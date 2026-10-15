## 本分支的修改与开发思路

本分支基于 [XiaoMiku01/TetherKit](https://github.com/XiaoMiku01/TetherKit) 开发。原项目提供了用户态 RNDIS 驱动和 USB 到系统网卡的基础架构。我的修改主要围绕日常使用体验：**连接少几步，问题看得懂，不用的时候少占资源。**

### AI 开发说明

本分支的代码修改由 **OpenAI Codex（GPT-6）** 根据我的需求和反馈完成。我负责提出需求、确认使用效果，并参与真机验证；AI 负责修改代码、补充测试、构建和执行验证步骤。此说明仅指本分支的修改，不代表原项目的代码也由 AI 编写。

### 修改了什么，为什么修改

| 方面 | 修改前 | 本分支的变化 | 修改原因 |
|---|---|---|---|
| 连接流程 | 连接设备和应用网络配置分开操作。 | 点击连接后自动应用 DHCP 或上次成功的配置；显示连接、获取地址等阶段，以及失败原因和重试入口。 | 让一次连接尽量直接得到可用网络，失败时也知道卡在哪里。 |
| 授权方式 | 特权操作依赖反复进行管理员授权。 | 管理员一次登记当前用户和当前 App 构建，日常连接使用持久信任；安装、更新、卸载仍需管理员授权。 | 减少重复弹窗，同时把特权访问限定在已批准的用户和构建上。 |
| 后台与资源 | 特权组件常驻；界面刷新和 RX 空队列循环可能产生不必要的开销。 | 连接时启动组件，断开或终止性失败后退出；连接中退出 App 仍保持网络。关闭主窗口停止主页面轮询，菜单栏保留固定入口，图表和日志移入详情；RX 空队列短暂自旋后休眠。 | 不用的功能不应持续渲染、轮询，或空耗一个 CPU 核。 |
| 设备管理 | 连接期间设备发现和选择受到限制。 | 连接中可刷新设备，刷新有进度反馈；明确点击切换才更换设备，并保留跨组件重启的设备名称。 | 查看、选择另一台手机，不应立即打断当前连接。 |
| 网络诊断 | 需要展开较多结果才能判断情况。 | 先显示测试总览：全部通过默认收起，有异常自动展开，失败项放在最前面。 | 先让人知道有没有问题，再提供排查细节。 |
| 用量与设置 | 没有按手机统计每日用量，MTU、MAC 参数一直占据主界面。 | 设备行显示今日用量，点击查看每日下载、上传和合计；MTU、MAC 收入高级设置。 | 常用信息直接可见，很少调整的参数按需打开。 |

### 当前界面截图

以下截图来自本分支连接真实手机后的实际界面。

**主界面：**设备行直接显示今日用量；序列号默认隐藏，点击眼睛图标才显示。高级设备参数通过独立入口打开。

![本分支：连接成功并显示今日用量的主界面](docs/assets/fork-main-zh.jpg)

**每日流量：**点击今日用量，查看每天的下载、上传和合计。

![本分支：每日流量明细](docs/assets/fork-usage-zh.jpg)

**设备高级设置：**MTU、MAC 选项不再常驻主界面；连接期间保持只读。

![本分支：设备高级设置](docs/assets/fork-settings-zh.jpg)

### 发布可下载的 Release

`Release` 工作流会检出标签对应的源码，构建并测试，打包 App 和命令行工具，再将两个附件及 `SHA256SUMS.txt` 上传到本仓库的 GitHub Releases，不会同步原作者的 Homebrew tap。

1. 如果 GitHub 提示当前 fork 未启用工作流，先在 Actions 页面启用。
2. 将 `CMakeLists.txt` 的 `VERSION` 改成新版本，提交发布修改并推送到 `main`。新标签对应的源码必须包含这次工作流修改。
3. 创建并推送相同版本的标签。例如，**先将 VERSION 改为 0.2.0**，然后执行：

   ```bash
   git tag -a v0.2.0 -m "TetherKit 0.2.0"
   git push origin v0.2.0
   ```

4. 在 `Actions → Release` 查看结果。成功后，到 `Releases → Assets` 下载 App zip；GitHub 自动生成的“Source code”附件只有源码，不是 App。

也可在 `Actions → Release → Run workflow` 填写**已存在且版本一致的标签**手动运行，适合标签触发没有执行的情况；已有 Release 不会被覆盖。手动按钮需要本工作流先推送到默认分支才会出现。

当前附件支持 **macOS 26+、Apple Silicon**。App 内嵌 libusb，命令行附件仍需 Homebrew libusb。App 使用临时签名，未经 Apple 公证。只有实际云端构建成功后才能确认本次发布可下载，本地检查通过不代表 GitHub Actions 已运行成功。

### 我的开发思路

1. **先解决真实使用中的麻烦。** 从发热、重复授权、手动配 IP、操作反馈不清楚这些问题入手，把它完善成适合每天使用的工具。
2. **让工作量跟实际使用对应。** 界面可见时刷新，需要连接时运行组件；流量统计复用已有计数器和生命周期检查，没有增加抓包或逐包记账。
3. **常规操作简单，有影响的操作明确。** 记住成功配置，切换设备需要主动确认操作；技术参数和诊断细节放在次级页面，仍然保留排查能力。
4. **沿用原项目的架构，做有针对性的改进。** 保留 C++ 用户态驱动、C ABI、SwiftUI 和特权组件的职责划分；通过测试和真机连接验证修改，不重新替换已经可用的基础。

### 统计口径、取舍与验证范围

- 每日用量只统计**这台 Mac 经 TetherKit 传输的流量**，包含局域网流量，不代表手机全部流量，也不等于运营商账单。设备通过 USB VID/PID 和序列号的散列识别，没有序列号时不按型号混记；从启用此功能后开始累计。
- 按 Mac 本地日期记账，约每秒采样一次。普通运行期间，有变化才最多每分钟保存一次，断开、失败、跨天、正常停机时立即保存；异常终止可能丢失约一分钟尚未保存的用量。
- 降低 CPU 占用也有取舍：RX 空闲等待可能给首包增加约 1 ms 加调度延迟。一次轻负载短时采样中，helper 约占单核 CPU 的 0.6%，此前短时基线约 0.5%；这不是严格的吞吐对照，也不承诺零开销。
- 本轮 **53 项 Swift 测试、23 项 CTest 通过**，并用真实手机验证自动 DHCP、刷新、重连、组件退出和用量保存。双真实手机切换、静态 DNS 及满负载吞吐仍需进一步真机验证。下文原项目的性能数据属于历史结果，不能当作本分支的新压测结论。

**安装说明：**下文保留的 Homebrew 命令及上游链接对应原项目发行渠道，不会安装本分支的修改。要使用本分支，可在发布后从[本仓库 Releases](https://github.com/xiahua007-dev/TetherKit/releases)下载预编译 App（macOS 26+、Apple Silicon），或从当前仓库源码通过 GUI 构建脚本打包，具体见下文构建说明。

---

<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="TetherKit 图标">
</p>

# TetherKit

[English](README.md) | **简体中文**

**HoRNDIS 在新系统上用不了的替代方案 —— 不装内核扩展，让 Android USB 网络共享在 macOS 上重新可用。**

TetherKit 是一个 **macOS 用户态 RNDIS 驱动**：把 RNDIS 设备（Android 手机的 USB 网络共享、
Windows Phone、嵌入式 Linux gadget 等）变成一张系统可见的网卡，**不需要 kext、不需要
DriverKit、不用关 SIP、不用开发者账号**。Apple Silicon 与 Intel 走同一条代码路径。
自带图形界面，「选设备 → 连接 → 配 IP」三步点击；也提供命令行工具 `tetherkit-cli`。

*以下为修改前的上游界面，当前版本请参见上方截图。*

![修改前的上游主界面](docs/assets/screenshot-main-zh.jpg)

- **USB 侧**：[libusb](https://libusb.info/) 异步批量传输，完整实现 RNDIS 主机侧状态机。
- **网卡侧**：macOS 的 `feth`（`if_fake`）虚拟网卡对 + BPF，直接读写原始以太帧。
- **无内核代码**：纯用户态 C++23，不需要 kext、不需要 DriverKit、不需要关 SIP。

> ⚠️ **状态**：全部模块已实现，210 个测试用例（10408 条断言）在普通构建与
> ThreadSanitizer 构建下均通过。端到端已用 Android 手机压测：**RX 约 326 Mbps /
> TX 约 240~300 Mbps，双向零重传**（USB 2.0 高速，理论上限 426 Mbps）。
> 测量方法与完整结果见 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)，
> 验证清单见 [AGENTS.md](AGENTS.md) 第 6 节。

---

## 从 HoRNDIS 过来的？

如果你是因为 **HoRNDIS 升级完 macOS 就用不了了**，或者在 Apple Silicon 上它一直显示
「已阻止的软件」、根本找不到那个「允许」按钮 —— TetherKit 就是为这种情况写的。

[HoRNDIS](https://github.com/jwise/HoRNDIS) 好用了很多年，它本身没有问题。问题在于它是一个
**内核扩展**，而这正是 macOS 一直在收紧的地方：

| | HoRNDIS | TetherKit |
|---|---|---|
| 是什么 | 内核扩展（kext） | 普通的用户态程序 |
| Apple Silicon | 要先进恢复模式把安全策略降到「降低安全性」并重启，第三方 kext 才**有可能**加载 | 什么都不用改 —— 在系统眼里它根本不是驱动 |
| SIP | 通常需要关掉或削弱 | 不动 |
| 升级 macOS 之后 | kext 可能直接不加载，往往要重新批准或重新编译 | 就是个 App，没有什么要重新批准的 |
| 出问题的最坏情况 | 内核崩溃（kernel panic） | 进程退出 |
| 上游状态 | 最新发布 9.2（2024 年 8 月）；[「MacOS Sonoma not supported」](https://github.com/jwise/HoRNDIS/issues/169) 仍未关闭 | 在积极开发 |

TetherKit 是从另一头解决同一个问题：不去教内核说 RNDIS，而是**在用户态**通过 libusb 把
RNDIS 说完，再借 `feth` 虚拟网卡对把以太帧交给系统。内核自始至终没有加载我们的任何代码。

**代价说在前面**：网卡由一个需要你启动的 App 创建（连接本身不受界面退出影响 —— 它跑在一个
很小的特权后台组件里）；吞吐受限于用户态拷贝而不是 USB 链路。不过实测下来这并没有成为瓶颈，
数据见上面。

---

## 为什么需要它

macOS 内核**没有** RNDIS 驱动。插上开了 USB 网络共享的 Android 手机，系统不会出现新网卡。
既有方案要么写 kext（需要关 SIP 或降低 Apple Silicon 的安全策略、签名门槛高、系统更新易
失效），要么走 Network Extension（需要开发者账号 + 系统扩展审批）。TetherKit 选择第三条
路：**在用户态同时扮演 USB 主机和网卡驱动**。

---

## 安装

**兼容性**：macOS 14 Sonoma、15 Sequoia、26 Tahoe，Apple Silicon（M1–M4）与 Intel 都支持；
命令行工具最低到 macOS 13.3 Ventura。**什么都不用关** —— SIP 保持开启，Apple Silicon 的
安全策略保持「完全安全性」。

```bash
# 图形界面 TetherKit.app（macOS 14+）
brew install XiaoMiku01/tap/tetherkit

# 命令行工具 tetherkit-cli（macOS 13.3+）
brew install XiaoMiku01/tap/tetherkit-cli
```

两个 formula 都从源码构建，`libusb` 会被自动带上。tap 仓库在
[XiaoMiku01/homebrew-tap](https://github.com/XiaoMiku01/homebrew-tap)。

图形界面装完这样启动（首次启动会自动在「应用程序」里建立 Finder 别名，
之后在聚焦里搜 TetherKit 即可直接启动）：

```bash
open "$(brew --prefix)/opt/tetherkit/TetherKit.app"
```

首次运行界面会引导安装特权组件：点「安装特权组件」、输一次管理员密码即可。

升级：

```bash
brew upgrade tetherkit tetherkit-cli
```

> **旧版用户注意**：自 v0.1.2 起 `tetherkit` 这个 formula 名归图形界面，
> 命令行改名 `tetherkit-cli`（二进制同名）。之前装过命令行的请
> `brew uninstall tetherkit && brew install tetherkit-cli`。

也可以从 [Releases](https://github.com/XiaoMiku01/TetherKit/releases) 直接下预编译产物
（仅 arm64）。但它们**没有签名**，浏览器下载后会被 Gatekeeper 隔离，得手动解除：

```bash
xattr -d com.apple.quarantine tetherkit-cli     # 命令行
xattr -dr com.apple.quarantine TetherKit.app    # 图形界面（递归）
```

介意这一步的话就走上面的 Homebrew，或者按下文「[从源码构建](#从源码构建)」自己构建
—— 本地构建的产物不带隔离属性。

---

## 图形界面

TetherKit.app（SwiftUI）点击一次「连接」就会自动应用 DHCP 或上次成功的静态配置。
网络配置收进「高级网络设置」。吞吐与日志
放在单独的「运行详情」窗口里，需要时再打开。

它由两部分组成：`TetherKit.app` 以**普通用户身份**运行，需要 root 的操作交给一个
由 launchd 按需拉起的特权组件 `tetherkit-helper`。helper 仅在连接期间运行，断开或连接失败清理完成后自动退出；单纯打开 App、刷新设备或切换语言不会启动它。关闭窗口或退出 App 时，已有连接继续由 helper 保持。安装或更新时经管理员授权，登记
本机用户与这个 App 构建；日常连接通过 XPC 代码身份核验，不再要求管理员密码。
重新构建 App 后需授权更新组件。打包 App 启用 Hardened Runtime，并通过库加载约束
锁定内嵌依赖。

特权组件的安装载荷内嵌在 .app 里（`Contents/Library/HelperTools/`），首次运行时
界面会引导安装（见上文「安装」）；偏好终端的话效果完全相同：

```bash
sudo ./gui/Scripts/install-helper.sh
```

卸载：仪表盘底部有「卸载特权组件…」按钮（终端等价命令
`sudo ./gui/Scripts/uninstall-helper.sh`）。

连接期间可以刷新 USB 设备列表、选择另一台设备；点击「切换到此设备」才会断开
当前设备、连接所选设备并自动配网。仅刷新或选择不会影响当前连接，MTU 与 MAC
选项仍在连接期间锁定。

界面里可以配置**上网方式**：

| 方式 | 说明 |
|---|---|
| 自动（DHCP） | 交给系统的 IPConfiguration，租约、DNS、路由全部自动配好。绝大多数手机都自带 DHCP 服务器，推荐 |
| 静态 IP | 手动指定 IP、子网掩码、网关与 DNS。输入时即时校验（含子网掩码的连续性） |

另有一个「让所有流量默认走这张网卡」开关。不开时只有绑定到本网卡的流量走它；
本机没有别的可用网络时通常不需要开 —— 系统会自己把它选为主服务。

**后台运行**：关闭主窗口后 App 驻留菜单栏（程序坞图标隐藏），菜单栏不显示
连接状态详情，点击可打开主窗口。主窗口只负责连接控制；需要查看吞吐图表和实时日志时，
打开「运行详情」窗口。详情窗口打开时每秒刷新一次，关闭后停止采集这些详情；
已建立的连接由特权组件持有，即使退出界面也不会断。

**检查更新**：菜单「TetherKit → 检查更新…」手动查；App 也会每天自动查一次
（只访问 GitHub 的公开 Releases API，不上报任何信息），发现新版在仪表盘
底部点亮一条提示。更新本身仍走 `brew upgrade` 或源码重编 —— 免证书分发下
自动替换 .app 会被 Gatekeeper 拦下，所以刻意只查不换。不想要自动检查：
`defaults write com.tetherkit.app updateCheckDisabled -bool YES`。

**界面语言**：菜单「TetherKit → 语言」可选「跟随系统 / 中文 / English」，
菜单栏面板里也有同一个开关。切换**立即生效**，不需要重启 App —— 库产生的
日志行也会跟着换（语言会一并同步给特权组件）。默认跟随系统语言。

**要求**：macOS 14+（命令行部分仍支持 13.3+）。实现细节与设计取舍见
[docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md)。

---

## 命令行工具

图形界面之外还有命令行工具 `tetherkit-cli`（安装见上文）：

```bash
# 先看看设备有没有被识别（**不需要 root**）
tetherkit-cli --list

# 启动驱动
sudo tetherkit-cli

# 另开一个终端，给新出现的网卡配 IP（RNDIS 设备通常自带 DHCP 服务器）
sudo ipconfig set feth0 DHCP
ipconfig getifaddr feth0
```

> 上面的命令都按已安装（`tetherkit-cli` 在 PATH 里）来写。从源码构建的话
> 换成 `./build/bin/tetherkit-cli` 即可。

启动成功后程序会打印它创建的网卡名与后续命令。按 `Ctrl-C` 优雅退出
（会先让设备退出 RNDIS，再销毁网卡）。

常用选项（完整列表见 `--help`）：

| 选项 | 说明 |
|---|---|
| `--list` | 列出识别到的 RNDIS 设备后退出，不需要 root |
| `--vid` / `--pid` | 指定设备（十六进制），用于多设备场景 |
| `--stats 1000` | 每秒打印一行吞吐/丢包统计 |
| `--log debug` | 打开协议交互细节日志 |
| `--max-transfer-kb` | 吞吐的主要调优旋钮，见 [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |
| `--lang zh\|en\|auto` | 界面语言，默认 `auto`（见下） |

**语言**：默认按 `TETHERKIT_LANG` → `LC_ALL` → `LC_MESSAGES` → `LANG` 依次推断，
取第一个非空值，以 `zh` 开头算中文、其余算英文。

```bash
tetherkit-cli --lang en --help     # 显式指定
TETHERKIT_LANG=en tetherkit-cli --list
```

> ⚠️ `sudo` 是否把 `LANG` 透传给命令取决于 sudoers 的 `env_keep`，因此
> `sudo tetherkit-cli` 未必跟随你的终端语言 —— 那时显式写 `--lang`。

### 为什么需要 root

| 操作 | 需要 root？ | 原因 |
|---|---|---|
| 创建 / 销毁 `feth` | ✔ | 内核对 `SIOCIFCREATE2` / `SIOCSDRVSPEC` 有 `proc_suser` 检查 |
| 打开 `/dev/bpf*` | ✔ | 节点是 `0600 root:wheel`，且 macOS **没有** FreeBSD 的 `access_bpf` 组 |
| libusb 声明 RNDIS 接口 | ✘ | macOS 内核**没有** RNDIS 驱动，接口本来就没人占。非沙箱命令行程序不需要 root、也不需要 entitlement |

也就是说 root 是网卡侧的要求，不是 USB 侧的。`--list` 因此不需要 root。

---

## 故障排查

| 现象 | 原因与对策 |
|---|---|
| `--list` 找不到设备 | ① 换一根**数据线**（很多线只供电）；② 在设备上开启「USB 网络共享 / USB tethering」；③ 解锁手机并信任本机。用 `system_profiler SPUSBDataType` 确认系统是否看到该设备 |
| `声明 RNDIS 数据接口失败 [libusb: LIBUSB_ERROR_ACCESS]` | 接口被别的东西占了。检查是否装过 HoRNDIS 之类的第三方 kext，或有别的用户态程序在用该设备 |
| `创建 feth 虚拟网卡需要 root` | 用 `sudo` 运行 |
| `sysctl net.link.fake.hwcsum 当前是 1，要求 0` | 这批开关在 feth **创建时被快照**，创建后改无效。按提示先 `sudo sysctl -w net.link.fake.hwcsum=0` 再启动 |
| `ipconfig set feth0 DHCP` 拿不到地址 | 确认设备侧的网络共享真的开着；用 `--stats 1000` 看 TX 有没有帧发出去、RX 有没有回包 |
| 网卡配好了但上不了网 | 默认路由还指向原来的网卡。`sudo route -n change default $(ipconfig getoption feth0 router)`，注意这会顶掉现有默认路由 |
| 吞吐远低于预期 | 看启动日志里的「设备聚合上限 N 包」与「链路批量写」两项，再对照 [docs/PERFORMANCE.md](docs/PERFORMANCE.md) 的排查表 |
| 重启后网卡不见了 | `ipconfig set` 建立的是**临时**服务，只存活到下一次网络配置变更，且不出现在系统设置里。这是 macOS 的限制，不是 bug |

### 常见疑问

**Android 的 USB 网络共享在 macOS 上到底能不能用？**
开箱即用是不能的 —— macOS 不带 RNDIS 驱动，插上开了 USB 网络共享的手机，系统里不会多出
任何网卡。TetherKit 补的就是这一块。

**要关 SIP 吗？Apple Silicon 上要降安全策略吗？**
都不用。那些是**内核扩展**的要求。TetherKit 是普通程序，内核不会加载它的任何代码；需要
特权的只是一个后台小组件，安装时输一次管理员密码，之后不再打扰。

**HoRNDIS 显示「已阻止的软件」、没有「允许」按钮，能修吗？**
那是 macOS 在拒绝加载第三方 kext，不是 kext 自己能解决的。Apple Silicon 上想加载它，必须
先进恢复模式降低安全策略。TetherKit 从根上绕开了这一整类问题。

**M1 / M2 / M3 / M4 能用吗？**
能。Apple Silicon 与 Intel 走同一条代码路径，除了编译目标之外没有任何架构相关的东西。

**我的设备支持吗？**
只要它暴露 RNDIS 接口就行：多数开了 USB 网络共享的 Android 手机、Windows Phone，以及
Linux 的 `g_ether` / `u_ether` USB gadget（树莓派 Zero、BeagleBone 等）。
跑 `tetherkit-cli --list` 就能确认，**不需要 root**。

**iPhone 的 USB 共享需要它吗？**
不需要。macOS 原生支持 iPhone 的 USB 网络共享，TetherKit 面向的是它不覆盖的那些设备。

---

## 架构

```
        ┌──────────────────────────── macOS 内核 ────────────────────────────┐
        │                                                                    │
        │   IP 栈 / 路由 / DHCP 客户端                                        │
        │        │                                                           │
        │        ▼                                                           │
        │   ┌─────────┐   if_fake peer 对   ┌─────────┐                       │
        │   │  feth0  │ ◄─────────────────► │  feth1  │                       │
        │   │(系统侧) │                     │(驱动侧) │                       │
        │   └─────────┘                     └────┬────┘                      │
        │    配 IP/路由                          │ BPF                       │
        └────────────────────────────────────────┼───────────────────────────┘
                                                 │ read()/write() 原始以太帧
        ┌────────────────────────────────────────┼───────────────────────────┐
        │                     TetherKit（用户态） │                           │
        │                                        ▼                           │
        │   ┌──────────────────── 数据路径桥接 ─────────────────────┐         │
        │   │  TX: BPF 批量读 → 聚合多帧 → RNDIS_PACKET_MSG → bulk OUT│        │
        │   │  RX: bulk IN → 拆 RNDIS_PACKET_MSG → SPSC 队列 → BPF 写 │        │
        │   └───────────────────────────┬───────────────────────────┘         │
        │                               │                                     │
        │   ┌──────────── RNDIS 状态机 ──┴──────────────┐                      │
        │   │ INITIALIZE / QUERY / SET / KEEPALIVE /   │                      │
        │   │ RESET / INDICATE_STATUS / HALT           │                      │
        │   └───────────────────────────┬──────────────┘                      │
        │                               │                                     │
        │   ┌────────── libusb ─────────┴──────────────┐                      │
        │   │ 控制通道：SEND_ENCAPSULATED_COMMAND /     │                      │
        │   │           GET_ENCAPSULATED_RESPONSE      │                      │
        │   │ 通知通道：中断 IN（RESPONSE_AVAILABLE）    │                      │
        │   │ 数据通道：bulk IN / bulk OUT（异步池化）   │                      │
        │   └───────────────────────────┬──────────────┘                      │
        └───────────────────────────────┼─────────────────────────────────────┘
                                        │ USB
                                   ┌────┴─────┐
                                   │ RNDIS 设备 │
                                   └──────────┘
```

---

## 从源码构建

依赖：macOS 13.3+、Xcode 命令行工具（Apple clang 支持 C++23）、CMake ≥ 3.24、libusb 1.0。

```bash
brew install libusb cmake
```

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
```

产物：`build/bin/tetherkit-cli`。

### 构建图形界面

需要完整 Xcode 工具链。在上面的构建目录基础上：

```bash
cmake --build build --target gui        # 等价于 ./gui/Scripts/build-gui.sh
open dist/TetherKit.app
```

### 构建选项

| 选项 | 默认 | 说明 |
|---|---|---|
| `TETHERKIT_BUILD_TESTS` | `ON` | 构建单元测试 |
| `TETHERKIT_BUILD_BENCHMARKS` | `ON` | 构建性能基准 |
| `TETHERKIT_WARNINGS_AS_ERRORS` | `OFF` | 警告当错误 |
| `TETHERKIT_NATIVE_ARCH` | `OFF` | `-mcpu=native`，产物不可移植 |
| `TETHERKIT_ENABLE_LTO` | `OFF` | 链接时优化 |
| `TETHERKIT_ENABLE_ASAN` | `OFF` | AddressSanitizer |
| `TETHERKIT_ENABLE_UBSAN` | `OFF` | UndefinedBehaviorSanitizer |
| `TETHERKIT_ENABLE_TSAN` | `OFF` | ThreadSanitizer（**验证无锁数据结构必备**） |

### 测试

```bash
ctest --test-dir build --output-on-failure
```

无锁队列与多线程数据路径的正确性用 ThreadSanitizer 单独验证：

```bash
cmake -S . -B build-tsan -DTETHERKIT_ENABLE_TSAN=ON
cmake --build build-tsan -j
ctest --test-dir build-tsan --output-on-failure
```

### 性能基准

```bash
cmake -S . -B build-rel -DCMAKE_BUILD_TYPE=Release
cmake --build build-rel -j
./build-rel/bin/tetherkit_bench
```

汇总结果见 [docs/BENCHMARKS.md](docs/BENCHMARKS.md)。

---

## 文档

| 文档 | 内容 |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **总体设计**：为什么选 feth+BPF、模块划分、并发模型、拆除顺序、私有 ABI 的风险评估 |
| [docs/RNDIS-PROTOCOL.md](docs/RNDIS-PROTOCOL.md) | **协议参考**：字段偏移、状态码、OID、状态机、设备 quirk。含三条最容易搞错的规则 |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | **调优指南**：旋钮、怎么判断瓶颈、已知限制 |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | **基准结果**（自动生成）+ 测量方法与已知局限 |
| [docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md) | **图形界面**：进程与信任模型、数据流、实现约束、已实现/未实现清单 |
| [docs/GUI-SPIKE.md](docs/GUI-SPIKE.md) | **可行性验证**：为什么这么做特权提升，以及被排除的三条路线 |
| [AGENTS.md](AGENTS.md) | 实现备忘：已实测确认的环境事实、进度、**踩过的坑**、待验证清单 |

---

## 许可

见 [LICENSE](LICENSE)。

### 每台手机每日用量

设备行显示今日累计，点击可查看每日下载、上传与合计。按手机USB序列号区分，重连继续累计；无序列号时提示无法累计。仅统计此Mac通过TetherKit的流量，包含局域网流量，与运营商计费可能不同。MTU和MAC选项位于“设备高级设置”。统计复用已有计数器与检查周期，无连接时不运行；异常断电可能丢失约一分钟未保存用量。
