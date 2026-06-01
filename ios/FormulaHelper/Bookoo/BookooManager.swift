import Foundation
@preconcurrency import CoreBluetooth
import UserNotifications

private struct UnsafePeripheralBox: @unchecked Sendable {
    let values: [CBPeripheral]
    init(_ v: [CBPeripheral]) { self.values = v }
}

/// Coordinates BLE for all paired Bookoo scales. Survives app termination via
/// CBCentralManager state restoration so the overnight auto-log workflow
/// triggers without any phone interaction.
@MainActor
final class BookooManager: NSObject, ObservableObject {
    static let shared = BookooManager()

    // CBUUID is not Sendable, so we can't expose stored instance properties to
    // nonisolated CB delegate callbacks. Wrap them as nonisolated computed
    // properties that build the CBUUID on demand — the underlying CBUUID(string:)
    // call is cheap.
    nonisolated private var serviceUUID: CBUUID { CBUUID(string: "0FFE") }
    nonisolated private var weightCharUUID: CBUUID { CBUUID(string: "FF11") }
    nonisolated private var commandCharUUID: CBUUID { CBUUID(string: "FF12") }
    nonisolated private let restoreID = "com.ashokteja.formulahelper.bookoo"

    private var central: CBCentralManager!
    private let bleQueue = DispatchQueue(label: "bookoo.ble")

    /// All peripherals iOS has handed us — either freshly discovered, restored,
    /// or currently connected.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var commandChars: [UUID: CBCharacteristic] = [:]
    private var sessions: [UUID: BookooSession] = [:]

    @Published private(set) var pairedScales: [PairedScale] = []
    @Published private(set) var discovered: [DiscoveredScale] = []
    @Published private(set) var isScanning = false
    @Published private(set) var bleAuthorized = true
    /// Global dry-bottle calibration, shared across all scales.
    @Published private(set) var dryBottleWeight: Double?
    /// Peripherals currently connected (BLE link up).
    @Published private(set) var connectedIDs: Set<UUID> = []
    /// Live debug per peripheral — last raw reading + session phase. Used by the
    /// pairing UI to confirm packets are arriving and the state machine is
    /// progressing as expected.
    @Published private(set) var debugInfo: [UUID: DebugRow] = [:]

    struct DebugRow: Equatable {
        var weightG: Double
        var phase: String
        var updatedAt: Date
        var packetCount: Int
        var maxWeightEver: Double
        var maxMagnitudeEver: Double
        var lastSignByte: UInt8
        var lastRawHex: String
    }

    struct DiscoveredScale: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    override init() {
        super.init()
        pairedScales = BookooPairingStore.load()
        dryBottleWeight = BookooPairingStore.loadDryBottleWeight()
        // Must construct CBCentralManager early so iOS restores any in-flight
        // peripherals before the launch sequence completes — that's what makes
        // background auto-reconnect work.
        central = CBCentralManager(
            delegate: self,
            queue: bleQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: restoreID]
        )
    }

    // MARK: - Public API

    func startDiscoveryScan() {
        Task { @MainActor in
            discovered = []
            if central.state == .poweredOn {
                central.scanForPeripherals(
                    withServices: [serviceUUID],
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
                isScanning = true
                // Auto-stop after 30s so we don't drain battery if the user
                // backgrounds the pairing sheet.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(30))
                    stopDiscoveryScan()
                }
            }
        }
    }

    func stopDiscoveryScan() {
        central.stopScan()
        isScanning = false
        // Resume the passive paired-scale rescan so connections still establish.
        startPairedRescanIfNeeded()
    }

    func pair(_ d: DiscoveredScale, named name: String) {
        let scale = PairedScale(
            id: d.id,
            name: name,
            pairedAt: Date(),
            lastSeenAt: nil,
            lastBatteryPct: nil
        )
        pairedScales = BookooPairingStore.upsert(scale)
        // Kick connection so the user sees status update immediately.
        if let p = peripherals[d.id] {
            central.connect(p, options: nil)
        } else {
            startPairedRescanIfNeeded()
        }
    }

    func rename(id: UUID, to name: String) {
        guard let i = pairedScales.firstIndex(where: { $0.id == id }) else { return }
        pairedScales[i].name = name
        BookooPairingStore.save(pairedScales)
    }

    /// Set (or clear) the global dry-bottle calibration shared by all scales.
    func setDryBottleWeight(_ grams: Double?) {
        dryBottleWeight = grams
        BookooPairingStore.saveDryBottleWeight(grams)
    }

    /// Live weight from whichever scale most recently streamed a packet. Used
    /// by the calibration sheet — the user places the empty bottle on whatever
    /// scale is on, and we read it regardless of which one it is.
    var liveWeightAnyScale: Double? {
        debugInfo.values.max(by: { $0.updatedAt < $1.updatedAt })?.weightG
    }

    func unpair(id: UUID) {
        if let p = peripherals[id] { central.cancelPeripheralConnection(p) }
        peripherals.removeValue(forKey: id)
        commandChars.removeValue(forKey: id)
        sessions.removeValue(forKey: id)
        pairedScales = BookooPairingStore.remove(id: id)
    }

    /// Flush any pending logs accumulated while offline / unauthenticated.
    /// Called from the app on foreground and after every successful BLE log.
    func flushPendingLogs() async {
        let pending = BookooPairingStore.loadPending()
        guard !pending.isEmpty else { return }
        var remaining: [BookooPairingStore.PendingLog] = []
        for p in pending {
            do {
                _ = try await APIClient.shared.startFeeding(ml: p.ml)
            } catch {
                remaining.append(p)
            }
        }
        BookooPairingStore.savePending(remaining)
    }

    // MARK: - Internals

    private func startPairedRescanIfNeeded() {
        guard central.state == .poweredOn else { return }
        guard !pairedScales.isEmpty else { return }
        // Passive scan filtered by service UUID — cheap. iOS coalesces it with
        // any other CB scan running. AllowDuplicates=false because we only need
        // the first sighting to trigger a connect.
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func handleReading(_ r: BookooReading, from id: UUID, magnitude: Double = 0, signByte: UInt8 = 0, hex: String = "") {
        BookooPairingStore.updateLastSeen(id: id, batteryPct: r.batteryPct)
        if let idx = pairedScales.firstIndex(where: { $0.id == id }) {
            pairedScales[idx].lastSeenAt = Date()
            pairedScales[idx].lastBatteryPct = r.batteryPct
        }

        let session = sessions[id] ?? {
            let s = BookooSession(peripheralID: id)
            s.onLog = { [weak self] ml, measuredGrams, unroundedMl, peripheralID in
                self?.performLog(ml: ml, measuredGrams: measuredGrams, unroundedMl: unroundedMl, peripheralID: peripheralID)
            }
            sessions[id] = s
            return s
        }()
        session.ingest(r)

        let prev = debugInfo[id]
        debugInfo[id] = DebugRow(
            weightG: r.weightG,
            phase: phaseDescription(session.phase),
            updatedAt: Date(),
            packetCount: (prev?.packetCount ?? 0) + 1,
            maxWeightEver: max(prev?.maxWeightEver ?? -Double.infinity, r.weightG),
            maxMagnitudeEver: max(prev?.maxMagnitudeEver ?? 0, magnitude),
            lastSignByte: signByte,
            lastRawHex: hex
        )
    }

    private func phaseDescription(_ p: BookooSession.Phase) -> String {
        switch p {
        case .ready: return "ready"
        case .tracking(let peak): return "tracking (peak \(String(format: "%.1f", peak))g)"
        case .lifting(let trough, _): return "lifting (trough \(String(format: "%.1f", trough))g)"
        case .logged: return "logged · cooldown"
        }
    }

    private func performLog(ml: Int, measuredGrams: Double, unroundedMl: Double, peripheralID: UUID) {
        let scaleName = pairedScales.first { $0.id == peripheralID }?.name ?? "Bookoo"
        Task { @MainActor in
            do {
                // /api/start anchors the expiry timer AND creates the mix_log
                // entry server-side. Calling /api/log here too would double-log.
                let resp = try await APIClient.shared.startFeeding(ml: ml)
                if let sk = resp.sk {
                    BookooPairingStore.recordMeasured(sk: sk, grams: measuredGrams, ml: unroundedMl)
                }
                sendBeep(peripheralID: peripheralID)
                postLogNotification(ml: ml, scaleName: scaleName)
                await flushPendingLogs()
            } catch APIError.badStatus(401, _) {
                postAuthRequiredNotification()
            } catch {
                BookooPairingStore.enqueuePending(
                    .init(ml: ml, scaleID: peripheralID, ts: Date())
                )
                postRetryQueuedNotification(ml: ml)
            }
        }
    }

    private func sendBeep(peripheralID: UUID) {
        guard let p = peripherals[peripheralID],
              let c = commandChars[peripheralID]
        else { return }
        // CMD_TARE_AND_START is effective in every mode (start_timer alone only
        // fires in timing/ratio mode) so it's the most reliable trigger for the
        // scale's own audible tare cue. The bottle is already off the scale by
        // the time this fires, so re-taring the empty pan is harmless.
        p.writeValue(BookooCommand.tareAndStart, for: c, type: .withResponse)
    }

    private func postLogNotification(ml: Int, scaleName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Logged \(ml) ml bottle"
        content.body = "Bookoo · \(scaleName)"
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "bookoo-log-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    private func postAuthRequiredNotification() {
        let content = UNMutableNotificationContent()
        content.title = "AvantiLog needs you to sign in"
        content.body = "Open the app and sign in so I can log future bottles."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "bookoo-auth-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    private func postRetryQueuedNotification(ml: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Couldn't reach the server"
        content.body = "Will retry the \(ml) ml log when AvantiLog is online."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "bookoo-retry-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - CBCentralManagerDelegate

extension BookooManager: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else { return }
        // Wrap in a Sendable box so Swift 6 strict concurrency lets us send
        // the legacy CoreBluetooth array across the actor hop. We're the only
        // owner — no races.
        let box = UnsafePeripheralBox(restored)
        Task { @MainActor in
            for p in box.values {
                p.delegate = self
                peripherals[p.identifier] = p
                if p.state == .connected {
                    connectedIDs.insert(p.identifier)
                    p.discoverServices([serviceUUID])
                }
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bleAuthorized = central.state != .unauthorized
            if central.state == .poweredOn {
                startPairedRescanIfNeeded()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Bookoo"
        let pid = peripheral.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in
            peripherals[pid] = peripheral
            peripheral.delegate = self

            // If this is a paired scale, connect immediately.
            if pairedScales.contains(where: { $0.id == pid }) {
                central.connect(peripheral, options: nil)
                return
            }

            // Otherwise it's a discovery scan result — surface to the UI.
            if isScanning,
               !discovered.contains(where: { $0.id == pid })
            {
                discovered.append(DiscoveredScale(id: pid, name: name, rssi: rssi))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let pid = peripheral.identifier
        Task { @MainActor in
            connectedIDs.insert(pid)
            peripheral.delegate = self
            peripheral.discoverServices([serviceUUID])
            // Restart paired rescan so other paired scales also auto-connect
            // when they come online. Calling discover scan twice is safe; iOS
            // coalesces.
            _ = pid
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let pid = peripheral.identifier
        Task { @MainActor in
            connectedIDs.remove(pid)
            commandChars.removeValue(forKey: pid)
            sessions[pid] = nil
            // 2s backoff before resuming the rescan to avoid hot-spinning when
            // the scale auto-shuts off.
            try? await Task.sleep(for: .seconds(2))
            startPairedRescanIfNeeded()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BookooManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            for svc in peripheral.services ?? [] where svc.uuid == serviceUUID {
                peripheral.discoverCharacteristics([weightCharUUID, commandCharUUID], for: svc)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let pid = peripheral.identifier
        Task { @MainActor in
            for c in service.characteristics ?? [] {
                if c.uuid == weightCharUUID {
                    peripheral.setNotifyValue(true, for: c)
                } else if c.uuid == commandCharUUID {
                    commandChars[pid] = c
                }
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == weightCharUUID,
              let data = characteristic.value,
              let reading = BookooPacket.parse(data)
        else { return }
        let pid = peripheral.identifier
        let signByte = data.count > 6 ? data[6] : 0
        // Raw magnitude — sign-agnostic. Lets us tell whether the scale is
        // actually emitting a non-zero weight when the parsed (signed) value
        // looks pinned to 0.
        let magnitude: Double = {
            guard data.count >= 10 else { return 0 }
            let raw = (Int(data[7]) << 16) | (Int(data[8]) << 8) | Int(data[9])
            return Double(raw) / 100.0
        }()
        // Header bytes hex — first 10 bytes is enough to capture the sign +
        // weight field.
        let hex = data.prefix(10).map { String(format: "%02X", $0) }.joined(separator: " ")
        Task { @MainActor in
            handleReading(reading, from: pid, magnitude: magnitude, signByte: signByte, hex: hex)
        }
    }
}
