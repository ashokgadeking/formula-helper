import Foundation

struct PairedScale: Codable, Identifiable, Equatable {
    let id: UUID                  // CBPeripheral.identifier
    var name: String
    var pairedAt: Date
    var lastSeenAt: Date?
    var lastBatteryPct: Int?
}

/// Persists paired scale metadata to the shared App Group UserDefaults so the
/// data is visible to the main app, widgets, and (future) Siri intents from
/// one source of truth.
enum BookooPairingStore {
    private static let groupID = "group.com.ashokteja.formulahelper"
    private static let key = "bookoo.paired_scales"
    private static let pendingKey = "bookoo.pending_logs"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: groupID)
    }

    // MARK: - Paired scales

    static func load() -> [PairedScale] {
        guard let data = defaults?.data(forKey: key),
              let scales = try? JSONDecoder().decode([PairedScale].self, from: data)
        else { return [] }
        return scales
    }

    static func save(_ scales: [PairedScale]) {
        guard let data = try? JSONEncoder().encode(scales) else { return }
        defaults?.set(data, forKey: key)
    }

    @discardableResult
    static func upsert(_ scale: PairedScale) -> [PairedScale] {
        var scales = load()
        if let i = scales.firstIndex(where: { $0.id == scale.id }) {
            scales[i] = scale
        } else {
            scales.append(scale)
        }
        save(scales)
        return scales
    }

    @discardableResult
    static func remove(id: UUID) -> [PairedScale] {
        var scales = load()
        scales.removeAll { $0.id == id }
        save(scales)
        return scales
    }

    static func updateLastSeen(id: UUID, batteryPct: Int) {
        var scales = load()
        guard let i = scales.firstIndex(where: { $0.id == id }) else { return }
        scales[i].lastSeenAt = Date()
        scales[i].lastBatteryPct = batteryPct
        save(scales)
    }

    // MARK: - Pending log retry queue

    struct PendingLog: Codable {
        let ml: Int
        let scaleID: UUID
        let ts: Date
    }

    static func loadPending() -> [PendingLog] {
        guard let data = defaults?.data(forKey: pendingKey),
              let arr = try? JSONDecoder().decode([PendingLog].self, from: data)
        else { return [] }
        return arr
    }

    static func savePending(_ arr: [PendingLog]) {
        // Cap at 10, drop oldest. Pending is a best-effort retry queue, not an
        // authoritative log — bounding it keeps it from ballooning under sustained
        // outage.
        let trimmed = Array(arr.suffix(10))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults?.set(data, forKey: pendingKey)
    }

    static func enqueuePending(_ p: PendingLog) {
        var arr = loadPending()
        arr.append(p)
        savePending(arr)
    }

    static func clearPending() {
        defaults?.removeObject(forKey: pendingKey)
    }
}
