## About this fork: changes and development approach

[阅读本节中文版](README.zh-CN.md#本分支的修改与开发思路)

This fork builds on [XiaoMiku01/TetherKit](https://github.com/XiaoMiku01/TetherKit). The original project provides the user-space RNDIS driver and USB-to-network architecture. My changes focus on making it practical for everyday use: **connect with fewer steps, make failures understandable, and keep resource use low when nothing needs doing.**

### AI-assisted development

The code changes in this fork were implemented by **OpenAI Codex (GPT-6)**, based on my requirements and feedback. I defined the goals, reviewed the behavior, and participated in real-device testing; the AI handled code edits, test additions, builds, and verification steps. This describes the changes in this fork, not the authorship of the upstream project.

### What changed, and why

| Area | Before these changes | This fork | Reason |
|---|---|---|---|
| Connection setup | Connecting and applying network settings were separate steps. | Connect once to apply DHCP or the last successful configuration automatically; show connection and address-configuration stages, failures, and retry actions. | A connection should lead to a usable network, with enough information to locate a failure. |
| Authorization | Privileged operations relied on repeated administrator authorization. | An administrator registers the current user and exact App build once; normal connections use that persistent trust. Installation, updates, and removal still require administrator authorization. | Reduce repeated prompts while keeping privileged access tied to an approved user and build. |
| Background lifecycle | The privileged helper stayed resident; UI refresh and an empty RX loop could cause unnecessary work. | Start the helper on connection and exit after disconnect or terminal failure. An active connection survives quitting the App. Stop main-page polling when its window is closed; keep a fixed menu-bar entry and move charts/logs into details. The empty RX loop sleeps after a short spin. | Unused features should not keep rendering, polling, or consuming a CPU core. |
| Device selection | Device discovery and selection were restricted during a connection. | Refresh devices while connected, show refresh progress, and explicitly switch to another selected device; preserve device names across helper restarts. | Discovering or selecting another phone should not interrupt the current connection. |
| Network diagnostics | Results required more space and inspection. | Show a compact summary: collapse all-pass results, expand failures automatically, and place failures first. | Make the outcome visible before the troubleshooting detail. |
| Usage and advanced settings | No daily usage history per phone; MTU and MAC options stayed on the main page. | Show today's usage in each device row; open daily download/upload totals on click. Move MTU and MAC options into advanced settings. | Keep frequently useful information visible and rarely changed parameters out of the way. |

### Current interface

Captured from this fork running with a real phone connected (Chinese UI).

**Main window:** today's usage appears in the device row; the serial number is hidden by default and can be revealed with the eye button. Advanced device parameters are accessed separately.

![This fork: connected main window with daily usage](docs/assets/fork-main-zh.jpg)

**Daily usage:** click today's total to see daily download, upload, and combined usage.

![This fork: daily traffic history](docs/assets/fork-usage-zh.jpg)

**Advanced device settings:** MTU and MAC options are kept off the main page. They are read-only while connected.

![This fork: advanced device settings](docs/assets/fork-settings-zh.jpg)

### The approach behind these changes

1. **Start with everyday friction.** Heat, repeated authorization, manual IP setup, and unclear feedback drove the changes; the aim is a dependable daily tool.
2. **Match work to actual use.** The UI refreshes when visible, the helper runs while needed, and traffic accounting reuses existing counters and the existing lifecycle check. No packet capture or additional per-packet accounting was added.
3. **Keep routine actions simple and consequences explicit.** Successful defaults are remembered; device switching requires a deliberate action; technical controls and diagnostic details remain available on secondary screens.
4. **Build on the existing architecture.** Keep the C++ user-space driver, C ABI, SwiftUI App, and privileged-helper separation. Add focused tests and verify the real connection lifecycle instead of replacing working foundations.

### Scope and tradeoffs

- Daily usage covers **this Mac's traffic through TetherKit**, including local-network traffic, not all phone traffic or carrier-billed usage. Device identity uses a hash of USB VID/PID and serial number; devices without a serial number are not merged by model name. Tracking starts when this feature is enabled.
- Usage is grouped by the Mac's local date and sampled about once a second. Changed totals are saved at most once a minute during normal operation, and flushed on disconnect, failure, date change, or graceful shutdown. Abrupt termination can lose about a minute of unsaved usage.
- Lower CPU use has tradeoffs: the RX idle wait can add about 1 ms plus scheduling delay to the first packet. A short, light-load helper sample measured about 0.6% of one CPU core, against an earlier short baseline of about 0.5%; this is not a controlled throughput comparison or a promise of zero overhead.
- Verification for these changes: **53 Swift tests and 23 CTest entries passed**, plus real-phone checks for automatic DHCP, refresh, reconnect, helper exit, and usage persistence. Two-phone switching, static DNS behavior, and full-load throughput still need further hardware verification. The upstream benchmark results below are historical results, not a new benchmark of this fork.

**Installation note:** the Homebrew commands and upstream links retained below refer to the original project's distribution. They do not install this fork's changes. To use this fork, build this checkout with its GUI build script; see [the build instructions](#building-from-source).

---

<p align="center">
  <img src="docs/assets/icon.png" width="128" alt="TetherKit icon">
</p>

# TetherKit

**English** | [简体中文](README.zh-CN.md)

**A kext-free HoRNDIS alternative that brings Android USB tethering on macOS back to life.**

TetherKit is a **user-space RNDIS driver for macOS**: it turns an RNDIS device (Android USB
tethering, Windows Phone, embedded Linux gadgets, …) into a network interface that macOS can
see and use — with **no kernel extension, no DriverKit, no SIP changes and no developer
account**. Works the same on Apple Silicon and Intel. Ships with a GUI — pick a device,
connect, configure IP in three clicks — plus a command-line tool, `tetherkit-cli`.

*Upstream interface before this fork; see the current screenshots above.*

![Upstream main window before this fork](docs/assets/screenshot-main-en.jpg)

- **USB side**: asynchronous bulk transfers via [libusb](https://libusb.info/), with a complete
  host-side RNDIS state machine.
- **Interface side**: macOS `feth` (`if_fake`) virtual interface pairs + BPF, reading and
  writing raw Ethernet frames directly.
- **No kernel code**: pure user-space C++23. No kext, no DriverKit, no need to disable SIP.

> ⚠️ **Status**: all modules are implemented; 210 test cases (10,408 assertions) pass
> under both a normal build and a ThreadSanitizer build. End-to-end throughput,
> measured against a real Android phone: **~326 Mbps RX / ~240–300 Mbps TX, zero
> retransmits in both directions** (USB 2.0 high-speed; theoretical ceiling 426 Mbps).
> Methodology and full results: [docs/BENCHMARKS.md](docs/BENCHMARKS.md); the
> verification checklist lives in [AGENTS.md](AGENTS.md) §6 (Chinese).

---

## Coming from HoRNDIS?

If you landed here because **HoRNDIS stopped working after a macOS upgrade**, or because it
shows up as blocked/"Disabled Software" with no *Allow* button on your Apple Silicon Mac —
that is what TetherKit is for.

[HoRNDIS](https://github.com/jwise/HoRNDIS) was the answer for years, and it is good software.
But it is a **kernel extension**, and that is the part macOS keeps tightening:

| | HoRNDIS | TetherKit |
|---|---|---|
| Kind of software | Kernel extension (kext) | Plain user-space program |
| Apple Silicon | Needs *Reduced Security* set in Recovery + a reboot before a third-party kext can load at all | Nothing to change — it is not a driver as far as the OS is concerned |
| SIP | Commonly needs to be weakened | Untouched |
| After a macOS upgrade | Kext may stop loading; re-approval or a rebuild is often needed | Just an app; nothing to re-approve |
| Worst case failure | Kernel panic | The process exits |
| Upstream status | Latest release 9.2 (Aug 2024); ["MacOS Sonoma not supported"](https://github.com/jwise/HoRNDIS/issues/169) still open | Actively developed |

TetherKit reaches the same goal from the other side: instead of teaching the kernel to speak
RNDIS, it speaks RNDIS **in user space** over libusb, and hands the resulting Ethernet frames
to macOS through a `feth` virtual interface pair. The kernel never loads any of our code.

**What you give up:** the interface is created by an app you have to start (the connection
itself survives quitting the UI — it lives in a small privileged background component), and
throughput is bounded by user-space copies rather than the USB link. In practice that has not
been the limit: see the measured numbers above.

---

## Why this exists

The macOS kernel has **no** RNDIS driver. Plug in an Android phone with USB tethering enabled
and no new interface shows up. Existing approaches either ship a kext (requires weakening SIP
or Apple Silicon's security policy, a high signing bar, and breaks easily on system updates)
or go through a Network Extension (requires a developer account plus system-extension
approval). TetherKit takes a third route: **act as both the USB host and the network driver,
entirely in user space**.

---

## Installation

**Compatibility**: macOS 14 Sonoma, 15 Sequoia and 26 Tahoe, on Apple Silicon (M1–M4) and
Intel. The command-line tool goes back to macOS 13.3 Ventura. Nothing needs to be disabled —
SIP stays on, the Apple Silicon security policy stays at *Full Security*.

```bash
# The GUI, TetherKit.app (macOS 14+)
brew install XiaoMiku01/tap/tetherkit

# The command-line tool, tetherkit-cli (macOS 13.3+)
brew install XiaoMiku01/tap/tetherkit-cli
```

Both formulae build from source and pull in `libusb` automatically. The tap
lives at [XiaoMiku01/homebrew-tap](https://github.com/XiaoMiku01/homebrew-tap).

Launch the GUI like this (on first launch the app drops a Finder alias into
/Applications, so Spotlight can find and launch TetherKit from then on):

```bash
open "$(brew --prefix)/opt/tetherkit/TetherKit.app"
```

On first run the app walks you through installing the privileged helper —
one click, one admin password prompt.

To upgrade:

```bash
brew upgrade tetherkit tetherkit-cli
```

> **Note for existing users**: as of v0.1.2 the formula name `tetherkit` belongs
> to the GUI; the CLI was renamed `tetherkit-cli` (binary included). If you had
> the CLI installed, run `brew uninstall tetherkit && brew install tetherkit-cli`.

You can also grab prebuilt artifacts straight from
[Releases](https://github.com/XiaoMiku01/TetherKit/releases) (arm64 only). They are
**unsigned**, so a browser download gets quarantined by Gatekeeper and you have to
clear the attribute yourself:

```bash
xattr -d com.apple.quarantine tetherkit-cli     # CLI
xattr -dr com.apple.quarantine TetherKit.app    # GUI (recursive)
```

If that bothers you, use Homebrew above, or build it yourself as described in
[Building from source](#building-from-source) — locally built artifacts carry no
quarantine attribute.

---

## Graphical interface

TetherKit.app (SwiftUI) applies DHCP or your last successful static configuration
automatically when you click Connect. Network settings are under Advanced network settings. Throughput and logs are available in a separate runtime-details
window when you need them.

It comes in two pieces: `TetherKit.app` runs as a **normal user**, and anything
that needs root is handed to `tetherkit-helper`, a privileged component launched
on demand by launchd. The helper runs while connecting or connected, and exits after
disconnection or terminal-failure cleanup. Opening the app, scanning devices, or changing
language does not start it. Closing or quitting the app preserves an existing connection.
Installing or updating it requires administrator authorization and
registers the local user and this app build. Everyday connection operations then use XPC
code identity checks without asking for an administrator password. A rebuilt app needs
an authorized helper update. The packaged app uses Hardened Runtime and pins its bundled
libraries with library load constraints.

The helper's installation payload is embedded in the .app
(`Contents/Library/HelperTools/`); on first run the app walks you through
installing it (see Installation above). If you prefer the terminal, this is
exactly equivalent:

```bash
sudo ./gui/Scripts/install-helper.sh
```

Uninstall: the dashboard has an "Uninstall privileged component…" button at the
bottom (terminal equivalent: `sudo ./gui/Scripts/uninstall-helper.sh`).

While connected, you can refresh the USB device list and select another device.
Click “Switch to this device” to disconnect the current one, connect the selected
one, and apply network settings automatically. Refreshing or selecting alone keeps
the current connection. MTU and MAC settings remain locked while connected.

The app lets you choose how the virtual interface gets its address:

| Mode | Notes |
|---|---|
| Automatic (DHCP) | Handled by the system's IPConfiguration — lease, DNS and routes are all set up for you. Most phones ship a DHCP server, so this is the recommended choice |
| Static IP | Enter address, netmask, gateway and DNS yourself. Validated as you type, including netmask contiguity |

There is also a "route all traffic through this interface" switch. With it off,
only traffic explicitly bound to the interface uses it. You usually do not need
it — when no other network is available, macOS picks this interface as the
primary service on its own.

**Background mode**: closing the main window keeps the app in the menu bar
(the Dock icon is hidden). The status item does not show connection details and
provides an entry back to the main window. The main window only shows connection
controls; open "Runtime details" when you need the throughput chart and live log.
That window refreshes once per second while it is visible and stops collecting
those details when it is closed. The connection itself lives in the privileged
helper, so quitting the UI never drops it.

**Update check**: "TetherKit → Check for Updates…" checks on demand; the app also
checks once a day on its own (it only hits GitHub's public Releases API and
reports nothing), lighting up a notice at the bottom of the dashboard when a new
version is out. The update itself still goes through `brew upgrade` or a source
rebuild — with certificate-free distribution, auto-replacing the .app would be
blocked by Gatekeeper, so the app deliberately only checks, never swaps. To
disable the automatic check:
`defaults write com.tetherkit.app updateCheckDisabled -bool YES`.

**Interface language**: "TetherKit → Language" offers Follow system / 中文 /
English, and the menu bar panel carries the same switch. Changes take effect
**immediately** — no restart — and the log lines coming out of the library
follow along (the language is pushed to the privileged helper too). The default
is to follow the system language.

**Requires** macOS 14+ (the CLI still supports 13.3+). Design notes and
trade-offs are in [docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md).

---

## Command-line tool

Besides the GUI there is a command-line tool, `tetherkit-cli` (installation above):

```bash
# First check whether the device is recognized (**no root needed**)
tetherkit-cli --list

# Start the driver
sudo tetherkit-cli

# In another terminal, configure the new interface (RNDIS devices usually run a DHCP server)
sudo ipconfig set feth0 DHCP
ipconfig getifaddr feth0
```

> The commands above assume an installed `tetherkit-cli` (on your `PATH`). If you
> built from source, substitute `./build/bin/tetherkit-cli`.

On a successful start the program prints the interface it created along with the follow-up
commands. `Ctrl-C` shuts down gracefully (the device is taken out of RNDIS first, then the
interface is destroyed).

Common options (see `--help` for the full list):

| Option | Description |
|---|---|
| `--list` | List detected RNDIS devices and exit; no root required |
| `--vid` / `--pid` | Select a device (hex), for multi-device setups |
| `--stats 1000` | Print a throughput/drop statistics line every second |
| `--log debug` | Enable detailed protocol interaction logging |
| `--max-transfer-kb` | The main throughput tuning knob — see [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |
| `--lang zh\|en\|auto` | Interface language, default `auto` (see below) |

**Language**: by default the tool checks `TETHERKIT_LANG`, `LC_ALL`,
`LC_MESSAGES` and `LANG` in that order and takes the first non-empty value.
Anything starting with `zh` means Chinese; everything else means English.

```bash
tetherkit-cli --lang zh --help     # pick explicitly
TETHERKIT_LANG=zh tetherkit-cli --list
```

> ⚠️ Whether `sudo` passes `LANG` through depends on your sudoers `env_keep`, so
> `sudo tetherkit-cli` does not necessarily follow your terminal's language —
> pass `--lang` explicitly in that case.

### Why root is needed

| Operation | Root? | Reason |
|---|---|---|
| Create / destroy `feth` | ✔ | The kernel enforces `proc_suser` on `SIOCIFCREATE2` / `SIOCSDRVSPEC` |
| Open `/dev/bpf*` | ✔ | The nodes are `0600 root:wheel`, and macOS has **no** equivalent of FreeBSD's `access_bpf` group |
| libusb claiming the RNDIS interface | ✘ | The macOS kernel has **no** RNDIS driver, so nothing else holds the interface. A non-sandboxed command line program needs neither root nor an entitlement |

In other words, root is a requirement of the interface side, not the USB side — which is why
`--list` works without it.

---

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `--list` finds no device | ① Try a different **data** cable (many are power-only); ② enable "USB tethering" on the device; ③ unlock the phone and trust this computer. Use `system_profiler SPUSBDataType` to check whether the system sees the device at all |
| `claiming the RNDIS data interface failed [libusb: LIBUSB_ERROR_ACCESS]` | Something else owns the interface. Check for a third-party kext such as HoRNDIS, or another user-space program using the device |
| `creating the feth virtual interface requires root` | Run it with `sudo` |
| `sysctl net.link.fake.hwcsum is 1, expected 0` | These switches are **snapshotted when the feth is created**; changing them afterwards has no effect. Do `sudo sysctl -w net.link.fake.hwcsum=0` first, then start |
| `ipconfig set feth0 DHCP` gets no address | Make sure tethering is actually on at the device side; use `--stats 1000` to see whether TX frames go out and RX frames come back |
| Interface is configured but there is no connectivity | The default route still points at the old interface. `sudo route -n change default $(ipconfig getoption feth0 router)` — note this displaces the existing default route |
| Throughput far below expectations | Check the "device aggregation limit N packets" and "link batch write" lines in the startup log, then work through the checklist in [docs/PERFORMANCE.md](docs/PERFORMANCE.md) |
| The interface is gone after a reboot | `ipconfig set` creates a **temporary** service that only lives until the next network configuration change, and never appears in System Settings. That is a macOS limitation, not a bug |

### Questions people usually arrive with

**Does Android USB tethering work on macOS at all?**
Not out of the box — macOS ships no RNDIS driver, so an Android phone in USB tethering mode
simply produces no network interface. That is what TetherKit adds.

**Do I have to disable SIP, or lower the security policy on Apple Silicon?**
No. Those are requirements of *kernel extensions*. TetherKit is an ordinary program; the
kernel never loads any of its code. The privileged part is a small background component that
needs an admin password once, at install time.

**HoRNDIS shows as "Disabled Software" / has no *Allow* button. Can I fix it?**
That is macOS refusing to load a third-party kext, not something the kext can fix from its
side. On Apple Silicon, loading one at all requires booting into Recovery and lowering the
security policy. TetherKit avoids the whole category of problem.

**Does it work on M1 / M2 / M3 / M4?**
Yes — Apple Silicon and Intel take the same code path. There is nothing architecture-specific
about it beyond ordinary compilation.

**Is my device supported?**
Anything that presents an RNDIS interface: most Android phones with USB tethering enabled,
Windows Phone, and Linux `g_ether`/`u_ether` USB gadgets (Raspberry Pi Zero, BeagleBone …).
Run `tetherkit-cli --list` to check — it needs no root.

**Does iPhone tethering need this?**
No. macOS supports iPhone USB tethering natively; TetherKit is for the devices it does not
cover.

---

## Architecture

```
        ┌──────────────────────────────── macOS kernel ────────────────────────────────┐
        │                                                                              │
        │   IP stack / routing / DHCP client                                           │
        │        │                                                                     │
        │        ▼                                                                     │
        │   ┌─────────┐    if_fake peer pair    ┌─────────┐                            │
        │   │  feth0  │ ◄─────────────────────► │  feth1  │                            │
        │   │(system) │                         │(driver) │                            │
        │   └─────────┘                         └────┬────┘                            │
        │    IP + routes                             │ BPF                             │
        └────────────────────────────────────────────┼─────────────────────────────────┘
                                                     │ read() / write() raw Ethernet frames
        ┌────────────────────────────────────────────┼─────────────────────────────────┐
        │   TetherKit (user space)                   │                                 │
        │                                            ▼                                 │
        │   ┌───────────────────────── data path bridge ─────────────────────────┐     │
        │   │ TX: BPF batch read → coalesce frames → RNDIS_PACKET_MSG → bulk OUT │     │
        │   │ RX: bulk IN → split RNDIS_PACKET_MSG → SPSC queue → BPF write      │     │
        │   └──────────────────────────────────┬─────────────────────────────────┘     │
        │                                      │                                       │
        │   ┌───────── RNDIS state machine ──────────┐                                 │
        │   │ INITIALIZE / QUERY / SET / KEEPALIVE / │                                 │
        │   │ RESET / INDICATE_STATUS / HALT         │                                 │
        │   └────────────────────┬───────────────────┘                                 │
        │                        │                                                     │
        │   ┌───────────────────── libusb ─────────────────────┐                       │
        │   │ control:      SEND_ENCAPSULATED_COMMAND /        │                       │
        │   │               GET_ENCAPSULATED_RESPONSE          │                       │
        │   │ notification: interrupt IN (RESPONSE_AVAILABLE)  │                       │
        │   │ data:         bulk IN / bulk OUT (async, pooled) │                       │
        │   └─────────────────────────┬────────────────────────┘                       │
        └─────────────────────────────┼────────────────────────────────────────────────┘
                                      │ USB
                                ┌─────┴──────┐
                                │RNDIS device│
                                └────────────┘
```

---

## Building from source

Requirements: macOS 13.3+, Xcode command line tools (Apple clang with C++23 support),
CMake ≥ 3.24, libusb 1.0.

```bash
brew install libusb cmake
```

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build -j
```

Output: `build/bin/tetherkit-cli`.

### Building the GUI

Requires the full Xcode toolchain. On top of the build directory above:

```bash
cmake --build build --target gui        # same as ./gui/Scripts/build-gui.sh
open dist/TetherKit.app
```

### Build options

| Option | Default | Description |
|---|---|---|
| `TETHERKIT_BUILD_TESTS` | `ON` | Build unit tests |
| `TETHERKIT_BUILD_BENCHMARKS` | `ON` | Build benchmarks |
| `TETHERKIT_WARNINGS_AS_ERRORS` | `OFF` | Treat warnings as errors |
| `TETHERKIT_NATIVE_ARCH` | `OFF` | `-mcpu=native`; the binary is no longer portable |
| `TETHERKIT_ENABLE_LTO` | `OFF` | Link-time optimization |
| `TETHERKIT_ENABLE_ASAN` | `OFF` | AddressSanitizer |
| `TETHERKIT_ENABLE_UBSAN` | `OFF` | UndefinedBehaviorSanitizer |
| `TETHERKIT_ENABLE_TSAN` | `OFF` | ThreadSanitizer (**required to validate the lock-free structures**) |

### Tests

```bash
ctest --test-dir build --output-on-failure
```

The lock-free queue and the multi-threaded data path are validated separately under
ThreadSanitizer:

```bash
cmake -S . -B build-tsan -DTETHERKIT_ENABLE_TSAN=ON
cmake --build build-tsan -j
ctest --test-dir build-tsan --output-on-failure
```

### Benchmarks

```bash
cmake -S . -B build-rel -DCMAKE_BUILD_TYPE=Release
cmake --build build-rel -j
./build-rel/bin/tetherkit_bench
```

Aggregated results: [docs/BENCHMARKS.md](docs/BENCHMARKS.md).

---

## Documentation

The documents below are written in Chinese.

| Document | Contents |
|---|---|
| [docs/DESIGN.md](docs/DESIGN.md) | **Overall design**: why feth+BPF, module breakdown, concurrency model, teardown ordering, risk assessment of the private ABI |
| [docs/RNDIS-PROTOCOL.md](docs/RNDIS-PROTOCOL.md) | **Protocol reference**: field offsets, status codes, OIDs, state machine, device quirks. Includes the three rules that are easiest to get wrong |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | **Tuning guide**: the knobs, how to identify the bottleneck, known limits |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | **Benchmark results** (auto-generated) + methodology and known limitations |
| [docs/GUI-ARCHITECTURE.md](docs/GUI-ARCHITECTURE.md) | **Graphical interface**: process and trust model, data flow, implementation constraints, what is and is not implemented |
| [docs/GUI-SPIKE.md](docs/GUI-SPIKE.md) | **Feasibility spike**: why privilege escalation is done this way, and the three routes that were ruled out |
| [AGENTS.md](AGENTS.md) | Implementation notes: verified facts about the environment, progress, **pitfalls hit along the way**, and the to-be-verified checklist |

---

## License

See [LICENSE](LICENSE).

### Daily usage per phone

The device row shows today’s total; click it for daily download, upload, and combined usage. Phones are identified by USB serial number, so totals survive reconnections; devices without a serial number cannot be reliably tracked. Counts cover traffic through TetherKit on this Mac, including local traffic, and may differ from carrier billing. MTU and MAC options are under Advanced device settings. Tracking reuses existing counters and checks, with no idle worker; an abrupt power loss may lose about one minute of unsaved usage.
