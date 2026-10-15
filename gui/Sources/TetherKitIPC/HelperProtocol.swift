import Foundation

/// App 调用 helper 的 XPC 接口。
///
/// 运行权限由 listener 核验真实 XPC 用户与安装时登记的代码哈希。
/// `authorization` 参数沿用旧方法形状，不再携带管理员令牌。
/// 安装、卸载和更新仍通过 App 的管理员安装器进行。
/// 错误继续使用 (String?, Bool)，避免跨 XPC 传不可解码的 NSError。
@objc public protocol TetherKitHelperProtocol {
    /// 连通性探测。**不单独申请管理员授权** —— 否则「没装」和「没授权」两种失败会混在一起。
    func helperVersion(reply: @escaping (String) -> Void)

    /// 运行环境预检（root 状态、feth 的创建期 sysctl、MTU 上限）。
    func environment(reply: @escaping (Data?, String?) -> Void)

    /// 枚举 RNDIS 设备。
    ///
    /// 由 helper 而不是 App 来枚举：App 侧也能枚举（不需要 root），但会话跑起来
    /// 之后设备已被 helper 独占，App 再去读字符串描述符只会失败。统一走 helper
    /// 就没有这个不一致。
    func listDevices(reply: @escaping (Data?, String?) -> Void)

    /// 启动 RNDIS 会话。**需要可信连接。**
    func startSession(authorization: Data, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void)

    /// 在同一 helper 内停旧连新，中间不进入空闲退出。
    func switchSession(authorization: Data, configuration: Data,
                       reply: @escaping (String?, Bool) -> Void)

    /// 停止会话并销毁虚拟网卡。**需要可信连接。**
    func stopSession(authorization: Data, reply: @escaping (String?, Bool) -> Void)

    /// 取会话状态快照。
    func sessionStatus(reply: @escaping (Data?, String?) -> Void)

    /// 给网卡下发上网方式（DHCP / 静态 IP / 撤销）。**需要可信连接。**
    ///
    /// DHCP 模式下这一调用会阻塞到拿到租约或超时（库内部上限 10 秒），
    /// 因此 helper 侧不能把它排在会串行阻塞其它请求的队列上。
    func applyNetwork(authorization: Data, interface: String, configuration: Data,
                      reply: @escaping (String?, Bool) -> Void)

    /// 回读网卡真实生效的 IP 状态。
    func queryNetwork(interface: String, reply: @escaping (Data?, String?) -> Void)

    /// 取走 helper 侧积压的日志与提示。
    func drainFeed(reply: @escaping (Data?) -> Void)

    /// 告诉 helper 用哪种语言渲染它产生的文字。**不单独申请管理员授权** —— 它只影响
    /// 文案，改不了任何行为。
    ///
    /// 为什么必须有这一条：helper 以 root 跑在 launchd 下，看不到用户的语言
    /// 偏好，而它产生的提示（「会话已停止」）与 libtetherkit 的日志都会原样
    /// 显示在 App 的日志卡里。不同步的话界面是一种语言、日志是另一种。
    ///
    /// 参数是 `Language` 的 rawValue（`"chinese"` / `"english"`）。传字符串而
    /// 不是整数：将来加语言时，旧 helper 收到不认识的值会原样忽略，而不是
    /// 把它当成某个碰巧存在的枚举值。
    func setLanguage(_ rawValue: String, reply: @escaping () -> Void)
}
