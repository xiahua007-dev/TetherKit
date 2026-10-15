import Foundation
import TetherKitCore
import TetherKitIPC

/// App 的 helper 边界，允许离线验证设备切换的请求顺序与失败行为。
protocol HelperConnection {
    func installation() async throws -> HelperInstallation?
    func observation() async -> HelperObservation
    func switchSession(authorization: Data, configuration: SessionConfiguration) async throws
    func helperVersion() async throws -> String
    func environment() async throws -> EnvironmentReport
    func listDevices() async throws -> [DeviceDescriptor]
    func sessionStatus() async throws -> SessionStatus
    func queryNetwork(interface: String) async throws -> NetworkState
    func drainFeed() async throws -> HelperFeed
    func setLanguage(_ language: Language) async
    func startSession(authorization: Data, configuration: SessionConfiguration) async throws
    func stopSession(authorization: Data) async throws
    func applyNetwork(authorization: Data, interface: String,
                      configuration: NetworkConfiguration) async throws
}

/// 与 tetherkit-helper 通信的客户端。
///
/// 把「基于 reply block 的 XPC」包成 async/await。看着琐碎，但有一处必须小心：
/// NSXPCConnection 的错误处理块与方法的 reply 块**可能都被调用**（比如请求已
/// 发出、连接随后断开），而 CheckedContinuation 被 resume 两次是直接崩溃。
/// 因此每次调用都用 ContinuationGuard 包一层，保证只兑现一次。
final class HelperClient: HelperConnection {
    enum Failure: LocalizedError {
        /// 连不上 —— 最常见的原因是 helper 还没安装。
        case unreachable(String)
        /// helper 明确返回了错误。
        case helper(String)
        /// helper 复核授权没通过 —— 多半是凭据过期了，重新弹框再来一次就行。
        case authorizationRejected(String)
        /// 应答解不出来（两端版本不一致）。
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .unreachable(let detail):
                return L(.helperConnectFailed, detail) + "\n" + L(.appTrustRequired)
            case .helper(let message), .authorizationRejected(let message):
                return message
            case .malformedResponse:
                return L(.helperReplyUnparsable)
            }
        }

        var isUnreachable: Bool {
            if case .unreachable = self { return true }
            return false
        }

        /// 是否值得「重新取一次授权再试」。
        var isAuthorizationProblem: Bool {
            if case .authorizationRejected = self { return true }
            return false
        }
    }

    /// 保证一个 continuation 只被兑现一次。
    ///
    /// XPC 的错误块和 reply 块存在都被调用的可能，而重复 resume 会崩溃 ——
    /// 这个坑只在「请求发出后连接才断」这种时序上出现，很难靠测试撞到。
    private final class ContinuationGuard<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?

        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: T) {
            take()?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        private func take() -> CheckedContinuation<T, Error>? {
            lock.withLock {
                defer { continuation = nil }
                return continuation
            }
        }
    }

    private let connectionLock = NSLock()
    private var cachedConnection: NSXPCConnection?

    deinit {
        cachedConnection?.invalidate()
    }

    /// 取（必要时创建）到 helper 的连接。
    private func connection() -> NSXPCConnection {
        connectionLock.withLock {
            if let existing = cachedConnection {
                return existing
            }
            let created = NSXPCConnection(machServiceName: HelperConstants.machServiceName,
                                          options: .privileged)
            created.remoteObjectInterface = NSXPCInterface(with: TetherKitHelperProtocol.self)

            // 连接断掉后必须丢弃缓存，否则后续调用会一直打在一条死连接上，
            // 表现为「helper 明明装好了却一直连不上」。
            let invalidate: @Sendable () -> Void = { [weak self, weak created] in
                self?.connectionLock.withLock {
                    if self?.cachedConnection === created { self?.cachedConnection = nil }
                }
            }
            created.invalidationHandler = invalidate
            created.interruptionHandler = invalidate

            created.resume()
            cachedConnection = created
            return created
        }
    }

    private func discardConnection() {
        let previous = connectionLock.withLock { () -> NSXPCConnection? in
            defer { cachedConnection = nil }
            return cachedConnection
        }
        previous?.invalidate()
    }

    /// 发一次调用。`body` 拿到代理与守卫，负责发起请求并兑现结果。
    private func invoke<T>(
        _ body: @escaping (TetherKitHelperProtocol, ContinuationGuard<T>) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let guarded = ContinuationGuard(continuation)
            let proxy = connection().remoteObjectProxyWithErrorHandler { error in
                guarded.resume(throwing: Failure.unreachable(error.localizedDescription))
            }
            guard let typed = proxy as? TetherKitHelperProtocol else {
                guarded.resume(throwing: Failure.malformedResponse)
                return
            }
            body(typed, guarded)
        }
    }

    /// 「返回一个 Codable 或一条错误」这种应答的通用处理。
    private func decode<T: Decodable>(_ type: T.Type, data: Data?, message: String?,
                                      into guarded: ContinuationGuard<T>) {
        if let message {
            guarded.resume(throwing: Failure.helper(message))
            return
        }
        guard let data, let value = try? JSONDecoder().decode(type, from: data) else {
            guarded.resume(throwing: Failure.malformedResponse)
            return
        }
        guarded.resume(returning: value)
    }

    private static let ownCodeHash = try? AppTrust.hash(of: Bundle.main.bundleURL)

    func installation() async throws -> HelperInstallation? {
        guard let installation = HelperRecords.read(HelperInstallation.self,
                                                    path: HelperRecords.installationPath) else { return nil }
        guard installation.userID == getuid(), installation.codeHash == Self.ownCodeHash else {
            throw Failure.helper(L(.appTrustRequired))
        }
        return installation
    }

    func observation() async -> HelperObservation {
        let record = HelperRecords.read(HelperRuntimeRecord.self, path: HelperRecords.runtimePath)
        return HelperObservation(isRunning: record?.processIsRunning ?? false, lastStatus: record?.status)
    }

    // MARK: - 探测（不需要授权）

    func helperVersion() async throws -> String {
        try await invoke { proxy, guarded in
            proxy.helperVersion { guarded.resume(returning: $0) }
        }
    }

    func environment() async throws -> EnvironmentReport {
        try await invoke { proxy, guarded in
            proxy.environment { data, message in
                self.decode(EnvironmentReport.self, data: data, message: message, into: guarded)
            }
        }
    }

    func listDevices() async throws -> [DeviceDescriptor] {
        if !(await observation()).isRunning {
            return try await Task.detached { try TetherKitLibrary.listDevices() }.value
        }
        return try await invoke { proxy, guarded in
            proxy.listDevices { data, message in
                self.decode([DeviceDescriptor].self, data: data, message: message, into: guarded)
            }
        }
    }

    func sessionStatus() async throws -> SessionStatus {
        try await invoke { proxy, guarded in
            proxy.sessionStatus { data, message in
                self.decode(SessionStatus.self, data: data, message: message, into: guarded)
            }
        }
    }

    func queryNetwork(interface: String) async throws -> NetworkState {
        try await invoke { proxy, guarded in
            proxy.queryNetwork(interface: interface) { data, message in
                self.decode(NetworkState.self, data: data, message: message, into: guarded)
            }
        }
    }

    func drainFeed() async throws -> HelperFeed {
        try await invoke { proxy, guarded in
            proxy.drainFeed { data in
                guard let data, let feed = try? JSONDecoder().decode(HelperFeed.self, from: data)
                else {
                    guarded.resume(returning: .empty)
                    return
                }
                guarded.resume(returning: feed)
            }
        }
    }

    /// 把界面语言告诉 helper。**失败静默吞掉** —— 语言没同步上只是日志卡里
    /// 混了另一种语言，不该让它把「连不上 helper」的错误弹给用户（正常启动
    /// 顺序里 helper 可能还没装）。
    func setLanguage(_ language: Language) async {
        guard (await observation()).isRunning else { return }
        _ = try? await invoke { proxy, guarded in
            proxy.setLanguage(language.rawValue) { guarded.resume(returning: ()) }
        }
    }

    // MARK: - 特权操作（需要授权凭据）

    func startSession(authorization: Data, configuration: SessionConfiguration) async throws {
        let payload = try JSONEncoder().encode(configuration)
        for attempt in 0..<2 {
            do {
                try await invokeVoid { proxy, guarded in
                    proxy.startSession(authorization: authorization,
                                       configuration: payload) { message, authorizationFailed in
                        Self.finish(message, authorizationFailed, guarded)
                    }
                }
                return
            } catch let failure as Failure where failure.isUnreachable && attempt == 0 {
                // 仅处理空闲退出与新连接擦肩而过；已受理的会话不会进入空闲退出。
                discardConnection()
                try await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    func switchSession(authorization: Data, configuration: SessionConfiguration) async throws {
        let payload = try JSONEncoder().encode(configuration)
        try await invokeVoid { proxy, guarded in
            proxy.switchSession(authorization: authorization, configuration: payload) { message, failed in
                Self.finish(message, failed, guarded)
            }
        }
    }

    func stopSession(authorization: Data) async throws {
        try await invokeVoid { proxy, guarded in
            proxy.stopSession(authorization: authorization) { message, authorizationFailed in
                Self.finish(message, authorizationFailed, guarded)
            }
        }
        discardConnection()
    }

    func applyNetwork(authorization: Data, interface: String,
                      configuration: NetworkConfiguration) async throws {
        let payload = try JSONEncoder().encode(configuration)
        try await invokeVoid { proxy, guarded in
            proxy.applyNetwork(authorization: authorization, interface: interface,
                               configuration: payload) { message, authorizationFailed in
                Self.finish(message, authorizationFailed, guarded)
            }
        }
    }

    private func invokeVoid(
        _ body: @escaping (TetherKitHelperProtocol, ContinuationGuard<Void>) -> Void
    ) async throws {
        _ = try await invoke(body)
    }

    private static func finish(_ message: String?, _ authorizationFailed: Bool,
                               _ guarded: ContinuationGuard<Void>) {
        guard let message else {
            guarded.resume(returning: ())
            return
        }
        guarded.resume(throwing: authorizationFailed
            ? Failure.authorizationRejected(message)
            : Failure.helper(message))
    }
}
