# TetherKit 调试交接记录

更新时间：2026-10-15

## 当前源码位置

本仓库已移动到：

```text
/Users/xiahua/xiahua/my/TetherKit
```

这是完整 Git 仓库，`.git`、当前分支、远端配置、未提交修改、构建目录和已生成的 App 都已保留。

当前 Git 状态是**未提交修改**，基线提交：

```text
1ded051 chore(release): v0.1.5 —— 特权组件版本对不上时可一键更新
```

远端：`https://github.com/XiaoMiku01/TetherKit.git`

当前分支：`main`。仓库是浅克隆，但 Git 历史和远端配置仍然保留。

请先读仓库的 `AGENTS.md`。本次用户还要求：所有解释、沟通及新代码注释使用简体中文；只改必要代码，不额外重构，不根据历史日志增加猜测性修复。未经明确要求不要委派其他 agent。

## 用户需求

2026-10-15 新增的四项连接体验优化已整理为实施提案：
[连接流程与授权优化](docs/提案/2026-10-15-连接流程与授权优化/README.md)。
包含自动应用网络配置、连接阶段与失败提示、可信 App 日常免密码、高级设置及成功配置持久化。
用户将切换 AI 实施；当前仅完成文档，四项均未实现，请按提案维护进度和验收记录。

1. TetherKit 当前运行会导致电脑发热，需要定位并降低 CPU 占用。
2. 菜单栏不要显示连接状态、上下行速率、IP、连接时长等状态详情。
3. 菜单栏保留固定图标，点击后提供打开主窗口的入口。
4. 主窗口关闭后不要继续刷新主页面，也不要继续做界面状态轮询。
5. 主窗口打开时每秒刷新一次即可。
6. 网络连接必须继续由特权 helper 保持；关闭主窗口不能断开连接。
7. 修改不能破坏正常连接、收发和主窗口功能。

## 已定位的发热原因

旧版进程中观察到：

- 普通 App 进程 CPU 约 60%–90%，主线程有大量 SwiftUI ViewGraph/Charts 渲染。
- root helper 进程 `/Library/PrivilegedHelperTools/com.tetherkit.helper` CPU 约 80%–100%。
- helper 日志当时几乎没有流量，因此主要问题不是业务流量本身。

核心原因在 `src/core/bridge.cc` 的 RX 注入线程：

- RX 队列为空时，旧代码最多自旋 64 次，然后调用 `std::this_thread::yield()`。
- `yield()` 只是让出当前时间片，线程仍然是可运行状态，在空闲机器上会很快再次运行。
- 暂停分支同样只 `yield()`，所以暂停时也会持续消耗 CPU。
- 结果是空闲时 RX worker 持续忙等，helper 会烧掉一个 CPU 核。

USB 日志中的历史 `LIBUSB_ERROR_NO_DEVICE` 不是当前高 CPU 的主要原因；代码已经会在连续保活失败后拆除设备和数据通道，没有继续针对这个历史日志做猜测性修改。

## 已完成的代码修改

### C++ 数据路径降 CPU

文件：

- `src/core/bridge.cc`
- `include/tetherkit/core/bridge.h`

修改：

- RX 暂停分支改为 `sleep_for(1ms)`。
- RX 空队列短暂自旋耗尽后改为 `sleep_for(1ms)`。
- 保留 `rx_spin_before_yield` 字段名，避免无必要的 ABI/接口改动。
- 正常收发、队列、批处理和 XPC 协议没有改动。

影响：

- 空闲时线程真正睡眠，不再持续 runnable。
- 首包可能增加约 1ms 加调度延迟。
- 正常有流量时仍然按原批处理路径收发。

### SwiftUI/App 轮询生命周期

文件：

- `gui/Sources/TetherKitApp/AppModel.swift`
- `gui/Sources/TetherKitApp/TetherKitApp.swift`
- `gui/Sources/TetherKitApp/Views/MenuBarPanel.swift`
- `gui/Sources/TetherKitIPC/Models.swift`

修改：

- 主窗口可见时每 1 秒刷新一次。
- 主窗口关闭时取消轮询任务；在途 XPC 返回也不会继续更新已关闭窗口的界面。
- 主窗口重新打开时立即开始新一轮刷新，并清掉旧的吞吐采样，避免显示后台期间的假速率。
- 菜单栏图标固定为 `network` 图标，不再绑定状态和速率数据。
- 菜单栏面板删除连接状态、速率、IP、时长等详情，只保留操作入口和已有基础操作。
- 网络会话没有在窗口关闭时停止，仍由 helper 独立持有。
- 吞吐历史采样由 120 点调整为 60 点，仍保留约 60 秒历史。

文档同步修改：

- `README.md`
- `README.zh-CN.md`
- `docs/GUI-ARCHITECTURE.md`

## 已完成验证

### C++

命令：

```bash
cmake --build work/build -j4
ctest --test-dir work/build --output-on-failure
```

结果：23/23 通过。包含 bridge 收发、暂停、背压、停止等测试；需要 root/真实 feth 的测试按项目既有条件跳过。

### Swift GUI

命令：

```bash
TETHERKIT_LIB_DIR="$PWD/work/build/lib" swift test --package-path gui
```

结果：17/17 通过。包含 IPC 模型、授权生命周期、版本和本地化测试。

### 空闲 CPU 探针

使用测试专用阻塞链路运行 0.5 秒，RX 线程没有真实网络流量：

```text
wall=0.500 cpu=0.006440 ratio=0.013
```

进程 CPU 时间约占 1.3%，说明空闲 RX 线程已不再持续忙等。该探针只验证离线桥接线程，没有替代真实 USB/feth 测试。

### 2026-10-14 真实 App/helper 验证与界面动画修复

用户已关闭旧版进程。通过管理员授权对话框安装并注册了新特权组件，当前
`/Library/PrivilegedHelperTools/com.tetherkit.helper` 正常由 LaunchDaemon 拉起。
连接手机后 helper 空闲约 0.3%–0.4% CPU，说明数据路径忙等修复已在真实 helper 上生效。

主窗口打开时发现 App 曾持续约 16%–19% CPU。`sample` 显示 SwiftUI/QuartzCore 持续布局，
根因为 `StatusRing` 运行状态下的 `repeatForever` 呼吸动画。该动画只有装饰作用，
不影响连接或收发；已移除，保留连接建立等过渡状态的旋转提示。重新打包并启动后，
App 采样降至约 7%–9% CPU；Swift GUI 17 个测试通过，Release 打包自检通过。

当前运行版本为：

```text
/Users/xiahua/xiahua/my/TetherKit/dist/TetherKit.app
```

### 2026-10-14 按需运行详情窗口

进一步验证发现，主窗口常驻吞吐图表和实时日志会让 SwiftUI 长期维护 Charts 与日志
列表。已将 `ThroughputCard` 与 `LogCard` 移到独立的「运行详情」窗口：主窗口只保留
连接状态、设备选择和网络配置，并在状态卡提供打开详情的按钮。

轮询现在按窗口职责拆分：主窗口读取连接状态、设备和网络配置；运行详情窗口打开时
才读取日志并生成吞吐历史。两个窗口都关闭时停止 App 侧 XPC 轮询；网络会话仍由 helper
持有。详情窗口关闭后吞吐历史清空，重新打开从新采样开始。

真机 UI 冒烟已完成：当前运行会话仍保持 `feth0` 和 DHCP 地址，主窗口可见且能看到
「打开运行详情」按钮；打开后显示吞吐/日志，关闭后回到轻量主窗口。最终打包版本在
主窗口打开、详情窗口关闭时 App CPU 采样约 0%–1.8%，打开详情窗口时约 4.2%，
helper 约 0.4%。

### Release App

已使用 Release C++ 库和 Swift release 构建生成：

```text
dist/TetherKit.app
```

构建命令：

```bash
cmake -S . -B work/build-release \
  -DTETHERKIT_BUILD_TESTS=OFF \
  -DTETHERKIT_BUILD_BENCHMARKS=OFF \
  -DCMAKE_BUILD_TYPE=Release
cmake --build work/build-release -j4
TETHERKIT_BUILD_DIR="$PWD/work/build-release" ./gui/Scripts/build-gui.sh
```

构建脚本已完成 dylib/libusb 内嵌、rpath 清理、ad-hoc 签名和签名自检。

注意：本次构建的 C++ 库使用宿主默认部署目标 macOS 26.0，Swift 目标是 macOS 14.0，因此链接器提示部署版本不一致。当前产物只作为本机调试构建；不能据此声称它能在 macOS 14/15 运行。若需要对外分发，重新设置一致的部署目标并测试。

`git diff --check` 曾通过。没有新增正式回归测试；现有测试和临时性能探针不能证明所有 GUI 生命周期行为。

## 尚未完成或需要后续 AI 继续验证

1. **系统 helper 已更新并正常响应。** 2026-10-15 核实，其核心 dylib 与当前源码版 App 的载荷一致；无需再次安装。此前“尚未替换”的记录已过时。
2. 安装 helper 需要管理员密码。不要在没有用户明确操作的情况下停止现有 helper 或中断当前网络连接。
3. 需要用新 App 做一次真实 UI smoke test：
   - 打开主窗口，确认约每秒刷新；
   - 关闭主窗口，确认不再发送周期性 XPC 刷新；
   - 从菜单栏打开主窗口，确认立即刷新；
   - 确认连接仍由 helper 保持。
   上一次已启动新构建的 App，但 UI 工具按 bundle ID 选择时因新旧两个 App 同名而失败，尚未完成窗口关闭/重开验证。后续应指定新 App 的完整路径。
4. 当前菜单栏面板仍保留语言菜单和退出按钮。如果用户最终要求“菜单栏只留打开主窗口一个按钮”，后续可继续删掉这两个控件，并同步 README 文案。
5. 真实 USB 设备上的吞吐、首包延迟和有流量时的 helper CPU 仍需复测。
   root helper 未能做线程采样，因为需要管理员权限；CPU 探针仅有修改后的结果，没有做旧代码在相同探针下的前后对照。
6. 没有提交本次修改；后续 AI 可以先执行：

```bash
cd /Users/xiahua/xiahua/my/TetherKit
git status --short
git diff --check
```

## 移动后的构建注意事项

原仓库路径是 `/Users/xiahua/Documents/Codex/2026-10-14/tetherkit/work/TetherKit-src`。
本次是整体移动，构建缓存原样保留；CMake 的 `work/build`、`work/build-release` 和 SwiftPM 的 `gui/.build` 里含有旧的绝对路径，不能直接认为搬迁后仍可增量构建。不要为了复用缓存改业务代码。

建议用新缓存目录重建：

```bash
cd /Users/xiahua/xiahua/my/TetherKit
cmake -S . -B work/build-handoff-tests \
  -DTETHERKIT_BUILD_TESTS=ON \
  -DTETHERKIT_BUILD_BENCHMARKS=OFF \
  -DCMAKE_BUILD_TYPE=Debug
cmake --build work/build-handoff-tests -j4
ctest --test-dir work/build-handoff-tests --output-on-failure
TETHERKIT_LIB_DIR="$PWD/work/build-handoff-tests/lib" \
  swift test --package-path gui --scratch-path work/swift-handoff-tests
```

原 `dist/TetherKit.app` 的运行依赖已内嵌，构建目录 rpath 已移除；它与包含绝对路径的编译缓存不同。仓库中的 `work/idle_probe.cc` 和 `work/idle_probe` 是临时探针，不是项目正式测试，当前会出现在 Git 的未跟踪文件里，不要误提交探针可执行文件。

## 2026-10-15 当前安装与运行状态

- 已卸载 Homebrew 的 `tetherkit` GUI formula；独立的 `tetherkit-cli` 仍保留。
- 最新源码 App 已 Release 打包并启动，路径为 `dist/TetherKit.app`；签名自检通过。
  `/Applications/TetherKit` 的 Finder 别名已由 App 确认就绪，指向该源码版。
- helper PID 86896 从昨晚持续运行，核心 dylib 与 App 内载荷 SHA256 一致：
  `75fa720fd0dafcc64f7fcf0d493c0a71897bae594e43248e2ecd39d55955e6be`。
  此前“brew 卸载导致 helper 消失”的判断错误，formula 没有卸载 helper 的 hook。
- 只读 XPC 验证：协议号 3、版本 0.1.5、会话 `idle`、RNDIS 设备数 0。
  当前 App PID 26087、helper PID 86896，CPU 快照均为 0.0%；这不是有流量时的性能结果。
- App 包含按点击运行的“测试网络”功能，检测网关、DNS 和常用网站 HTTPS；
  新按钮的实际 UI 与手机链路尚未验证。UI 自动化读取超时，不代表 App 未运行。
- 本次 Swift 构建 scratch 实际路径为 `/Users/xiahua/xiahua/my/work/swift-current-release`。
  打包使用现有 Release C++ 库；旧 CMake 缓存仍不可直接增量构建。
  macOS 部署目标不一致的警告仍存在，此产物用于本机验证。
- 本次没有停止或重装 helper，也没有改路由；尚未提交代码。

## 重要安全/运行提示

- 搬迁时曾观察到旧版 Homebrew App（PID 60387，CPU 约 55%）和旧 helper（PID 98913，CPU 约 100%）。这是历史快照，已被上方 2026-10-15 的运行状态取代，不能据此判断当前仍在运行旧版。
- 新 App 的 helper 载荷在：

```text
/Users/xiahua/xiahua/my/TetherKit/dist/TetherKit.app/Contents/Library/HelperTools
```

- 如需用户自行安装新 helper，可在确认会中断/重建连接的影响后执行：

```bash
cd /Users/xiahua/xiahua/my/TetherKit
sudo ./gui/Scripts/install-helper.sh
```

- 安装后应检查：

```bash
ps -axo pid,pcpu,args | rg 'TetherKit.app/Contents/MacOS/TetherKit|com.tetherkit.helper'
sudo launchctl print system/com.tetherkit.helper
```


## 2026-10-15 连接优化实施补充

连接自动配网、阶段/错误与重试、高级配置及成功配置持久化、可信 App 免密码运行的代码已实现。
协议号 4，Swift 回归 31/31；详情、签名探针与尚未完成的真机验收见连接提案末尾。
本轮已检测到 HONOR 设备并在新 UI 观察到 DHCP 地址及网络测试响应；之后设备离场。
系统 helper 已采用持久信任，未登记的旧状态探针无法再查询它；后续请用被登记的 App 观察状态。
打包会改变 App cdhash，因此最新磁盘构建必须重新授权登记后才能验证重启。不要为只改测试或文档重复替换 App。

最终构建已打开并触发恢复授权。用户已明确同意更新组件与持久信任，当前等待系统密码框由用户完成；手机共享当前未检出。完成后继续 App 重启、单次连接自动 DHCP、关闭窗口保持连接、超过 5 分钟免密码验收。此阶段不要再次打包改变 cdhash。

用户随后已完成最终构建授权。已真机验证一次点击自动 DHCP（10.81.9.225/24，网关/DNS 10.81.9.165）、App 退出后 helper 保持连接、新 App 进程免密码断开/重连、主窗口关闭后网关 ping 3/3 成功；关闭窗口采样 App 0%、helper 约0.2%。撤销后重连仍自动 DHCP。详情已追加到提案。此后未再次修改二进制。

超过安装授权 5 分钟后的免密码断开、重连与自动 DHCP 已实测通过（helper 已运行5:35，App 为重启后的新进程）。最终保留 feth0 10.81.9.225/24、网关/DNS 10.81.9.165 的正常连接。剩余真机项为重插/拔线竞态、真实 DHCP 超时、静态 IP/DNS、不同用户与满负载吞吐。

## 2026-10-15 设备刷新与切换补充

用户要求按“连接中可刷新和选择新设备，明确点击切换才断旧连新并自动配网”实施，代码已完成。
`DeviceCard` 解锁运行期刷新与设备选择、标记当前连接；`AppModel` 运行时仍每2秒发现设备，刷新失败保留列表。
切换先验证网络草稿及目标存在，再按 stop → start 固定目标/配置快照执行；停止失败不启动新会话，启动失败清除旧连接显示。
新增 `HelperConnection` 边界与7项设备切换测试，总计38/38通过；Release App 已打包，未提交。
当前仅重建磁盘 App，尚未更新系统信任或主动断开现有会话；已向用户询问是否现在更新（会短暂断开），等待回复。两台真实设备切换未实测。

用户已明确同意启用设备刷新/切换新版并更新信任、重新连接。已退出旧 App、打开新版并点击「更新特权组件」，当前等待用户在系统授权框完成验证；授权完成后继续连接和运行期刷新真机验证。不要再次打包改变 cdhash。

设备刷新/切换新版已启用：用户完成管理员授权，初次安装在 launchctl bootstrap 返回5；旧会话已优雅停机，之后再次注册成功，root信任记录更新为09:11:57。未根据单次失败增加猜测性修复。
已实际重新连接HONOR并自动DHCP至feth0 10.81.9.225/24，网关/DNS10.81.9.165。运行中刷新按钮可点击、设备行标记“当前连接”；点击刷新后连接与IP保持，绑定源地址ping网关3/3成功。最终保留正常连接。双设备切换仍只有离线测试，尚未实测。

本轮界面反馈：网络测试结果可展开/收起，新测试自动展开；设备手动刷新圆形进度+“刷新中…”至少600ms，自动发现不延时。38项测试和Release打包通过。已正常断开旧会话、打开新版并触发系统授权框，等待用户完成后继续重连与UI验收；不要再次构建改变身份。

用户随后要求网络测试结果带总览：全部成功外部显示“全部通过”并默认收起；有失败显示异常数量、自动展开、失败项置顶，组内保留检测顺序。已实现，40项Swift测试通过；保留刷新loading至少600ms。该总览构建正在Release打包，尚未启用，不要把上一版已授权当成本轮新哈希已登记。

最终总览构建已打包、由用户完成授权并重连HONOR，feth0保持10.81.9.225。真机网络测试显示“测试结果·全部通过”且详情默认收起，手动展开和收起均成功；已点击设备刷新，连接保持。40项测试通过，异常计数/稳定排序经离线验证，真实异常自动展开尚未人为制造故障实测。最终保留连接、结果收起状态，未再打包。

## helper按需生命周期实施

用户已批准“连接时启动、断开后退出，退出App但连接中则保留helper”的方案。代码已实现，协议5，47项Swift测试通过，Release打包/签名和脚本/plist检查通过。核心C++未改。
App空闲只读root公开安装身份和运行状态，设备枚举与预检本地完成；语言不唤醒helper。helper断开清理回复后500ms缓冲，每秒生命周期检查退出；失败保留终态后退出，活动/切换保留进程。
新增root所有0644的公开安装身份（不含私有网络配置），原信任0600不变；运行状态路径见docs/GUI-ARCHITECTURE.md新节。根权限仍由私有信任+真实XPC身份校验。
当前已退出旧App并打开最终构建，点击更新后等待用户在系统授权框确认。授权后需要真机验证：空闲主窗口不启动helper、连接创建进程、退出App仍联网、断开后进程消失且UI不唤醒、快速重连。不要重复构建导致再次换身份。

按需生命周期真机结果：最终构建已授权启用，48项Swift通过。空闲主窗口和手动刷新后0/3/6/9秒采样均无helper；连接创建helper并自动DHCP至10.81.9.225。退出App后同一helper PID保留，网关ping2/2。断开后0/2/4/6秒采样无helper，窗口轮询没有重新拉起。
验证中修复了新helper丢失设备名称的回归：生产会话工厂先枚举记住名称再打开会话，App跨进程刷新按ID+VID/PID回填已知字符串（离场清除）。这次修复后最终构建已再次授权启用，未再修改二进制。
随后真实设备离场：helper记录连续保活LIBUSB_ERROR_NO_DEVICE失败，清理feth并退出；App重新打开从本地记录显示原始错误，没有helper进程，ifconfig无feth残留。用户要求继续，已请求重新接手机/开启共享，等待最后的名称重启和快速重连验证。最终保持未连接状态，不要把设备离场误报成代码崩溃。

最终收尾：用户重新接上手机后，HONOR名称/序列号正常，自动DHCP至10.81.9.97/24，网关/DNS10.81.9.165。快速断开立即重连成功；退出App后helper PID43792保留，绑定feth地址ping网关2/2，重开App名称完整。随后断开，0/2/4秒均无helper进程；再次连接启动新PID43846并自动DHCP成功。空闲语言切换不唤醒helper，已恢复中文。最终保留正常连接，48项测试结果不变，未重新打包、未提交Git。

## 2026-10-15 每台手机每日流量与高级设置收纳

用户批准实施按手机、按天统计，并指定设备行中间显示今日用量，MTU/MAC收到次级页面。现已完成，协议6。新增TrafficUsage/UsageLedger和每日流量弹窗，DeviceCard的今日数字可点击，设备高级设置弹窗保留原会话参数及连接中只读规则。
helper复用1秒生命周期检查读取原有累计字节，变化每分钟保存，断开/失败/跨日/优雅退出强制保存；不增加收发线程工作或空闲进程。Runtime停机后保留最终桥接统计用于最后一批记账，接口名照常清空。日界约1秒采样误差，断电/SIGKILL最多可能丢约一分钟数据。无序列号不混记，身份键散列，历史文件路径和口径见GUI架构新节。
使用新构建缓存work/build-usage（旧work/build-release缓存含搬迁前路径，不能直接重建），C++ Werror Release/23项CTest通过；Swift53项通过；Release App签名验证和git diff --check通过。最终构建已启用，不要再打包改变cdhash。
真机：HONOR今日由0增长，明细显示日期、下载/上传/合计，位置截图已核对；断开后文件记录下载6058/上传15392，helper退出；重开App仍显示21KB，重连显示22KB继续累计。最终构建退出App期间网关1200B ping4/4成功，重开App今日由36KB增至53KB，证明App退出仍统计。高级设置弹窗在连接中MTU/MAC禁用，已收起，最终保留10.81.9.97/24、网关/DNS10.81.9.165正常连接，helper PID45991。
CPU记录在work/usage-cpu-before.json、usage-cpu-after.json、usage-cpu-steady.json：旧版20秒CPU时间增加0.10秒（约0.5%单核），新版操作UI期间20秒增加0.14秒（约0.7%），新版稳定30秒增加0.19秒（约0.6%）。这是当前轻负载短时观察，不是严格满负载对照，也不承诺零开销。未做跨午夜真实等待/双真实设备/满负载吞吐，日期、跨重连、不同设备、保存频率、断开最终采样由离线测试覆盖。
两次更新时首次launchctl bootstrap均返回5，旧会话已停机，重试后注册成功；第二次由本agent在UI确认重试，最终身份已登记。没有扩大范围去修改安装脚本重试策略。未提交Git。

## 序列号默认隐藏与截图更新（未提交）

DeviceRow将SN默认替换为固定长度圆点，独立眼睛按钮可切换显示/隐藏，退出视图或序列号变化时恢复隐藏，不持久化显示偏好。隐藏状态下辅助功能树中不包含真实序列号，设备选择按钮与眼睛按钮分开，避免嵌套按钮。只改展示，不改变设备身份或每日记账。53项Swift通过，Release打包并启用；组件bootstrap首次5，UI重试成功。真机验证默认隐藏、点击显示、再点击隐藏、连接自动DHCP至10.81.9.48。README三张fork截图均已重新保存，主图不含明文SN；当前保持连接且SN隐藏。用户要求继续不提交/推送。
