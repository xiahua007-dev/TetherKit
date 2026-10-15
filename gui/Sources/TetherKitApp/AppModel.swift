import Foundation
import Observation
import SwiftUI
import TetherKitCore
import TetherKitIPC

/// 一次采样得到的瞬时速率。
struct ThroughputSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let receiveBitsPerSecond: Double
    let transmitBitsPerSecond: Double
    let receivePacketsPerSecond: Double
    let transmitPacketsPerSecond: Double

    static let zero = ThroughputSample(timestamp: .distantPast, receiveBitsPerSecond: 0,
                                       transmitBitsPerSecond: 0, receivePacketsPerSecond: 0,
                                       transmitPacketsPerSecond: 0)
}

/// 连续重复的日志折叠成一条。
///
/// 周期性路径（比如每 2 秒一次的设备枚举）会把同一句话刷成一整列，淹没真正
/// 有信息量的行；折叠成「一行 ×N」承载同样的信息。id 取首条的 —— 重复只更新
/// 计数与时间戳，行的身份不变，列表不用整行重建。
struct CollapsedLogEntry: Identifiable {
    let first: LogEntry
    private(set) var latest: LogEntry
    private(set) var count: Int = 1

    init(_ entry: LogEntry) {
        first = entry
        latest = entry
    }

    var id: UUID { first.id }

    /// 时间戳以外完全相同才算重复 —— 消息里带着变化的值（地址、计数）就该分行。
    func matches(_ entry: LogEntry) -> Bool {
        entry.level == first.level && entry.thread == first.thread
            && entry.message == first.message
    }

    mutating func absorb(_ entry: LogEntry) {
        latest = entry
        count += 1
    }
}

/// helper 的可达性。界面靠它决定是「显示安装引导」还是「正常工作」。
enum HelperAvailability: Equatable {
    case unknown
    case available(version: String)
    case missing(reason: String)
    /// 装着的 helper 比当前 App 旧（或新），XPC 接口对不上。
    ///
    /// 单独一个状态而不是并进 missing：这两种情况的解决办法不一样，
    /// 一个是「去装」，一个是「去重装」，提示文案必须能区分。
    case outdated(installed: Int, expected: Int)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// 装着的特权组件与 App 自带的那份不是同一个版本。
///
/// ★ 与 `HelperAvailability.outdated` 的分工 ★
///   那个说的是**协议对不上**：方法签名都不一致了，再调下去要么卡住要么崩，
///   所以必须挡在安装引导页上。这个说的是**协议仍兼容、版本却不一样** ——
///   组件照常能用，只是它里面还是升级前的那份 libtetherkit，新版修的问题在
///   真正干活的那一侧一个都没修（`brew upgrade` 只换 .app，动不了
///   /Library/PrivilegedHelperTools）。
///
///   所以它不拦路，只在管理行里点亮一个「更新特权组件」。协议号不变的版本
///   （0.1.4 → 0.1.5 这种）以前完全没有提示，用户唯一能察觉的迹象是
///   「更新说明里写着修好的毛病还在」。
struct HelperVersionMismatch: Equatable {
    /// 装着的那份，只取版本号（如 `"0.1.3"`）。
    let installed: String
    /// App 自带的那份 —— 点了按钮之后会装上去的版本。
    let expected: String
}

/// 手动「检查更新」的结果，驱动一个弹窗。
enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case updateAvailable(UpdateChecker.Release)
    case failed(String)
    /// 开发构建（`swift run` 的裸可执行文件）没有版本号，没法比。
    case unavailable
}

/// 界面的全部状态与动作。
///
/// 会话只在特权 helper 中运行；空闲探测与设备枚举留在 App，避免唤醒 helper。
@Observable
@MainActor
final class AppModel {
    // MARK: - 对界面公开的状态

    private(set) var helperAvailability: HelperAvailability = .unknown
    /// 装着的组件与 App 版本对不上时的两个版本号；一致（或还没探到）为 nil。
    private(set) var helperNeedsTrustRecovery = false
    private(set) var helperIsRunning = false
    private(set) var helperVersionMismatch: HelperVersionMismatch?
    private(set) var environment: EnvironmentReport?
    private(set) var devices: [DeviceDescriptor] = []
    private(set) var status: SessionStatus = .idle
    private(set) var networkState: NetworkState = .empty
    private(set) var networkTestState: NetworkTestState = .idle
    private(set) var throughput: ThroughputSample = .zero
    private(set) var throughputHistory: [ThroughputSample] = []
    private(set) var logs: [LogEntry] = []
    private(set) var droppedLogCount: UInt64 = 0

    /// 用户在设备列表里选中的那台。为 nil 表示「用找到的第一台」。
    var selectedDeviceID: String?
    /// 会话配置里用户可调的部分。
    var requestedMTU: UInt32 = 1500
    var adoptDeviceMAC: Bool = true
    /// 网络配置表单。
    var networkConfiguration: NetworkConfiguration = .dhcp
    private(set) var savedNetworkConfiguration: NetworkConfiguration = .dhcp
    private var appliedNetworkConfiguration: NetworkConfiguration?

    var hasNetworkChanges: Bool { networkConfiguration != appliedNetworkConfiguration }

    var connectionLabel: String {
        if status.networkPhase == .failed, status.runState != .failed {
            return L(status.runState == .stopped ? .connectionTimedOut : .addressConfigurationFailed)
        }
        if status.runState == .starting { return L(.connectingPhone) }
        if status.runState == .running {
            switch status.networkPhase {
            case .waitingForInterface: return L(.connectingPhone)
            case .configuring: return L(.gettingAddress)
            case .ready where networkState.hasAddress:
                if !status.linkUp { return L(.linkDown) }
                if status.paused { return L(.transferPaused) }
                return L(.networkReady)
            case .failed: return L(.addressConfigurationFailed)
            default: return L(.notConfigured)
            }
        }
        return Design.statusLabel(for: status)
    }

    func rememberNetworkConfiguration(_ configuration: NetworkConfiguration) {
        guard configuration.mode != .none,
              NetworkValidator.validationMessage(for: configuration) == nil else { return }
        savedNetworkConfiguration = configuration
        networkDefaults.set(try? JSONEncoder().encode(configuration),
                                  forKey: "TetherKitSuccessfulNetworkConfiguration")
    }

    /// 界面语言偏好。改它会**同时**做三件事：切 Swift 侧的文案表、把语言推给
    /// libtetherkit（否则日志卡里会混进另一种语言）、再推给 helper（它以 root
    /// 跑在 launchd 下，看不到用户的语言偏好）。
    ///
    /// `didSet` 里顺带把 `languageRevision` 加一 —— 文案是从全局表里查的，
    /// SwiftUI 无从得知它变了，得靠这个值把视图树整个重建一次。
    var languagePreference: LanguagePreference = .system {
        didSet {
            guard languagePreference != oldValue else { return }
            applyLanguage(languagePreference)
        }
    }

    /// 语言换了多少次。视图根上挂 `.id(model.languageRevision)`，靠它触发重建。
    private(set) var languageRevision = 0

    /// 正在等待某个特权操作完成 —— 界面据此禁用按钮并显示进度。
    private(set) var isBusy: Bool = false
    private(set) var isRefreshingDevices = false
    /// 需要弹给用户看的错误。
    var alertMessage: String?

    /// 已知的新版本。驱动管理行里的「有新版」提示；nil = 没有或没查过。
    private(set) var availableUpdate: UpdateChecker.Release?
    /// 手动「检查更新」的结果弹窗。视图关掉弹窗时置回 nil。
    var updateCheckResult: UpdateCheckResult?

    var logLevelFilter: LogLevel = .info

    // MARK: - 内部

    private let client: any HelperConnection
    private let networkDefaults: UserDefaults

    init(networkDefaults: UserDefaults = .standard, client: any HelperConnection = HelperClient()) {
        self.client = client
        self.networkDefaults = networkDefaults
        restoreNetworkConfiguration()
    }

    private var hasStarted = false
    private var pollingTask: Task<Void, Never>?
    /// 上一次的状态快照，用来做差算速率。
    private var previousStatus: SessionStatus?
    private var sessionStartedAt: Date?
    /// 上次枚举设备的时刻。用单调时钟，避免系统时间被调整时算出负的间隔。
    private var lastDeviceRefresh: ContinuousClock.Instant?

    /// 主窗口关闭时停止状态轮询；网络会话由 helper 独立持有。
    private var isMainWindowVisible = false
    /// 详情窗口关闭时停止日志与吞吐数据轮询。
    private var isDetailsWindowVisible = false

    private var isPollingNeeded: Bool {
        isMainWindowVisible || isDetailsWindowVisible
    }

    /// 最近一次「明确要求显示主窗口」的时刻。初始值 = 现在，因为 App 启动本身
    /// 就是一次合法的窗口展示。
    private var windowPresentationRequestedAt = ContinuousClock.now

    /// 缓存的授权令牌。为 nil 表示下次特权操作需要弹框。
    ///
    /// 不自己记过期时间：系统的 timeout 由授权数据库控制（可能被管理员改），
    /// 我们自己算一份只会和系统不一致。以 helper 的复核结果为准更可靠。
    private var cachedAuthorization: AuthorizationToken?

    /// 系统授权框里显示的说明。
    ///
    /// 不写这一句的话框里只有「TetherKit 想要进行更改」，用户无从判断该不该批准。
    /// 用计算属性而不是 `static let`：`static let` 只在类型第一次被用到时求值
    /// 一次，用户之后切换语言就再也不会更新了。

    /// 安装特权组件时授权框里的说明。单独一句 —— 这次批准的是「往系统目录里
    /// 装东西」，和上面的日常操作不是一回事，文案必须说实话。
    private static var helperInstallPrompt: String { L(.authPromptInstall) }

    /// 卸载特权组件时授权框里的说明。
    private static var helperUninstallPrompt: String { L(.authPromptUninstall) }

    /// 轮询周期。
    ///
    /// 主窗口可见时每秒刷新一次，减少 XPC 往返与图表重绘。
    private static let pollInterval: Duration = .seconds(1)

    /// 设备枚举的最小间隔。
    ///
    /// 比状态轮询慢得多，因为枚举要 libusb_open 去读字符串描述符。2 秒的插拔
    /// 响应延迟用户基本感觉不到，而开销降到了原来的四分之一。
    private static let deviceRefreshInterval: Duration = .seconds(2)

    /// 吞吐曲线保留的采样点数。60 点 × 1 秒 = 最近约 60 秒。
    private static let historyCapacity = 60

    /// 日志面板保留的行数。
    ///
    /// 2000 行足够回溯一整次启动序列加若干分钟运行；再多 SwiftUI 的列表会开始卡。
    private static let logCapacity = 2000

    // MARK: - 生命周期

    /// 应用一个语言偏好：本进程 → libtetherkit → helper，一处都不能漏。
    ///
    /// UserDefaults 只在这里写，读在 `restoreLanguagePreference()` 里 ——
    /// 两边都走同一个键名常量，改名不会漏改一半。
    func applyLanguage(_ preference: LanguagePreference) {
        let resolved = L10n.apply(preference)
        TetherKitLibrary.setLanguage(resolved)
        UserDefaults.standard.set(preference.rawValue, forKey: Self.languageDefaultsKey)
        languageRevision += 1
        Task { await client.setLanguage(resolved) }
    }

    /// 启动时恢复上次选的语言。没存过就是 `.system`。
    private func restoreLanguagePreference() {
        let stored = UserDefaults.standard.string(forKey: Self.languageDefaultsKey)
        let preference = stored.flatMap(LanguagePreference.init(rawValue:)) ?? .system
        // 直接写存储属性会触发 didSet 再存一次盘，绕开它：这里是「恢复」，
        // 不是「用户改了」。
        if preference != languagePreference {
            languagePreference = preference
        } else {
            applyLanguage(preference)
        }
    }

    private static let languageDefaultsKey = "TetherKitLanguagePreference"

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        restoreLanguagePreference()
        restoreKnownUpdate()
        Task { await checkForUpdatesQuietly() }
    }

    private func restoreNetworkConfiguration() {
        if let data = networkDefaults.data(forKey: "TetherKitSuccessfulNetworkConfiguration"),
           let configuration = try? JSONDecoder().decode(NetworkConfiguration.self, from: data),
           configuration.mode != .none,
           NetworkValidator.validationMessage(for: configuration) == nil {
            networkConfiguration = configuration
            savedNetworkConfiguration = configuration
        }
    }

    private func startPolling() {
        guard isPollingNeeded, pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do {
                    try await Task.sleep(for: Self.pollInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// 主窗口出现（含从菜单栏重新打开）。
    func windowDidAppear() {
        guard !isMainWindowVisible else { return }
        isMainWindowVisible = true
        startPolling()
    }

    /// 主窗口消失后停止主窗口状态轮询；详情窗口若仍打开，轮询继续运行。
    func windowDidDisappear() {
        isMainWindowVisible = false
        stopPollingIfNeeded()
    }

    /// 详情窗口出现时开始收集吞吐和日志。
    func detailsWindowDidAppear() {
        guard !isDetailsWindowVisible else { return }
        isDetailsWindowVisible = true
        previousStatus = nil
        throughput = .zero
        throughputHistory.removeAll()
        startPolling()
    }

    /// 详情窗口消失后停止收集日志和吞吐；不向 helper 发停止会话的请求。
    func detailsWindowDidDisappear() {
        isDetailsWindowVisible = false
        throughput = .zero
        throughputHistory.removeAll()
        stopPollingIfNeeded()
    }

    private func stopPollingIfNeeded() {
        if !isPollingNeeded {
            stopPolling()
        }
    }

    /// 登记「接下来这次主窗口展示是我们主动要求的」。
    ///
    /// App 启动时（初始化默认值）与「打开主窗口」按钮各登记一次。
    func expectWindowPresentation() {
        windowPresentationRequestedAt = ContinuousClock.now
    }

    /// 这次窗口出现是不是我们自己要求的。
    ///
    /// SwiftUI 会在「无窗口的 App 被激活」时（点菜单栏图标就会触发）擅自重建
    /// Window 场景，那种复活必须当场关掉。用时间窗而不是一次性标志来判定：
    /// 「3 秒内登记过」就算数 —— 一次性标志在「窗口已开着时再点打开」这类
    /// 路径上会残留，时间窗天然自愈。
    func isWindowPresentationExpected() -> Bool {
        ContinuousClock.now - windowPresentationRequestedAt < .seconds(3)
    }

    // MARK: - 轮询

    /// 只读 root 安装元数据和本地运行记录，不发 XPC，也不拉起 helper。
    func refreshHelperAvailability() async -> HelperObservation? {
        do {
            guard let installation = try await client.installation() else {
                helperNeedsTrustRecovery = FileManager.default.fileExists(
                    atPath: HelperConstants.helperExecutablePath)
                helperAvailability = .missing(reason: L(.helperLocalMetadataMissing))
                helperVersionMismatch = nil
                helperIsRunning = false
                return nil
            }
            guard installation.revision == HelperConstants.protocolRevision else {
                helperAvailability = .outdated(installed: installation.revision,
                                               expected: HelperConstants.protocolRevision)
                helperVersionMismatch = nil
                return nil
            }
            helperAvailability = .available(version: installation.version)
            helperNeedsTrustRecovery = false
            helperVersionMismatch = Self.versionMismatch(installed: installation.version)
            let observation = await client.observation()
            helperIsRunning = observation.isRunning
            return observation
        } catch {
            helperNeedsTrustRecovery = true
            helperAvailability = .missing(reason: error.localizedDescription)
            helperVersionMismatch = nil
            helperIsRunning = false
            return nil
        }
    }

    private func refresh() async {
        guard isPollingNeeded, !Task.isCancelled else { return }
        guard let observation = await refreshHelperAvailability() else { return }
        guard isPollingNeeded, !Task.isCancelled else { return }
        if environment == nil { environment = TetherKitLibrary.checkEnvironment() }
        let last = observation.lastStatus
        let sessionActive = last?.runState == .starting || last?.runState == .running
            || last?.runState == .stopping
        if !observation.isRunning || !sessionActive {
            guard !isBusy else { return }
            var final = last ?? .idle
            if !observation.isRunning, sessionActive {
                final.runState = .failed
                final.fatalMessage = L(.helperExitedUnexpectedly)
            }
            apply(status: final)
            networkState = .empty
            if shouldRefreshDevices() { await refreshDevices(reportErrors: false) }
            return
        }

        do {
            let fresh = try await client.sessionStatus()
            guard isPollingNeeded, !Task.isCancelled else { return }
            apply(status: fresh)
        } catch {
            let latest = await client.observation()
            if latest.isRunning {
                helperNeedsTrustRecovery = true
                helperAvailability = .missing(reason: error.localizedDescription)
            }
            return
        }
        guard isPollingNeeded, !Task.isCancelled else { return }
        if isDetailsWindowVisible {
            if let feed = try? await client.drainFeed() {
                guard isPollingNeeded, isDetailsWindowVisible, !Task.isCancelled else { return }
                apply(feed: feed)
            }
        }
        guard isPollingNeeded, !Task.isCancelled else { return }

        // helper 在会话占用设备时跳过字符串读取，运行中也能安全发现新增设备。
        if shouldRefreshDevices() {
            await refreshDevices(reportErrors: false)
        }

        guard isPollingNeeded, !Task.isCancelled else { return }
        if !status.systemInterface.isEmpty {
            let connectionID = status.connectionID
            let fresh = try? await client.queryNetwork(interface: status.systemInterface)
            guard isPollingNeeded, !Task.isCancelled, connectionID == status.connectionID else { return }
            networkState = fresh ?? .empty
        } else {
            networkState = .empty
        }
    }


    var usageRecords = TrafficUsage.read()

    func reloadUsage() {
        usageRecords = TrafficUsage.read()
        if let today = status.todayUsage { mergeUsage(today) }
    }

    private func mergeUsage(_ entry: DailyUsage) {
        guard !usageRecords.contains(entry) else { return }
        usageRecords.removeAll { $0.id == entry.id }
        usageRecords.append(entry)
    }

    func apply(status fresh: SessionStatus) {
        if let today = fresh.todayUsage { mergeUsage(today) }
        if let saved = fresh.savedConfiguration,
           saved.mode != .none, NetworkValidator.validationMessage(for: saved) == nil {
            let draftUnchanged = networkConfiguration == savedNetworkConfiguration
            if saved != savedNetworkConfiguration { rememberNetworkConfiguration(saved) }
            if draftUnchanged { networkConfiguration = saved }
        }
        if fresh.connectionID != status.connectionID {
            networkTestState = .idle
            networkState = .empty
            appliedNetworkConfiguration = nil
        }
        appliedNetworkConfiguration = fresh.appliedConfiguration
        if let configuration = fresh.appliedConfiguration {
            if configuration != savedNetworkConfiguration { rememberNetworkConfiguration(configuration) }
        }
        defer {
            previousStatus = fresh
            status = fresh
        }

        // 记录/清除连接时刻，用于显示已连接时长。
        if fresh.runState == .running, sessionStartedAt == nil {
            sessionStartedAt = Date()
        } else if fresh.runState != .running, fresh.runState != .stopping {
            sessionStartedAt = nil
        }

        guard isDetailsWindowVisible,
              let previous = previousStatus,
              fresh.runState == .running,
              fresh.monotonicNanos > previous.monotonicNanos else {
            if isDetailsWindowVisible, fresh.runState != .running {
                throughput = .zero
            }
            return
        }

        // 分母用库那边的单调时钟差，而不是我们的轮询周期 —— 两次拉取之间的
        // 真实间隔会被调度拉长，用固定周期当分母会把速率算高。
        let seconds = Double(fresh.monotonicNanos - previous.monotonicNanos) / 1_000_000_000
        guard seconds > 0 else { return }

        let sample = ThroughputSample(
            timestamp: Date(),
            receiveBitsPerSecond: Double(fresh.rxBytes &- previous.rxBytes) * 8 / seconds,
            transmitBitsPerSecond: Double(fresh.txBytes &- previous.txBytes) * 8 / seconds,
            receivePacketsPerSecond: Double(fresh.rxFrames &- previous.rxFrames) / seconds,
            transmitPacketsPerSecond: Double(fresh.txFrames &- previous.txFrames) / seconds)

        throughput = sample
        throughputHistory.append(sample)
        if throughputHistory.count > Self.historyCapacity {
            throughputHistory.removeFirst(throughputHistory.count - Self.historyCapacity)
        }
    }

    private func apply(feed: HelperFeed) {
        if !feed.logs.isEmpty {
            logs.append(contentsOf: feed.logs)
            if logs.count > Self.logCapacity {
                logs.removeFirst(logs.count - Self.logCapacity)
            }
        }
        droppedLogCount += feed.droppedLogs
    }

    // MARK: - 动作

    /// 已连接时长；未连接时为 nil。
    var connectedDuration: TimeInterval? {
        sessionStartedAt.map { Date().timeIntervalSince($0) }
    }

    var selectedDevice: DeviceDescriptor? {
        if let selectedDeviceID {
            return devices.first { $0.id == selectedDeviceID }
        }
        return devices.first(where: { status.runState == .running
            && $0.summary == status.deviceDescription }) ?? devices.first
    }

    var canSwitchDevice: Bool {
        guard status.runState == .running, let selectedDevice else { return false }
        return selectedDevice.summary != status.deviceDescription
    }

    /// 过滤 + 连续去重后的日志。
    ///
    /// 折叠放在过滤**之后**：原始流里两条相同的 INFO 之间可能夹着 trace，
    /// 按原始顺序折叠会失效，而用户在某个级别下看到的相邻重复才是该合并的。
    /// O(n) 重算，n ≤ 2000，对每秒一次的刷新节奏无感。
    var filteredLogs: [CollapsedLogEntry] {
        var collapsed: [CollapsedLogEntry] = []
        for entry in logs where entry.level >= logLevelFilter {
            if let last = collapsed.last, last.matches(entry) {
                collapsed[collapsed.count - 1].absorb(entry)
            } else {
                collapsed.append(CollapsedLogEntry(entry))
            }
        }
        return collapsed
    }

    /// 启动会话。会弹一次系统授权框。
    func startSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let network = networkConfiguration
        if let message = NetworkValidator.validationMessage(for: network) {
            alertMessage = message
            return
        }
        var configuration = SessionConfiguration(mtu: requestedMTU,
                                                 adoptDeviceMAC: adoptDeviceMAC,
                                                 networkConfiguration: network)
        // 指定总线 + 地址而不是 VID/PID：同型号两台设备 VID/PID 完全一样，
        // 只有总线地址能区分。
        if let device = selectedDevice {
            configuration.busNumber = device.busNumber
            configuration.deviceAddress = device.deviceAddress
        }

        configuration.language = L10n.language
        configuration.usageDevice = selectedDevice
        await authorized { [self] authorization in
            throughputHistory.removeAll()
            try await client.startSession(authorization: authorization,
                                          configuration: configuration)
            var pending = SessionStatus.idle
            pending.runState = .starting
            pending.networkPhase = .waitingForInterface
            apply(status: pending)
        }
    }

    /// 停止会话。
    func stopSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        await authorized { [self] authorization in
            try await client.stopSession(authorization: authorization)
            apply(status: .idle)
            networkState = .empty
            networkTestState = .idle
        }
    }

    /// 下发网络配置。
    func applyNetworkConfiguration() async {
        guard !isBusy else { return }
        let interface = status.systemInterface
        guard !interface.isEmpty else {
            alertMessage = L(.interfaceNotReadyYet)
            return
        }
        if let message = NetworkValidator.validationMessage(for: networkConfiguration) {
            alertMessage = message
            return
        }

        let configuration = networkConfiguration
        isBusy = true
        defer { isBusy = false }

        await authorized { [self] authorization in
            try await client.applyNetwork(authorization: authorization, interface: interface,
                                          configuration: configuration)
            appliedNetworkConfiguration = configuration
            rememberNetworkConfiguration(configuration)
            // 立刻回读一次，让界面马上反映真实生效的地址，而不用等下一个轮询周期。
            networkState = (try? await client.queryNetwork(interface: interface)) ?? .empty
        }
    }

    /// 撤销网卡上的 IP 配置。
    ///
    /// 单独一个动作而不是「上网方式选『不配置』再点应用」：撤销是一次性操作，
    /// 混进模式选择器里会让人以为选中它就已经生效了。
    func clearNetworkConfiguration() async {
        guard !isBusy else { return }
        let interface = status.systemInterface
        guard !interface.isEmpty else { return }

        isBusy = true
        defer { isBusy = false }

        await authorized { [self] authorization in
            try await client.applyNetwork(authorization: authorization, interface: interface,
                                          configuration: NetworkConfiguration(mode: .none))
            networkState = (try? await client.queryNetwork(interface: interface)) ?? .empty
        }
    }

    /// 按需测试当前虚拟网卡的实际连通性。
    func testNetwork() async {
        guard !networkTestState.isRunning else { return }
        let interface = status.systemInterface
        guard status.runState == .running, !interface.isEmpty, networkState.hasAddress else {
            alertMessage = L(.networkTestNotReady)
            return
        }

        let connectionID = status.connectionID
        networkTestState = .running
        let results = await NetworkTester.run(
            interfaceName: interface,
            sourceAddress: networkState.address,
            router: networkState.router)
        let observation = await client.observation()
        let current = observation.isRunning ? try? await client.sessionStatus() : nil
        guard connectionID == status.connectionID,
              current?.connectionID == connectionID, current?.runState == .running else {
            networkTestState = .idle
            return
        }
        networkTestState = .finished(results)
    }

    /// 刷新只枚举设备，不停止或重建现有会话；失败时保留原列表。
    func refreshDevices(reportErrors: Bool = true) async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        let started = ContinuousClock.now
        lastDeviceRefresh = .now
        defer { isRefreshingDevices = false }
        do {
            let fresh = try await client.listDevices()
            if !reportErrors {
                guard isPollingNeeded, !Task.isCancelled else { return }
            }
            devices = fresh.map { device in
                guard let known = devices.first(where: {
                    $0.id == device.id && $0.vendorID == device.vendorID
                        && $0.productID == device.productID
                }) else { return device }
                var reconciled = device
                if reconciled.manufacturer.isEmpty { reconciled.manufacturer = known.manufacturer }
                if reconciled.product.isEmpty { reconciled.product = known.product }
                if reconciled.serial.isEmpty { reconciled.serial = known.serial }
                return reconciled
            }
            if let selectedDeviceID, !fresh.contains(where: { $0.id == selectedDeviceID }) {
                self.selectedDeviceID = nil
            }
        } catch {
            if reportErrors { alertMessage = error.localizedDescription }
        }
        // 手动扫描很快时仍保留短暂反馈；自动发现不增加等待。
        if reportErrors {
            let remaining = Duration.milliseconds(600) - (ContinuousClock.now - started)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
    }

    /// 用户明确点击切换后，按顺序停旧会话、启动目标设备；全程使用固定快照。
    func switchDevice() async {
        guard !isBusy, canSwitchDevice, let device = selectedDevice else { return }
        let network = networkConfiguration
        if let message = NetworkValidator.validationMessage(for: network) {
            alertMessage = message
            return
        }
        var configuration = SessionConfiguration(
            vendorID: device.vendorID, productID: device.productID,
            busNumber: device.busNumber, deviceAddress: device.deviceAddress,
            mtu: requestedMTU, adoptDeviceMAC: adoptDeviceMAC, networkConfiguration: network)
        configuration.language = L10n.language
        configuration.usageDevice = device
        isBusy = true
        defer { isBusy = false }
        do {
            // 在中断旧连接之前确认目标仍然存在。
            let fresh = try await client.listDevices()
            guard fresh.contains(where: { $0.id == device.id
                && $0.vendorID == device.vendorID && $0.productID == device.productID }) else {
                alertMessage = L(.switchDeviceMissing)
                return
            }
            try await client.switchSession(authorization: Data(), configuration: configuration)
            networkState = .empty
            networkTestState = .idle
            throughputHistory.removeAll()
            selectedDeviceID = device.id
            var pending = SessionStatus.idle
            pending.runState = .starting
            pending.networkPhase = .waitingForInterface
            apply(status: pending)
        } catch {
            let observation = await client.observation()
            if observation.isRunning {
                if let fresh = try? await client.sessionStatus() { apply(status: fresh) }
            } else if let final = observation.lastStatus {
                apply(status: final)
            } else {
                var failed = SessionStatus.idle
                failed.runState = .failed
                failed.fatalMessage = error.localizedDescription
                apply(status: failed)
            }
            alertMessage = error.localizedDescription
        }
    }

    /// 距上次枚举是否已经够久。顺带记下这一次的时刻。
    private func shouldRefreshDevices() -> Bool {
        let now = ContinuousClock.now
        if let last = lastDeviceRefresh, now - last < Self.deviceRefreshInterval {
            return false
        }
        lastDeviceRefresh = now
        return true
    }

    func clearLogs() {
        logs.removeAll()
        droppedLogCount = 0
    }

    /// App 自带的库版本 —— 「特权组件应该是哪一版」的标准答案。
    ///
    /// 用**库**的版本而不是 Info.plist 里的 App 版本号：装到
    /// /Library/PrivilegedHelperTools 的正是 .app 里那份 libtetherkit 的拷贝
    /// （见 build-gui.sh 组装载荷那段），两边同源才比得准。而且 `swift run`
    /// 的裸可执行文件根本没有 bundle，读 Info.plist 那条路上这个判断会整个失效。
    ///
    /// 敢用 `static let` 缓存是因为它是编译期烧进 dylib 的常量，进程活着的时候
    /// 不会变 —— 与上面几个必须跟着语言走的提示语不同。顺手把版本号提取也
    /// 做掉：这个判断挂在每秒一次的轮询上，没必要每次都重跑一遍正则。
    private static let bundledVersion =
        HelperConstants.semanticVersion(of: TetherKitLibrary.versionInfo.version)

    /// 装着的组件和 App 自带的是不是同一版。一致时返回 nil。
    private static func versionMismatch(installed: String) -> HelperVersionMismatch? {
        let installedVersion = HelperConstants.semanticVersion(of: installed)
        guard installedVersion != bundledVersion else { return nil }
        return HelperVersionMismatch(installed: installedVersion, expected: bundledVersion)
    }

    /// 安装 / 更新特权组件（引导卡上的「一键安装」按钮，以及版本对不上时
    /// 管理行里的「更新特权组件」—— 更新就是照着 .app 里的载荷重装一遍）。
    func installHelper() async {
        await maintainHelper(.install, prompt: Self.helperInstallPrompt,
                             expectAvailable: true,
                             failureNotice: L(.installScriptRanButUnreachable))
    }

    /// 卸载特权组件（仪表盘底部的「卸载…」，确认框在 UI 层）。
    ///
    /// bootout 给 helper 发 SIGTERM —— 正在跑的会话被优雅停掉、虚拟网卡销毁，
    /// 这一点必须在确认框里向用户说明。卸载完成后界面自然回到安装引导页。
    func uninstallHelper() async {
        await maintainHelper(.uninstall, prompt: Self.helperUninstallPrompt,
                             expectAvailable: false,
                             failureNotice: L(.uninstallScriptRanButStillAlive))
    }

    /// 安装与卸载共用的执行壳：授权（复用缓存令牌）→ AEWP 执行 → XPC 探测
    /// 兜底确认。
    ///
    /// 授权与日常特权操作共用同一条权利（system.privilege.admin），令牌缓存
    /// 因此天然通用：装完 5 分钟内接着点「连接」不会再弹框。缓存令牌已过期的
    /// 罕见路径由 AEWP 自己弹系统默认文案的框兜底，不为它专造一次「带自定义
    /// 文案的重新授权」。
    ///
    /// ★ 成败判定 ★
    ///   AEWP 不给退出码（见 HelperInstaller 的说明），所以脚本跑完后用真实的
    ///   XPC 往返确认，兜几秒等 launchd 完成登记与按需拉起（或注销生效）。
    ///   方向由 expectAvailable 决定：安装等「连得上」，卸载等「连不上」。
    ///   失败时把脚本输出的末尾放进弹窗 —— 真实原因几乎总写在结尾。
    private func maintainHelper(_ action: HelperInstaller.Action,
                                prompt: String,
                                expectAvailable: Bool,
                                failureNotice: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        // 载荷与 AEWP 先行自检 —— 缺哪样都必须在弹授权框**之前**说清楚。
        if let failure = HelperInstaller.preflightError() {
            alertMessage = failure.localizedDescription
            return
        }

        let output: String
        do {
            let token: AuthorizationToken
            if let cached = cachedAuthorization {
                token = cached
            } else {
                token = try AuthorizationBroker.requestAuthorization(prompt: prompt)
                cachedAuthorization = token
            }
            defer { withExtendedLifetime(token) {} }
            output = try await HelperInstaller.run(action, with: token)
        } catch AuthorizationBroker.Failure.userCancelled {
            return
        } catch HelperInstaller.Failure.userCancelled {
            return
        } catch {
            alertMessage = error.localizedDescription
            return
        }

        for _ in 0..<6 {
            await refresh()
            if helperAvailability.isAvailable == expectAvailable { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
        alertMessage = L(.scriptOutput, failureNotice, Self.tail(of: output))
    }

    // MARK: - 检查更新

    /// 手动检查（App 菜单「检查更新…」）。结果无论好坏都弹窗。
    func checkForUpdates() async {
        guard let current = UpdateChecker.currentVersion else {
            updateCheckResult = .unavailable
            return
        }
        do {
            let latest = try await UpdateChecker.fetchLatestRelease()
            remember(latest)
            if UpdateChecker.isNewer(latest.version, than: current) {
                availableUpdate = latest
                updateCheckResult = .updateAvailable(latest)
            } else {
                availableUpdate = nil
                updateCheckResult = .upToDate(current: current)
            }
        } catch {
            updateCheckResult = .failed(error.localizedDescription)
        }
    }

    /// 自动检查：每天至多一次、失败静默、发现新版只点亮管理行的提示，
    /// 绝不弹窗打断 —— 更新是「顺便知道」的事，不值得一个模态框。
    /// `defaults write com.tetherkit.app updateCheckDisabled -bool YES` 可关掉。
    private func checkForUpdatesQuietly() async {
        guard let current = UpdateChecker.currentVersion else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.updateCheckDisabledKey) else { return }
        if let last = defaults.object(forKey: Self.updateLastCheckedKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }

        guard let latest = try? await UpdateChecker.fetchLatestRelease() else { return }
        defaults.set(Date(), forKey: Self.updateLastCheckedKey)
        remember(latest)
        availableUpdate = UpdateChecker.isNewer(latest.version, than: current) ? latest : nil
    }

    /// 把查到的最新版记进 defaults —— 明天的启动被节流拦住时，提示不该消失。
    private func remember(_ release: UpdateChecker.Release) {
        let defaults = UserDefaults.standard
        defaults.set(release.version, forKey: Self.updateKnownVersionKey)
        defaults.set(release.pageURL.absoluteString, forKey: Self.updateKnownPageKey)
    }

    /// 启动时恢复上次查到的新版提示。升级完成后（当前版本 ≥ 记住的版本）
    /// 自然失效，不需要任何清理逻辑。
    private func restoreKnownUpdate() {
        guard let current = UpdateChecker.currentVersion,
              let version = UserDefaults.standard.string(forKey: Self.updateKnownVersionKey),
              let page = UserDefaults.standard.string(forKey: Self.updateKnownPageKey),
              let pageURL = URL(string: page),
              UpdateChecker.isNewer(version, than: current) else { return }
        availableUpdate = UpdateChecker.Release(version: version, pageURL: pageURL)
    }

    private static let updateCheckDisabledKey = "updateCheckDisabled"
    private static let updateLastCheckedKey = "updateLastCheckedAt"
    private static let updateKnownVersionKey = "updateKnownVersion"
    private static let updateKnownPageKey = "updateKnownPageURL"

    /// 取输出的末尾几行给弹窗用 —— 完整输出可能很长，真实原因几乎总在结尾。
    /// 顺手剥掉脚本里的 ANSI 颜色码，弹窗里那是乱码。
    private static func tail(of output: String,
                             maxLines: Int = 10, maxCharacters: Int = 700) -> String {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "",
                                                options: .regularExpression)
        let lines = plain.split(separator: "\n", omittingEmptySubsequences: true)
        var kept = lines.suffix(maxLines).joined(separator: "\n")
        if kept.count > maxCharacters {
            kept = String(kept.suffix(maxCharacters))
        }
        return kept.isEmpty ? L(.scriptNoOutput) : kept
    }

    /// 普通操作由 helper 的 XPC 信任约束保护，不申请管理员凭据。
    private func authorized(_ body: @escaping (Data) async throws -> Void) async {
        do {
            try await body(Data())
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
