import CryptoKit
import Foundation

public struct DailyUsage: Codable, Identifiable, Hashable, Sendable {
    public var deviceKey: String
    public var day: String
    public var downloaded: UInt64 = 0
    public var uploaded: UInt64 = 0
    public var id: String { deviceKey + ":" + day }
    public var total: UInt64 { downloaded + uploaded }

    public init(deviceKey: String, day: String) {
        self.deviceKey = deviceKey
        self.day = day
    }
}

public enum TrafficUsage {
    public static let path = "/Library/PrivilegedHelperTools/com.tetherkit.usage.json"

    /// 不把序列号写入用量文件；无序列号时不猜测设备身份。
    public static func key(for device: DeviceDescriptor) -> String? {
        guard !device.serial.isEmpty else { return nil }
        let identity = "\(device.vendorID):\(device.productID):\(device.serial)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func day(at date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04ld-%02ld-%02ld", parts.year!, parts.month!, parts.day!)
    }

    public static func read() -> [DailyUsage] {
        HelperRecords.read([DailyUsage].self, path: path) ?? []
    }

    public static func formatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .decimal)
    }
}

/// 仅由 helper 生命周期队列调用。每秒复用已有计数快照，变更后最多每分钟落盘。
public final class UsageLedger {
    public private(set) var records: [DailyUsage]
    private var deviceKey: String?
    private var lastRX: UInt64 = 0
    private var lastTX: UInt64 = 0
    private var dirty = false
    private var lastSave: TimeInterval?
    private var lastDay: String?

    public init(records: [DailyUsage] = TrafficUsage.read()) { self.records = records }

    public func begin(deviceKey: String?) {
        self.deviceKey = deviceKey
        lastRX = 0
        lastTX = 0
    }

    @discardableResult
    public func sample(rx: UInt64, tx: UInt64, day: String) -> DailyUsage? {
        guard let deviceKey else { return nil }
        let down = rx >= lastRX ? rx - lastRX : rx
        let up = tx >= lastTX ? tx - lastTX : tx
        lastRX = rx
        lastTX = tx
        lastDay = day
        let index: Int
        if let found = records.firstIndex(where: { $0.deviceKey == deviceKey && $0.day == day }) {
            index = found
        } else {
            records.append(DailyUsage(deviceKey: deviceKey, day: day))
            index = records.count - 1
        }
        records[index].downloaded += down
        records[index].uploaded += up
        dirty = dirty || down != 0 || up != 0
        return records[index]
    }

    public func needsDayFlush(_ day: String) -> Bool { lastDay != nil && lastDay != day }

    public func saveIfNeeded(now: TimeInterval, force: Bool = false,
                             write: ([DailyUsage]) throws -> Void) throws {
        guard dirty else { return }
        if !force, let lastSave, now - lastSave < 60 { return }
        lastSave = now
        try write(records)
        dirty = false
    }
}
