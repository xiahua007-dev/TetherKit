import Darwin
import TetherKitIPC
import TetherKitCore
import Foundation

/// 「App 内一键安装 / 卸载」的执行入口：本二进制以 `--install` 或 `--uninstall`
/// 参数被 AEWP 拉起时接管进程，把自己所在载荷目录里对应的脚本以真 root 跑一遍。
///
/// ★ 为什么需要这个模式，而不是让 App 直接 AEWP 安装脚本 ★
///
///   AEWP 的 setuid 载体（security_authtrampoline）给子进程的凭据是
///   euid=0 / ruid=调用者。而 bash 在 euid ≠ ruid 且未带 -p 时会把 euid 降回
///   ruid —— 这是防 setuid 脚本的老规矩，zsh、dash 同理。于是脚本开头的
///   root 检查必然报「需要 root 权限」。**真机踩过，不是理论推演。**
///
///   二进制不受这条规矩管。这里以 euid=0 起步，setuid(0) 把 ruid/suid 一并
///   归零，得到与 sudo 完全相同的凭据；随后 exec 的脚本连同它的全部子进程
///   （cp、chown、launchctl）都不再有任何凭据歧义。
///
/// ★ 三个细节 ★
///   * stderr 并进 stdout：AEWP 只给一根连 stdout 的管道，脚本的 die 全走
///     stderr，不合流 App 那边就看不到失败原因。放在最前面，连 setuid 失败
///     的报错也要能到达管道。
///   * setgid 必须在 setuid **之前** —— 反过来 euid 已经不是 0，setgid 会失败。
///   * 脚本路径取自本可执行文件所在目录：载荷是平铺的，拷到哪都成立。
///     装进 /Library/PrivilegedHelperTools 的那份旁边没有脚本，会得到明确
///     报错而不是误装。
func runInstallerModeIfRequested() {
    let scriptName: String
    switch CommandLine.arguments.dropFirst().first {
    case "--install": scriptName = "install-helper.sh"
    case "--uninstall": scriptName = "uninstall-helper.sh"
    default: return
    }

    dup2(STDOUT_FILENO, STDERR_FILENO)

    let installingUser = getuid() == 0
        ? UInt32(ProcessInfo.processInfo.environment["SUDO_UID"] ?? "") ?? 0 : getuid()

    guard setgid(0) == 0, setuid(0) == 0 else {
        print(L(.installerNeedsRoot, Int(geteuid()), Int(getuid()))
              + L(.installerUseTerminal, scriptName))
        exit(1)
    }

    let executable = URL(fileURLWithPath: Bundle.main.executablePath
                                          ?? CommandLine.arguments[0])
    let script = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        .appendingPathComponent(scriptName).path
    guard FileManager.default.isExecutableFile(atPath: script) else {
        print(L(.installerScriptMissing, script))
        exit(1)
    }

    do {
        // 在安装成功后才原子提交信任，失败时保留旧记录。
        let app = executable.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var trust: AppTrust? = scriptName == "install-helper.sh"
            ? AppTrust(userID: installingUser, codeHash: try AppTrust.hash(of: app)) : nil
        if let previous = HelperService.loadTrust(), previous.userID == installingUser {
            trust?.networkConfiguration = previous.networkConfiguration
        }
        if let trust, !trust.isValid { throw AppTrust.Failure.invalidCode }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        var environment = ProcessInfo.processInfo.environment
        environment["TETHERKIT_INSTALLER_ACTIVE"] = "1"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
        if let trust {
            try? FileManager.default.removeItem(atPath: HelperRecords.runtimePath)
            try HelperRecords.write(HelperInstallation(
                userID: trust.userID, codeHash: trust.codeHash,
                revision: HelperConstants.protocolRevision,
                version: TetherKitLibrary.versionInfo.version), path: HelperRecords.installationPath)
            try trust.save()
        }
        exit(0)
    } catch {
        print(error.localizedDescription)
        exit(1)
    }
}
