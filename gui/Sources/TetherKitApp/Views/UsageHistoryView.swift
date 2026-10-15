import SwiftUI
import TetherKitIPC

struct UsageHistoryView: View {
    let device: DeviceDescriptor
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var records: [DailyUsage] {
        guard let key = TrafficUsage.key(for: device) else { return [] }
        let history = model.usageRecords.filter { $0.deviceKey == key }
            .sorted { $0.day > $1.day }
        return history.isEmpty ? [DailyUsage(deviceKey: key, day: TrafficUsage.day())] : history
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(device.displayName).font(.headline)
            Text(L(.usageHistory)).font(.subheadline)
            if TrafficUsage.key(for: device) == nil {
                Text(L(.usageUnavailable)).foregroundStyle(.secondary)
            } else {
                Table(records) {
                    TableColumn(L(.usageHistory), value: \.day)
                    TableColumn(L(.usageDownload)) { Text(TrafficUsage.formatted($0.downloaded)) }
                    TableColumn(L(.usageUpload)) { Text(TrafficUsage.formatted($0.uploaded)) }
                    TableColumn(L(.usageTotal)) { Text(TrafficUsage.formatted($0.total)) }
                }
                .frame(minHeight: 200)
            }
            Text(L(.usageScope)).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L(.ok)) { dismiss() } }
        }
        .padding(24)
        .frame(width: 620, height: 360)
    }
}
