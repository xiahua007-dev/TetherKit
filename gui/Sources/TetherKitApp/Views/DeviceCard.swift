import SwiftUI
import TetherKitIPC

/// 设备选择与会话参数。
///
/// 运行中允许刷新和选择其他设备；只有明确点击切换才会中断当前连接。
/// MTU 与 MAC 策略仍在运行中保持只读。
struct DeviceCard: View {
    @Bindable var model: AppModel
    @State private var showingSettings = false
    @State private var usageDevice: DeviceDescriptor?

    private var isLocked: Bool {
        model.status.runState == .running || model.status.runState.isTransitional
    }

    var body: some View {
        Card(title: L(.usbDeviceSectionTitle),
             systemImage: "cable.connector",
             accessory: AnyView(refreshButton)) {
            if model.devices.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                    devicePicker
                    if model.canSwitchDevice {
                        Button(L(.switchToSelectedDevice)) {
                            Task { await model.switchDevice() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.isRefreshingDevices)
                        .help(L(.switchDeviceHelp))
                    }
                    Button(L(.deviceSettings), systemImage: "slider.horizontal.3") {
                        showingSettings = true
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            VStack(alignment: .leading, spacing: 20) {
                Text(L(.deviceSettings)).font(.headline)
                Text(L(.deviceSettingsScope)).font(.caption).foregroundStyle(.secondary)
                tuningControls
                HStack { Spacer(); Button(L(.ok)) { showingSettings = false } }
            }.padding(24).frame(width: 480)
        }
        .sheet(item: $usageDevice) { device in
            UsageHistoryView(device: device, model: model)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await model.refreshDevices() }
        } label: {
            if model.isRefreshingDevices {
                HStack(spacing: Design.Spacing.tight) {
                    ProgressView().progressViewStyle(.circular).controlSize(.small)
                    Text(L(.refreshingUSBDevices)).font(.caption)
                }
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(model.isRefreshingDevices || model.isBusy || model.status.runState.isTransitional)
        .help(L(.rescanUSBDevices))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L(.noDeviceDetected), systemImage: "cable.connector.slash")
        } description: {
            // 这三条正是 macOS 上 RNDIS 连不上的全部常见原因，按命中率排序。
            VStack(alignment: .leading, spacing: 4) {
                Text(L(.deviceChecklistCable))
                Text(L(.deviceChecklistTethering))
                Text(L(.deviceChecklistUnlocked))
            }
            .font(.callout)
        }
        .frame(maxWidth: .infinity)
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            ForEach(model.devices) { device in
                DeviceRow(device: device,
                          usage: model.usageRecords.first { $0.deviceKey == TrafficUsage.key(for: device)
                              && $0.day == TrafficUsage.day() },
                          onUsage: { model.reloadUsage(); usageDevice = device },
                          isSelected: (model.selectedDevice?.id == device.id),
                          isLocked: model.isBusy || model.status.runState.isTransitional,
                          isConnected: model.status.runState == .running
                              && device.summary == model.status.deviceDescription) {
                    model.selectedDeviceID = device.id
                }
            }
        }
    }

    // 长解释一律放进悬停提示：这两个参数一年也调不了一次，说明文字却天天占着
    // 屏幕 —— 界面上只留「什么时候需要动它」这一句。
    private var tuningControls: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.small) {
            HStack {
                Text("MTU")
                    .font(.callout)
                    .frame(width: 92, alignment: .leading)
                // 步进 100 而不是 1：MTU 是要和对端协商的，逐字节微调没有意义，
                // 而 1500 / 1400 / 2000 这样的整数才是用户真正会试的值。
                Stepper(value: $model.requestedMTU, in: 576...2048, step: 100) {
                    Text(L(.mtuBytes, String(model.requestedMTU)))
                        .font(.system(.callout, design: .monospaced))
                }
                .disabled(isLocked)
                Spacer()
            }
            // 上限只有在环境预检拿到之后才知道，所以是两条独立文案而不是拼接 ——
            // 「（本机上限 N）」这半句在英文里落到句子的另一个位置，拼不出来。
            Text(model.environment.map { L(.mtuHelpWithLimit, Int($0.fethMaxMTU)) }
                 ?? L(.mtuHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(L(.mtuTooltip))

            Toggle(isOn: $model.adoptDeviceMAC) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L(.adoptDeviceMAC))
                    Text(L(.adoptDeviceMACHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(isLocked)
            .help(L(.adoptDeviceMACTooltip))
            .padding(.top, 2)
        }
    }
}

/// 设备列表里的一行。
private struct DeviceRow: View {
    let device: DeviceDescriptor
    let usage: DailyUsage?
    let onUsage: () -> Void
    let isSelected: Bool
    let isLocked: Bool
    let isConnected: Bool
    let onSelect: () -> Void
    @State private var isSerialVisible = false

    var body: some View {
        HStack(spacing: Design.Spacing.small) {
            Button(action: onSelect) {
                HStack(spacing: Design.Spacing.small) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.displayName)
                            .font(.callout)
                            .foregroundStyle(.primary)
                        HStack(spacing: Design.Spacing.tight) {
                            Text(device.summary)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLocked)

            if !device.serial.isEmpty {
                HStack(spacing: Design.Spacing.tight) {
                    Text(isSerialVisible ? L(.deviceSerialValue, device.serial) : L(.deviceSerialHidden))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        isSerialVisible.toggle()
                    } label: {
                        Image(systemName: isSerialVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L(isSerialVisible ? .hideDeviceSerial : .showDeviceSerial))
                    .help(L(isSerialVisible ? .hideDeviceSerial : .showDeviceSerial))
                }
            }

            Button(action: onUsage) {
                Text(TrafficUsage.key(for: device) == nil ? L(.usageUntracked)
                     : L(.todayUsage, TrafficUsage.formatted(usage?.total ?? 0)))
                    .font(.callout.monospacedDigit())
            }
            .buttonStyle(.borderless)
            .help(L(.usageScope))
            .frame(maxWidth: .infinity)

            if isConnected {
                StatusBadge(text: L(.currentUSBDevice), color: .green)
            }
            if device.usedAndroidQuirk {
                // 这条信息对排障很有用：走了兜底路径说明设备的 CDC 描述符不
                // 规范，日后若出问题这是第一个该看的线索。
                StatusBadge(text: L(.compatibilityMode), color: .orange)
                    .help(L(.compatibilityModeTooltip))
            }
        }
            .padding(Design.Spacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Design.Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Design.Radius.control)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : .clear,
                                  lineWidth: 1))
            .contentShape(Rectangle())
            .onDisappear { isSerialVisible = false }
            .onChange(of: device.serial) { isSerialVisible = false }
    }
}
