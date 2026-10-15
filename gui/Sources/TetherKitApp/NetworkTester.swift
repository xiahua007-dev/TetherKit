import Foundation
import TetherKitIPC

/// 网络连通性测试的项目。
///
/// 这些测试只在用户点击按钮时运行，不在后台轮询。网站测试使用 HTTPS，
/// 并通过 curl 的 `--interface` 强制走 TetherKit 创建的网卡。
enum NetworkTestTarget: String, CaseIterable, Identifiable, Sendable {
    case gateway
    case dns
    case publicHTTPS
    case baidu
    case bilibili
    case tencent
    case douyin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gateway: return L(.networkTestGateway)
        case .dns: return L(.networkTestDNS)
        case .publicHTTPS: return L(.networkTestPublicHTTPS)
        case .baidu: return L(.networkTestBaidu)
        case .bilibili: return L(.networkTestBilibili)
        case .tencent: return L(.networkTestTencent)
        case .douyin: return L(.networkTestDouyin)
        }
    }
}

struct NetworkTestResult: Identifiable, Equatable, Sendable {
    let id: NetworkTestTarget
    let target: NetworkTestTarget
    let success: Bool
    let latencyMilliseconds: Double?
    let statusCode: Int?
    let failureDescription: String?
}

enum NetworkTestState: Equatable, Sendable {
    case idle
    case running
    case finished([NetworkTestResult])

    var failedCount: Int {
        guard case .finished(let results) = self else { return 0 }
        return results.filter { !$0.success }.count
    }

    /// 失败项置顶，各组内保持原来的检测顺序。
    var orderedResults: [NetworkTestResult] {
        guard case .finished(let results) = self else { return [] }
        return results.filter { !$0.success } + results.filter { $0.success }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// 在后台执行一次性网络测试。
enum NetworkTester {
    private struct CommandResult: Sendable {
        let exitCode: Int32
        let output: String
        let error: String
    }

    static func run(interfaceName: String, sourceAddress: String,
                    router: String) async -> [NetworkTestResult] {
        let targets = NetworkTestTarget.allCases.filter { target in
            (target != .gateway && target != .dns) || !router.isEmpty
        }

        return await withTaskGroup(of: NetworkTestResult.self, returning: [NetworkTestResult].self) {
            group in
            for target in targets {
                group.addTask {
                    await run(target: target, interfaceName: interfaceName,
                              sourceAddress: sourceAddress, router: router)
                }
            }

            var results: [NetworkTestResult] = []
            for await result in group {
                results.append(result)
            }
            return targets.compactMap { target in results.first { $0.target == target } }
        }
    }

    private static func run(target: NetworkTestTarget, interfaceName: String,
                            sourceAddress: String, router: String) async -> NetworkTestResult {
        switch target {
        case .gateway:
            let result = await command("/sbin/ping", arguments: [
                "-c", "1", "-W", "2000", "-S", sourceAddress, router,
            ])
            let latency = parsePingLatency(result.output)
            return NetworkTestResult(id: target, target: target,
                                     success: result.exitCode == 0,
                                     latencyMilliseconds: latency,
                                     statusCode: nil,
                                     failureDescription: failure(result))

        case .dns:
            let result = await command("/usr/bin/dig", arguments: [
                "+time=2", "+tries=1", "+short", "@\(router)", "example.com",
            ])
            return NetworkTestResult(id: target, target: target,
                                     success: result.exitCode == 0 && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                     latencyMilliseconds: nil,
                                     statusCode: nil,
                                     failureDescription: failure(result))

        case .publicHTTPS, .baidu, .bilibili, .tencent, .douyin:
            let host = host(for: target)
            let resolvedAddress = router.isEmpty ? nil : await resolve(host: host, router: router)
            guard router.isEmpty || resolvedAddress != nil else {
                return NetworkTestResult(id: target, target: target, success: false,
                                         latencyMilliseconds: nil, statusCode: nil,
                                         failureDescription: L(.networkTestDNSFailed))
            }

            var arguments = [
                "--interface", interfaceName,
                "--connect-timeout", "4",
                "--max-time", "8",
                "--silent",
                "--show-error",
                "--output", "/dev/null",
                "--write-out", "%{http_code} %{time_total}",
            ]
            if let resolvedAddress {
                arguments += ["--resolve", "\(host):443:\(resolvedAddress)"]
            }
            arguments.append(url(for: target))
            let result = await command("/usr/bin/curl", arguments: arguments)
            let values = result.output.split(separator: " ")
            let statusCode = values.first.flatMap { Int($0) }
            let latency = values.dropFirst().first.flatMap { Double($0).map { $0 * 1000 } }
            return NetworkTestResult(id: target, target: target,
                                     success: result.exitCode == 0 && statusCode != nil,
                                     latencyMilliseconds: latency,
                                     statusCode: statusCode,
                                     failureDescription: failure(result))
        }
    }

    private static func url(for target: NetworkTestTarget) -> String {
        switch target {
        case .publicHTTPS: return "https://www.cloudflare.com/cdn-cgi/trace"
        case .baidu: return "https://www.baidu.com/"
        case .bilibili: return "https://www.bilibili.com/"
        case .tencent: return "https://www.qq.com/"
        case .douyin: return "https://www.douyin.com/"
        case .gateway, .dns: return ""
        }
    }

    private static func host(for target: NetworkTestTarget) -> String {
        switch target {
        case .publicHTTPS: return "www.cloudflare.com"
        case .baidu: return "www.baidu.com"
        case .bilibili: return "www.bilibili.com"
        case .tencent: return "www.qq.com"
        case .douyin: return "www.douyin.com"
        case .gateway, .dns: return ""
        }
    }

    private static func resolve(host: String, router: String) async -> String? {
        let result = await command("/usr/bin/dig", arguments: [
            "+time=2", "+tries=1", "+short", "A", "@\(router)", host,
        ])
        return result.output
            .split(whereSeparator: \.isNewline)
            .first(where: { line in
                let parts = line.split(separator: ".")
                return parts.count == 4 && parts.allSatisfy { part in
                    !part.isEmpty && part.allSatisfy(\.isNumber)
                }
            })
            .map(String.init)
    }

    private static func parsePingLatency(_ output: String) -> Double? {
        guard let marker = output.range(of: "time=") else { return nil }
        let suffix = output[marker.upperBound...]
        let number = suffix.prefix { $0.isNumber || $0 == "." }
        return Double(number)
    }

    private static func failure(_ result: CommandResult) -> String? {
        guard result.exitCode != 0 else { return nil }
        let message = result.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message.split(separator: "\n").last.map(String.init)
    }

    private static func command(_ executable: String, arguments: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()
                    let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                        encoding: .utf8) ?? ""
                    let error = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                       encoding: .utf8) ?? ""
                    continuation.resume(returning: CommandResult(exitCode: process.terminationStatus,
                                                                  output: output,
                                                                  error: error))
                } catch {
                    continuation.resume(returning: CommandResult(exitCode: -1, output: "",
                                                                  error: error.localizedDescription))
                }
            }
        }
    }
}
