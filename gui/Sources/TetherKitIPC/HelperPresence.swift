import Darwin
import Foundation

/// 本地状态只用于展示和发现进程；运行权限仍由 helper 的私有信任记录和 XPC 核验。
public enum HelperRecords {
    public static let installationPath = "/Library/PrivilegedHelperTools/com.tetherkit.installation.json"
    public static let runtimePath = "/var/run/com.tetherkit.helper-status.json"

    public static func read<T: Decodable>(_ type: T.Type, path: String) -> T? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o022 == 0,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func write<T: Encodable>(_ value: T, path: String) throws {
        guard geteuid() == 0 else { throw AppTrust.Failure.invalidCode }
        try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
        guard chmod(path, 0o644) == 0 else { throw AppTrust.Failure.invalidCode }
    }
}

/// 仅公开安装身份，不公开私有信任记录中的网络配置。
public struct HelperInstallation: Codable, Sendable {
    public var userID: UInt32
    public var codeHash: String
    public var revision: Int
    public var version: String

    public init(userID: UInt32, codeHash: String, revision: Int, version: String) {
        self.userID = userID
        self.codeHash = codeHash
        self.revision = revision
        self.version = version
    }
}

/// helper 在关键状态变化及退出前发布，App 读它不会触发 launchd。
public struct HelperRuntimeRecord: Codable, Sendable {
    public var processID: Int32
    public var status: SessionStatus

    public init(processID: Int32, status: SessionStatus) {
        self.processID = processID
        self.status = status
    }

    public var processIsRunning: Bool {
        guard processID > 0 else { return false }
        // PID 只用于非唤醒式存活探测，不参与授权；核对可执行路径避免旧 PID 被复用。
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(processID, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == HelperConstants.helperExecutablePath
    }
}

public struct HelperObservation: Sendable {
    public var isRunning: Bool
    public var lastStatus: SessionStatus?

    public init(isRunning: Bool, lastStatus: SessionStatus?) {
        self.isRunning = isRunning
        self.lastStatus = lastStatus
    }
}
