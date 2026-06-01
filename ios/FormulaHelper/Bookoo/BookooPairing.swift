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
    private static let dryBottleKey = "bookoo.dry_bottle_weight"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: groupID)
    }

    // MARK: - Dry bottle calibration (global, shared across all scales)

    /// Grams reading of the empty, dry bottle the user mixes in. Common to all
    /// paired scales — the user uses the same bottles regardless of which scale
    /// they're standing at. When set, BookooSession derives water_ml directly
    /// from the lift magnitude instead of guessing from the formula ratio.
    static func loadDryBottleWeight() -> Double? {
        guard let d = defaults, d.object(forKey: dryBottleKey) != nil else { return nil }
        return d.double(forKey: dryBottleKey)
    }

    static func saveDryBottleWeight(_ grams: Double?) {
        if let grams {
            defaults?.set(grams, forKey: dryBottleKey)
        } else {
            defaults?.removeObject(forKey: dryBottleKey)
        }
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

    // MARK: - Measured grams per sk

    /// When a Bookoo log fires, we know the exact peak grams the scale read,
    /// even though the server only stores the rounded ml. Save the measured
    /// value here keyed by the returned log sk so the edit panel can surface
    /// it instead of recomputing from the formula ratio.
    private static let measuredKey = "bookoo.measured_grams_by_sk"

    static func loadMeasuredGrams() -> [String: Double] {
        guard let data = defaults?.data(forKey: measuredKey),
              let map = try? JSONDecoder().decode([String: Double].self, from: data)
        else { return [:] }
        return map
    }

    static func recordMeasuredGrams(sk: String, grams: Double) {
        var map = loadMeasuredGrams()
        map[sk] = grams
        // Cap at 500 entries to keep the dict bounded. Oldest by iteration order
        // when over cap — good enough since this is a UX hint, not a system of
        // record.
        if map.count > 500 {
            map = Dictionary(uniqueKeysWithValues: map.suffix(500).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(map) {
            defaults?.set(data, forKey: measuredKey)
        }
    }
}
