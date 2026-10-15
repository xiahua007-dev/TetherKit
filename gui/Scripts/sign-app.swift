import Foundation
import Security

// 将内嵌库的实际签名哈希写入库加载约束；系统库由系统单独认可。
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let libraries = try FileManager.default.contentsOfDirectory(
    at: app.appendingPathComponent("Contents/Frameworks"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "dylib" }
var hashes: [Data] = []
for library in libraries {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(library as CFURL, [], &code) == errSecSuccess,
          let code else { fatalError("无法读取库签名") }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let values = info as? [String: Any],
          let codeHashes = values[kSecCodeInfoCdHashes as String] as? [Data] else {
        fatalError("库缺少代码哈希")
    }
    hashes.append(contentsOf: codeHashes)
}
guard !hashes.isEmpty else { fatalError("没有内嵌库") }
let constraint: [String: Any] = ["cdhash": ["$in": hashes]]
try PropertyListSerialization.data(fromPropertyList: constraint, format: .xml, options: 0)
    .write(to: output)
