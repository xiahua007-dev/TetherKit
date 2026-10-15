import Foundation
import TetherKitCore
import TetherKitIPC

/// 离线编排测试使用内存会话，生产实现仍只持有 C ABI 会话。
protocol HelperSession: AnyObject {
    func start() throws
    func stop()
    func status() -> SessionStatus
    func drainNotices() -> [String]
}
extension TetherKitSession: HelperSession {}

/// helper 的 XPC 服务实现。
///
/// ★ 线程模型 ★
///
///   XPC 的方法在连接自己的队列上被调用。凡是可能耗时的操作（启动会话要做 USB
///   握手、DHCP 要等租约）都**立刻派发到自己的串行队列并异步回复**，绝不在
///   XPC 队列上阻塞 —— 否则同一条连接上后续的状态轮询会被一起卡住，界面表现
///   成「整个卡死」。
///
///   会话生命周期与网卡配置各用一条串行队列：两者互不阻塞，但各自内部严格串行
///   （并发的 start/stop 或并发的 ipconfig 都是灾难）。状态查询不排队，直接打到
///   C 层 —— 那边的快照本来就是线程安全的。
final class HelperService: NSObject, TetherKitHelperProtocol {
    private let lifecycleQueue = DispatchQueue(label: "com.tetherkit.helper.lifecycle")
    private let networkQueue = DispatchQueue(label: "com.tetherkit.helper.network")

    /// 保护 session 与 notices。持有时间都极短，用普通锁足够。
    private let stateLock = NSLock()
    private var session: (any HelperSession)?
    private var connectionID: UUID?
    private let usageLedger = UsageLedger()
    private var todayUsage: DailyUsage?
    private var networkPhase: NetworkPhase = .idle
    private var networkMessage = ""
    private var appliedConfiguration: NetworkConfiguration?
    private var idleTimer: DispatchSourceTimer?
    private var idleDeadline: DispatchTime?
    private var terminalStatus: SessionStatus?
    private var publish: ((SessionStatus) -> Void)?
    private var exitWhenIdle: (() -> Void)?
    private let writeUsage: ([DailyUsage]) throws -> Void
    private let interfaceTimeout: TimeInterval
    private let makeSession: (SessionConfiguration) throws -> any HelperSession
    private let applyConfiguration: (NetworkConfiguration, String) throws -> Void
    private let queryConfiguration: (String) throws -> NetworkState

    init(interfaceTimeout: TimeInterval = 30,
         writeUsage: @escaping ([DailyUsage]) throws -> Void = {
            try HelperRecords.write($0, path: TrafficUsage.path)
         },
         makeSession: @escaping (SessionConfiguration) throws -> any HelperSession = {
            // 新进程先记住设备名称，再打开会话占用 USB；离线测试替换整个工厂。
            _ = try? TetherKitLibrary.listDevices()
            return try TetherKitSession(configuration: $0)
         },
         applyConfiguration: @escaping (NetworkConfiguration, String) throws -> Void = {
            try NetworkConfigurator.apply($0, to: $1)
         },
         queryConfiguration: @escaping (String) throws -> NetworkState = {
            try NetworkConfigurator.query(interface: $0)
         }) {
        self.writeUsage = writeUsage
        self.interfaceTimeout = interfaceTimeout
        self.makeSession = makeSession
        self.applyConfiguration = applyConfiguration
        self.queryConfiguration = queryConfiguration
        super.init()
    }

    /// startSession 正在构造 / 握手中。这段窗口里 session 还没登记，但设备
    /// **已经**被本进程打开了 —— 枚举的占用判定必须把它算进去，否则字符串
    /// 读取会往握手中的控制端点再插一笔传输。
    private var sessionStarting = false
    /// 尚未被 App 取走的提示。
    private var pendingNotices: [String] = []

    // MARK: - 不需要授权的探测接口

    func helperVersion(reply: @escaping (String) -> Void) {
        // 带上 XPC 接口修订号，让 App 能发现「helper 是升级前的旧版本」。
        reply(HelperConstants.encodeVersion(TetherKitLibrary.versionInfo.version))
    }

    func environment(reply: @escaping (Data?, String?) -> Void) {
        respond(with: TetherKitLibrary.checkEnvironment(), reply: reply)
    }

    func listDevices(reply: @escaping (Data?, String?) -> Void) {
        // 设备被本进程持有期间不读字符串描述符：读要 libusb_open，白白失败一遍，
        // 还会往正在握手的控制端点插传输。判定用「真的持有」而不是「session
        // 非 nil」—— failed / stopped 的死会话早就把 USB 拆干净了，把它们也算
        // 「占用」会让设备拔掉重插后一直读不到名字。
        // 跳过不会丢名字：C 层会回填上次成功读到的值（见 environment.cc）。
        let deviceHeld = stateLock.withLock { () -> Bool in
            if sessionStarting { return true }
            guard let session else { return false }
            switch session.status().runState {
            case .starting, .running, .stopping: return true
            case .idle, .stopped, .failed: return false
            }
        }
        do {
            let devices = try TetherKitLibrary.listDevices(readStrings: !deviceHeld)
            respond(with: devices, reply: reply)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func snapshot() -> SessionStatus {
        stateLock.withLock { () -> SessionStatus in
            var status = session?.status() ?? .idle
            status.connectionID = connectionID
            status.todayUsage = todayUsage
            status.networkPhase = networkPhase
            status.networkMessage = networkMessage
            status.appliedConfiguration = appliedConfiguration
            status.savedConfiguration = Self.loadTrust()?.networkConfiguration
            return status
        }
    }

    func sessionStatus(reply: @escaping (Data?, String?) -> Void) {
        let status = snapshot()
        // 顺带把会话事件收进提示队列 —— 状态轮询本来就是每个刷新周期一次，
        // 搭车过来不用多一次 XPC 往返。
        if let notices = withState({ $0?.drainNotices() }), !notices.isEmpty {
            appendNotices(notices)
        }
        respond(with: status, reply: reply)
    }

    func queryNetwork(interface: String, reply: @escaping (Data?, String?) -> Void) {
        do {
            respond(with: try NetworkConfigurator.query(interface: interface), reply: reply)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    func drainFeed(reply: @escaping (Data?) -> Void) {
        let drained = TetherKitLibrary.drainLogs()
        let notices = takeNotices()
        let feed = HelperFeed(logs: drained.entries, droppedLogs: drained.dropped, notices: notices)
        reply(try? JSONEncoder().encode(feed))
    }

    func setLanguage(_ rawValue: String, reply: @escaping () -> Void) {
        // 认不出来就保持原样。宁可继续用上一种语言，也不要因为 App 传了个新值
        // 就退回默认 —— 那会表现成「切了个语言，helper 的日志反而变回英文」。
        if let language = Language(rawValue: rawValue) {
            L10n.apply(language == .chinese ? .chinese : .english)
            TetherKitLibrary.setLanguage(language)
        }
        reply()
    }

    // MARK: - 需要授权的特权接口

    func startSession(authorization: Data, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void) {
        guard let configuration = decode(SessionConfiguration.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else {
            return
        }

        if let language = configuration.language {
            setLanguage(language.rawValue, reply: {})
        }
        start(configuration: configuration, reply: reply)
    }

    func switchSession(authorization: Data, configuration: Data,
                       reply: @escaping (String?, Bool) -> Void) {
        guard let configuration = decode(SessionConfiguration.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else { return }
        if let language = configuration.language { setLanguage(language.rawValue, reply: {}) }
        start(configuration: configuration, replacing: true, reply: reply)
    }

    func start(configuration: SessionConfiguration, replacing: Bool = false,
               reply: @escaping (String?, Bool) -> Void) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }

            // 已经彻底死掉（失败 / 已停）的旧会话不能挡住新的连接。
            //
            // 典型场景：设备被拔掉 → 保活连续失败 → 会话进入 failed。C++ 侧
            // 此时已经把 USB、网卡全部拆干净了，Swift 这层只剩一个壳 —— 但它
            // 非 nil。若只按「session != nil 就拒绝」，用户重插设备后永远
            // 连不上，只能重装 helper。这个坑真实踩过。
            if let existing = self.withState({ $0 }) {
                let state = existing.status().runState
                guard replacing || state == .failed || state == .stopped else {
                    reply(L(.helperSessionAlreadyRunning), false)
                    return
                }
                self.networkQueue.sync { existing.stop() }
                self.recordUsage(existing.status(), force: true)  // 等旧配置完成后才允许复用网卡
                self.stateLock.withLock { self.session = nil }
            }

            // 从构造到 start() 返回的整个握手期间把「设备已被持有」亮出来，
            // 让并发到来的 listDevices 跳过字符串读取（见那边的说明）。
            self.idleDeadline = nil
            self.terminalStatus = nil
            self.stateLock.withLock { self.sessionStarting = true }
            defer { self.stateLock.withLock { self.sessionStarting = false } }
            do {
                let session = try self.makeSession(configuration)
                self.usageLedger.begin(deviceKey: configuration.usageDevice.flatMap(TrafficUsage.key))
                self.stateLock.withLock { self.todayUsage = nil }
                try session.start()
                let id = UUID()
                self.stateLock.withLock {
                    self.session = session
                    self.connectionID = id
                    self.networkPhase = .waitingForInterface
                    self.networkMessage = ""
                    self.appliedConfiguration = nil
                }
                self.publish?(self.snapshot())
                self.waitForInterface(session, id: id,
                                      configuration: configuration.networkConfiguration,
                                      deadline: .now() + self.interfaceTimeout)
                reply(nil, false)
            } catch {
                var failed = SessionStatus.idle
                failed.runState = .failed
                failed.fatalMessage = error.localizedDescription
                self.terminalStatus = failed
                self.idleDeadline = .now() + .milliseconds(500)
                self.publish?(failed)
                reply(error.localizedDescription, false)
            }
        }
    }

    func stopSession(authorization: Data, reply: @escaping (String?, Bool) -> Void) {
        guard authorize(authorization, reply: reply) else { return }
        stop(reply: reply)
    }

    func stop(reply: @escaping (String?, Bool) -> Void) {
        lifecycleQueue.async { [weak self] in
            guard let self else { return }
            // 先把 session 从状态里摘出来再停：停机要 join 控制线程、可能耗时
            // 数百毫秒，期间不该继续对外声称「会话在运行」。
            let session = self.stateLock.withLock { () -> (any HelperSession)? in
                defer {
                    self.session = nil
                    self.connectionID = nil
                    self.networkPhase = .idle
                    self.networkMessage = ""
                    self.appliedConfiguration = nil
                }
                return self.session
            }
            self.networkQueue.sync { session?.stop() }
            if let session { self.recordUsage(session.status(), force: true) }
            self.appendNotices([L(.helperSessionStopped)])
            self.terminalStatus = nil
            self.idleDeadline = .now() + .milliseconds(500)
            self.publish?(self.snapshot())
            reply(nil, false)
        }
    }

    func applyNetwork(authorization: Data, interface: String, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void) {
        guard let configuration = decode(NetworkConfiguration.self, from: configuration, reply: reply),
              authorize(authorization, reply: reply) else {
            return
        }
        applyOwnedNetwork(interface: interface, configuration: configuration, reply: reply)
    }

    func applyOwnedNetwork(interface: String, configuration: NetworkConfiguration,
                           reply: @escaping (String?, Bool) -> Void) {
        // 界面已经校验过一遍，但 XPC 是任何本机进程都能连的，helper 必须自己再挡
        // 一道 —— 而且用的是同一份规则，不会出现两边判断不一致。
        if let message = NetworkValidator.validationMessage(for: configuration) {
            reply(message, false)
            return
        }

        guard let (session, id) = stateLock.withLock({ () -> (any HelperSession, UUID)? in
            guard let session, let id = connectionID,
                  session.status().runState == .running,
                  session.status().systemInterface == interface else { return nil }
            return (session, id)
        }) else {
            reply(L(.interfaceNotReadyYet), false)
            return
        }
        networkQueue.async { [self] in
            guard isCurrent(session, id: id) else {
                reply(L(.interfaceNotReadyYet), false)
                return
            }
            reply(configure(session, id: id, configuration: configuration), false)
        }
    }

    private func isCurrent(_ candidate: any HelperSession, id: UUID) -> Bool {
        stateLock.withLock { session === candidate && connectionID == id }
    }

    /// 有界等待只存在于连接期间，不依赖 App 窗口或状态轮询。
    private func waitForInterface(_ session: any HelperSession, id: UUID,
                                  configuration: NetworkConfiguration,
                                  deadline: DispatchTime) {
        networkQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
            guard isCurrent(session, id: id) else { return }
            let status = session.status()
            if status.runState == .running, !status.systemInterface.isEmpty {
                _ = configure(session, id: id, configuration: configuration)
            } else if status.runState == .failed || status.runState == .stopped {
                stateLock.withLock {
                    networkPhase = .failed
                    networkMessage = status.fatalMessage
                }
            } else if DispatchTime.now() >= deadline {
                session.stop()
                guard isCurrent(session, id: id) else { return }
                stateLock.withLock {
                    networkPhase = .failed
                    networkMessage = L(.connectionTimedOut)
                }
            } else {
                waitForInterface(session, id: id, configuration: configuration, deadline: deadline)
            }
        }
    }

    private func configure(_ session: any HelperSession, id: UUID,
                           configuration: NetworkConfiguration) -> String? {
        defer {
            lifecycleQueue.async { [weak self] in
                guard let self, self.isCurrent(session, id: id) else { return }
                self.publish?(self.snapshot())
            }
        }
        guard isCurrent(session, id: id) else { return L(.interfaceNotReadyYet) }
        stateLock.withLock { networkPhase = .configuring; networkMessage = "" }
        do {
            if let message = NetworkValidator.validationMessage(for: configuration) {
                throw NSError(domain: "TetherKit", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
            let interface = session.status().systemInterface
            try applyConfiguration(configuration, interface)
            let actual = try queryConfiguration(interface)
            guard session.status().runState == .running,
                  configuration.mode == .none || actual.hasAddress else {
                throw NSError(domain: "TetherKit", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: L(.addressConfigurationFailed)])
            }
            guard isCurrent(session, id: id) else { return L(.interfaceNotReadyYet) }
            if configuration.mode != .none, var trust = Self.loadTrust() {
                trust.networkConfiguration = configuration
                try trust.save()
            }
            stateLock.withLock {
                networkPhase = configuration.mode == .none ? .idle : .ready
                appliedConfiguration = configuration.mode == .none ? nil : configuration
            }
            return nil
        } catch {
            if isCurrent(session, id: id) {
                stateLock.withLock {
                    networkPhase = .failed
                    networkMessage = error.localizedDescription
                }
            }
            return error.localizedDescription
        }
    }

    /// 仅生产入口启用；定时器只在 helper 已运行时检查终止状态，不会唤醒新进程。
    func enableIdleExit(publish: @escaping (SessionStatus) -> Void,
                        exit: @escaping () -> Void) {
        lifecycleQueue.async { [self] in
            self.publish = publish
            self.exitWhenIdle = exit
            idleDeadline = .now() + .seconds(2)
            publish(snapshot())
            let timer = DispatchSource.makeTimerSource(queue: lifecycleQueue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.checkIdle() }
            idleTimer = timer
            timer.resume()
        }
    }

    /// 生命周期队列上执行，新的 start/switch 会在同一队列取消退出计划。
    private func checkIdle() {
        var current = snapshot()
        recordUsage(current, force: current.runState == .failed || current.runState == .stopped)
        current.todayUsage = stateLock.withLock { todayUsage }
        if current.runState == .starting || current.runState == .running
            || current.runState == .stopping {
            idleDeadline = nil
            return
        }
        if terminalStatus == nil, current.runState == .failed || current.runState == .stopped {
            terminalStatus = current
            if let session = withState({ $0 }) { networkQueue.sync { session.stop() } }
        }
        let status = terminalStatus ?? current
        publish?(status)
        if idleDeadline == nil { idleDeadline = .now() + .milliseconds(500) }
        if let idleDeadline, DispatchTime.now() >= idleDeadline {
            idleTimer?.cancel()
            self.idleTimer = nil
            exitWhenIdle?()
        }
    }

    /// 仅复用生命周期定时器；数据收发线程不增加任何操作。
    private func recordUsage(_ status: SessionStatus, force: Bool = false) {
        let day = TrafficUsage.day()
        do {
            if usageLedger.needsDayFlush(day) {
                try usageLedger.saveIfNeeded(now: ProcessInfo.processInfo.systemUptime, force: true, write: writeUsage)
            }
            let entry = usageLedger.sample(rx: status.rxBytes, tx: status.txBytes, day: day)
            stateLock.withLock { todayUsage = entry }
            try usageLedger.saveIfNeeded(now: ProcessInfo.processInfo.systemUptime, force: force, write: writeUsage)
        } catch {
            appendNotices([L(.usageSaveFailed, error.localizedDescription)])
        }
    }

    // MARK: - 停机清理

    /// 收到 SIGTERM（`launchctl bootout`）时调用。
    ///
    /// Swift 的 deinit 在进程被终止时不会跑，不主动停一下就会把 feth 网卡漏在
    /// 内核里。落盘登记能兜住 SIGKILL，但能优雅退出时还是该优雅退出 ——
    /// 那样连「下次启动清理」这一步都省了。
    func shutdown() {
        lifecycleQueue.sync {
            idleTimer?.cancel()
            idleTimer = nil
            let session = stateLock.withLock { () -> (any HelperSession)? in
                defer { self.session = nil }
                return self.session
            }
            networkQueue.sync { session?.stop() }
            if let session { recordUsage(session.status(), force: true) }
            publish?(.idle)
        }
    }

    // MARK: - 内部工具

    /// 普通操作核验真实 XPC 用户；代码身份由 listener 的系统约束核验。
    /// authorization 参数暂留在协议中，运行权限不依赖客户端传来的数据。
    private func authorize(_ data: Data, reply: @escaping (String?, Bool) -> Void) -> Bool {
        // listener 已设置系统代码签名要求；方法内再核对当前连接用户。
        guard let connection = NSXPCConnection.current(),
              let trust = Self.loadTrust(),
              connection.effectiveUserIdentifier == trust.userID else {
            reply(L(.appTrustRequired), false)
            return false
        }
        return true
    }

    static func loadTrust() -> AppTrust? {
        var metadata = stat()
        guard lstat(AppTrust.path, &metadata) == 0,
              metadata.st_uid == 0, metadata.st_mode & 0o177 == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              let data = try? Data(contentsOf: URL(fileURLWithPath: AppTrust.path)),
              let trust = try? JSONDecoder().decode(AppTrust.self, from: data),
              trust.isValid else { return nil }
        return trust
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data,
                                      reply: @escaping (String?, Bool) -> Void) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            reply(L(.helperRequestDecodeFailed, error.localizedDescription), false)
            return nil
        }
    }

    private func respond<T: Encodable>(with value: T, reply: (Data?, String?) -> Void) {
        do {
            reply(try JSONEncoder().encode(value), nil)
        } catch {
            reply(nil, L(.helperReplyEncodeFailed, error.localizedDescription))
        }
    }

    private func withState<T>(_ body: ((any HelperSession)?) -> T) -> T {
        stateLock.withLock { body(session) }
    }

    private func appendNotices(_ notices: [String]) {
        guard !notices.isEmpty else { return }
        stateLock.withLock {
            pendingNotices.append(contentsOf: notices)
            // 上限 200：App 若长时间不来取（比如被挂起），不该让它无限增长。
            if pendingNotices.count > 200 {
                pendingNotices.removeFirst(pendingNotices.count - 200)
            }
        }
    }

    private func takeNotices() -> [String] {
        stateLock.withLock {
            defer { pendingNotices.removeAll() }
            return pendingNotices
        }
    }
}

/// XPC 监听器代理。
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service: HelperService

    init(service: HelperService) {
        self.service = service
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let trust = HelperService.loadTrust(),
              connection.effectiveUserIdentifier == trust.userID,
              let requirement = trust.requirement else { return false }
        // 由 XPC 对每条消息核对真实代码身份，避免 PID 复用和客户端路径伪造。
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: TetherKitHelperProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
