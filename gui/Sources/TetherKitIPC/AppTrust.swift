import Foundation
import Security

/// 仅在管理员安装成功后写入；运行时交给 XPC 验证真实发送进程的代码身份。
public struct AppTrust: Codable, Sendable {
    public let userID: UInt32
    public let codeHash: String
    public var networkConfiguration: NetworkConfiguration?
    public static let path = "/Library/PrivilegedHelperTools/com.tetherkit.trust.json"

    public init(userID: UInt32, codeHash: String) {
        self.userID = userID
        self.codeHash = codeHash
    }

    public var isValid: Bool {
        userID > 0 && codeHash.count == 40
            && codeHash.allSatisfy { "0123456789abcdef".contains($0) }
    }

    public var requirement: String? {
        isValid ? "cdhash H\"\(codeHash)\"" : nil
    }

    public func save() throws {
        guard geteuid() == 0, isValid else { throw Failure.invalidCode }
        try JSONEncoder().encode(self).write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        guard chmod(Self.path, 0o600) == 0 else {
            try? FileManager.default.removeItem(atPath: Self.path)
            throw Failure.invalidCode
        }
    }

    public static func hash(of app: URL) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
        else { throw Failure.invalidCode }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let values = information as? [String: Any],
              let hash = values[kSecCodeInfoUnique as String] as? Data,
              let flags = values[kSecCodeInfoFlags as String] as? UInt32,
              flags & 0x10000 != 0 else { throw Failure.invalidCode }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public enum Failure: LocalizedError {
        case invalidCode
        public var errorDescription: String? { L(.appTrustRequired) }
    }
}
