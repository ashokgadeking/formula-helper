# Story 4.1: Bookoo auto-log foundation

Status: ready-for-dev

**Epic:** 4 — Bookoo scale auto-log
**Story ID:** 4.1
**Story Key:** 4-1-bookoo-autolog

## Story

As a **parent mixing a bottle one-handed at 3am with the phone in another room**,
I want **the iOS app to auto-detect when I finish a Bookoo prep and log the bottle for me**,
so that **I don't have to put the baby down or interact with anything other than the scale**.

## Acceptance Criteria

1. **CoreBluetooth manager.** A new `BookooManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate` singleton at `ios/FormulaHelper/Bookoo/BookooManager.swift`. Initialised at app launch from `FormulaHelperApp.init()` (not lazy — must claim the BLE state-restoration identifier before iOS asks). Uses queue `DispatchQueue(label: "bookoo.ble")`.

2. **State restoration.** `CBCentralManager` initialised with `[CBCentralManagerOptionRestoreIdentifierKey: "com.ashokteja.formulahelper.bookoo"]`. Implements `centralManager(_:willRestoreState:)`: pulls the restored peripherals from `dict[CBCentralManagerRestoredStatePeripheralsKey]`, re-attaches as delegate, and resumes notify subscription on weight char `FF11`.

3. **Background mode.** `ios/project.yml`'s `FormulaHelper` target adds `UIBackgroundModes: [bluetooth-central]` to Info.plist properties. `NSBluetoothAlwaysUsageDescription` added with copy: "AvantiLog connects to your Bookoo scale to auto-log bottle feedings."

4. **Multi-scale pairing storage.** `BookooPairing.swift` defines `struct PairedScale: Codable { let id: UUID; var name: String; var pairedAt: Date }`. Stored as JSON-encoded `[PairedScale]` in App Group UserDefaults (`group.com.ashokteja.formulahelper`) under key `bookoo.paired_scales`. App Group is used (not local UserDefaults) so widgets/Siri can read pair state if needed in future.

5. **Foreground pairing UI.** New row in `SettingsView` → Account section: "Bookoo Scales". Opens `BookooPairingView`:
   - Lists paired scales with name + battery % (last seen) + remove (trash) button.
   - "Add scale" button starts a scan with service-UUID filter `CBUUID(string: "FFE")`. Lists discovered peripherals by advertised name + RSSI. Tap to connect → on connect, append to paired list with default name "Bookoo (upstairs/downstairs/N)" — user can rename inline.
   - Scan auto-stops after 30s or when user taps a result.

6. **Auto-connect on power-on (background).** Whenever `centralManagerDidUpdateState` reports `.poweredOn`, OR `willRestoreState` fires: start a service-UUID scan with `[CBCentralManagerScanOptionAllowDuplicatesKey: false]`. On `didDiscover peripheral`, if `peripheral.identifier` is in the paired list, stop scan and connect. On `didDisconnect`, restart the scan.

7. **Weight characteristic subscription.** On `didDiscoverServices` for service `FFE` → discover characteristics → for `FF11` (weight) call `setNotifyValue(true, for:)`. For `FF12` (command) save the reference for later writes.

8. **Packet parser.** `BookooPacket.swift` ports `pi/scale.py`'s `parse_weight_packet`. Input: 20-byte `Data` from `FF11` notify. Output: `BookooReading { weightG: Double; flowRate: Double; timerMs: Int; batteryPct: Int }` or nil if packet is malformed. XOR checksum is verified but mismatch logged-and-accepted (per the Python reference comment about firmware variance).

9. **State machine.** `BookooSession.swift` — actor-isolated state machine per active scale:
   - States: `.idle → .tared → .measuring(peak: Double) → .stable(peak: Double, since: Date) → .lifted → .logged`.
   - Transition `.idle → .tared`: weight reading within ±0.5 g of zero seen for ≥0.5 s.
   - Transition `.tared → .measuring(peak)`: weight ≥ 3.0 g. Update `peak` on each subsequent reading where `weight > peak`.
   - Transition `.measuring → .stable`: weight stays within ±0.2 g for ≥ 2.0 s.
   - Transition `.stable → .lifted`: a single reading drops by ≥ 50% of `peak` (or below 1.0 g) — fires the log.
   - Idle timeout: 90 s in any non-`.idle` non-`.logged` state with no qualifying transitions → reset to `.idle`.
   - After `.logged`: cooldown 60 s before any new `.tared` is honored (prevents double-log if user puts the bottle back on briefly).

10. **ml derivation.** On `.lifted` transition, compute `ml = round(peak × 60 / powderPer60 / 10) × 10`. `powderPer60` is read from `CacheManager.shared.restore()?.settings.powder_per_60` (default 8.3 if state cache is empty). Floor at 30, ceiling at 300. If outside this range, log a debug event and reset state — no API call.

11. **Server calls on log.** On valid `.lifted`, sequentially:
    1. `try await APIClient.shared.logEntry(ml: ml, date: nil)` — server stamps with current time.
    2. `try await APIClient.shared.startFeeding(ml: ml)` — anchors the expiry timer the dashboard / widget / Siri all already consume.
    3. Send `CMD_START_TIMER` (0x04) via the FF12 command characteristic — scale plays its own start-timer audio cue (the "beep").
    4. Fire a local user notification via the existing `NotificationManager`: title "Logged \(ml) ml bottle", body "Bookoo · \(scaleName)". Includes the new sk for tap-to-edit (existing pattern).

12. **Failure handling.**
    - APIClient throws `APIError.badStatus(401, _)` → fire local notification "AvantiLog needs you to sign in" (no log retry). State machine resets after cooldown.
    - APIClient any other error → store the (ml, scaleId, timestamp) in a small persisted retry queue in App Group UserDefaults (`bookoo.pending_logs`). Next time the app enters foreground OR the next BLE event fires, flush the queue. Cap at 10 entries; oldest discarded.
    - BLE write of `CMD_START_TIMER` failure → silent (the log already succeeded; the beep is best-effort).

13. **Battery / last-seen.** On every weight packet, persist `batteryPct` and `Date()` per paired peripheral UUID to App Group UserDefaults so the pairing UI shows accurate "Last seen" + "battery 89%".

14. **Manual verification matrix** (on-device, dev TestFlight build):
    - Pair upstairs scale → power off → power on → app auto-reconnects (verify via console log streamed from device).
    - Pair both scales → power on downstairs only → log → power off → power on upstairs → log → both logs land server-side with no manual interaction.
    - Force-quit the app → power on a paired scale → wait for the prep flow → verify the log + notification still fire (state restoration path).
    - Tare-only test: power on the scale with no bottle, leave 90 s, verify state resets without logging.
    - Mid-prep cancel: get to `.measuring` (8 g on the scale), leave 90 s without lifting, verify state resets.
    - Replace-after-lift test: complete a log, put the bottle back on the scale within 60 s — verify NO second log fires (cooldown).
    - Battery and last-seen accuracy: check Settings → Bookoo Scales reflects current values.
    - Out-of-range guard: place a heavy object on the scale (>40 g) and lift — verify no log fires.
    - Sign-out test: sign out, run a prep, verify the 401 fallback notification.

## Tasks / Subtasks

- [ ] **Task 1 — Project plumbing** (AC: 3)
  - [ ] Subtask 1.1: Add `UIBackgroundModes: [bluetooth-central]` to `ios/project.yml` Info.plist properties.
  - [ ] Subtask 1.2: Add `NSBluetoothAlwaysUsageDescription` to Info.plist properties.
  - [ ] Subtask 1.3: Create `ios/FormulaHelper/Bookoo/` directory. (xcodegen's `sources: - path: FormulaHelper` picks it up automatically.)

- [ ] **Task 2 — Packet parser + commands** (AC: 8)
  - [ ] Subtask 2.1: Create `BookooPacket.swift` with `BookooReading` struct + `parse(_ data: Data) -> BookooReading?` static func.
  - [ ] Subtask 2.2: Port the XOR checksum from `ios/BookooReference/scale.py:46-50`.
  - [ ] Subtask 2.3: Create `BookooCommands.swift` with `CMD_START_TIMER` and the other constants from `ios/BookooReference/scale.py:25-30`. Public, marked `static let`.

- [ ] **Task 3 — CBCentralManager + restoration** (AC: 1, 2, 6, 7)
  - [ ] Subtask 3.1: Create `BookooManager.swift` with the singleton + dispatch queue.
  - [ ] Subtask 3.2: Wire `centralManager(_:willRestoreState:)` to rehydrate peripherals + re-establish delegates.
  - [ ] Subtask 3.3: Wire `centralManagerDidUpdateState` → if `.poweredOn`, kick off a service-UUID scan if any paired scales exist.
  - [ ] Subtask 3.4: On `didDiscover` of a paired peripheral, stop scan, connect, discover service/chars, subscribe to FF11, hold FF12 for writes.
  - [ ] Subtask 3.5: On `didDisconnect`, restart scan after a 2s backoff.
  - [ ] Subtask 3.6: Initialize `BookooManager.shared` in `FormulaHelperApp.init()` so the restoration identifier is claimed early.

- [ ] **Task 4 — Pairing store + UI** (AC: 4, 5, 13)
  - [ ] Subtask 4.1: Create `BookooPairing.swift` with `PairedScale` struct + an enum/helper for read/write to App Group defaults.
  - [ ] Subtask 4.2: Create `BookooPairingView.swift` matching `SettingsView`'s style. Three sections: paired list, scan results, action button.
  - [ ] Subtask 4.3: Add a "Bookoo Scales" row to `SettingsView` → Account section that pushes `BookooPairingView`.
  - [ ] Subtask 4.4: Add scan/discovery logic exposed by `BookooManager` (a `@Published` array of discovered peripherals while scan is active).

- [ ] **Task 5 — State machine** (AC: 9, 10, 12)
  - [ ] Subtask 5.1: Create `BookooSession.swift` as a `@MainActor` actor with the state enum and transition logic.
  - [ ] Subtask 5.2: Feed every weight packet into the session via `BookooManager` → if the peripheral changes, swap sessions (one per peripheral, addressed by peripheral.identifier).
  - [ ] Subtask 5.3: On `.lifted`, compute ml using `CacheManager.shared.restore()?.settings.powder_per_60`.
  - [ ] Subtask 5.4: Wire the idle timeout (90 s) using `Task.sleep` + cancellation on every transition.
  - [ ] Subtask 5.5: Wire the post-log cooldown (60 s).

- [ ] **Task 6 — Log + beep + notification** (AC: 11)
  - [ ] Subtask 6.1: On `.lifted`, fire the two APIClient calls sequentially. Bail on first failure but persist to retry queue (Task 7).
  - [ ] Subtask 6.2: Write `CMD_START_TIMER` to FF12. Best-effort.
  - [ ] Subtask 6.3: Schedule a local `UNNotificationRequest` via `NotificationManager`. Title + body per AC 11. Identifier `bookoo-log-\(sk)` so the existing notif tap-to-edit pattern works.

- [ ] **Task 7 — Failure paths** (AC: 12)
  - [ ] Subtask 7.1: Implement the persisted retry queue with cap 10 in App Group defaults under `bookoo.pending_logs`.
  - [ ] Subtask 7.2: On app foreground (existing `task { ... }` in `ContentView`), flush the retry queue.
  - [ ] Subtask 7.3: Also try flush on every successful BLE log so backlog drains opportunistically.

- [ ] **Task 8 — Build + sim sanity + dev TestFlight ship** (AC: 14)
  - [ ] Subtask 8.1: `xcodegen generate && xcodebuild ... build` clean for the FormulaHelper target.
  - [ ] Subtask 8.2: `/sim-reload` and confirm the existing UI still works (sanity only — Bookoo doesn't function in sim).
  - [ ] Subtask 8.3: `/testflight-release` (dev — branch is `dev_bookoo`, falls under `dev_*` auto-route).
  - [ ] Subtask 8.4: Run the on-device manual matrix from AC 14.

## Dev Notes

### Relevant architecture patterns and constraints

- **No backend changes.** Story 4.1 reuses `APIClient.logEntry` and `APIClient.startFeeding`. The server doesn't need to know the entry came from a Bookoo — that's iOS-internal.
- **App Group is the shared store.** Pairing state lives in `UserDefaults(suiteName: "group.com.ashokteja.formulahelper")`. Same suite as `CacheManager` so future widget/Siri integration can see pair state if needed.
- **State restoration timing.** `CBCentralManager` MUST be created in the app's main thread before `application(_:didFinishLaunchingWithOptions:)` returns or iOS won't reattach the restoration identifier. SwiftUI's `App.init()` runs synchronously before the launch sequence completes — that's the right hook.
- **NotificationManager already supports remote-action taps** (existing pattern from the household-notification work). Reuse its `scheduleLocal(...)` helper.
- **Bookoo BLE distance.** Class-2 BLE, advertised range ~10 m line-of-sight. The user's overnight workflow has the phone in another room — verify range in manual matrix.
- **Bookoo command structure** matches `ios/BookooReference/scale.py`. The 6-byte command frames + XOR checksum logic is identical; the Python implementation is a clean reference.
- **Cooldown rationale.** Without the 60 s post-log cooldown, the very common "put the bottle back on briefly to free up a hand" gesture would trigger a second log.

### Source tree components to touch

- `ios/FormulaHelper/Bookoo/BookooManager.swift` (new)
- `ios/FormulaHelper/Bookoo/BookooPacket.swift` (new)
- `ios/FormulaHelper/Bookoo/BookooCommands.swift` (new)
- `ios/FormulaHelper/Bookoo/BookooPairing.swift` (new)
- `ios/FormulaHelper/Bookoo/BookooSession.swift` (new)
- `ios/FormulaHelper/Bookoo/BookooPairingView.swift` (new)
- `ios/FormulaHelper/FormulaHelperApp.swift` (modify — init the manager early)
- `ios/FormulaHelper/Views/SettingsView.swift` (modify — add "Bookoo Scales" row)
- `ios/project.yml` (modify — Info.plist UIBackgroundModes + NSBluetoothAlwaysUsageDescription)

### Testing standards summary

No iOS test target exists. Manual matrix per AC 14 is the entire verification. App Intents have a `unit-testable` `perform()` in principle, but CoreBluetooth is delegate-driven and hard to unit-test without a test target — defer.

### Project structure notes

- New top-level group under `FormulaHelper/Bookoo/`. xcodegen treats source directories declaratively — anything under `sources: - path: FormulaHelper` is included.
- Reference materials at `ios/BookooReference/` (the restored Python script + protocol doc) — read-only, not compiled into any target.

### References

- Apple, "Core Bluetooth Background Processing for iOS Apps" — https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html
- Apple, "State Preservation and Restoration" (CoreBluetooth section)
- Source: `ios/BookooReference/protocols.md` — service/char UUIDs, packet layout, command list
- Source: `ios/BookooReference/scale.py` — Python reference implementation
- Source: `ios/FormulaHelper/Networking/APIClient.swift::logEntry` + `startFeeding` — the two server calls
- Source: `ios/FormulaHelper/Models/AppState.swift::AppSettings.powder_per_60` — formula ratio
- Source: `ios/FormulaHelper/Cache/CacheManager.swift` — App Group UserDefaults suite

## Dev Agent Record

### Agent Model Used
_(To be filled by dev-story agent)_

### Debug Log References

### Completion Notes List

### File List

## Open Questions / Clarifications

1. **Should the per-scale "Auto-log enabled" toggle ship in 4.1 or wait for 4.3?** Story 4.3 is currently sketched as the home for it. Recommendation: defer to 4.3 to keep this story focused.

2. **`CMD_START_TIMER` vs `CMD_TARE_AND_START`** for the beep. Plan locks `CMD_START_TIMER` because the bottle is already off the scale by the time we send it. Confirm.

3. **Discovered-peripheral naming.** Bookoo advertises a generic name; we should let the user rename inline on first pair. Should we attempt to read the device-info characteristic (manufacturer, model, serial) for a default name? Or just "Bookoo (1)", "Bookoo (2)"? Recommendation: numeric default + inline rename.

4. **Foreground-only mode toggle.** Some users may want auto-log only when foregrounded (privacy / battery comfort). Worth a Settings switch in 4.1 or defer? Recommendation: defer.
