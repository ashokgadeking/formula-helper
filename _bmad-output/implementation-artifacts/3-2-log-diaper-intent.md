# Story 3.2: Log a diaper via Siri

Status: ready-for-dev

**Epic:** 3 — Siri logging via App Intents
**Story ID:** 3.2
**Story Key:** 3-2-log-diaper-intent
**Depends on:** Story 3-1-log-bottle-intent (foundation: `AvantiLogShortcuts`, auth/error patterns).

## Story

As a **parent mid-diaper-change**,
I want to **say "Hey Siri, log a pee diaper" or "log a poo diaper" and have it recorded**,
so that **I capture the event before getting distracted by the next task**.

## Acceptance Criteria

1. **`LogDiaperIntent: AppIntent`** at `ios/FormulaHelper/AppIntents/LogDiaperIntent.swift`. Same shape as `LogBottleIntent` but for diapers.

2. **One required parameter: `type: DiaperType`.** A new `enum DiaperType: String, AppEnum` provides cases `pee` and `poo` with `localizedStringResource` "Pee" / "Poo" so Siri's parameter resolution picks them by spoken word. Use `static var typeDisplayRepresentation: TypeDisplayRepresentation = "Diaper Type"`.

3. **Phrases added to `AvantiLogShortcuts.appShortcuts`** (the provider created in 3-1). Append a second `AppShortcut` entry:
   - "Log a diaper in \(.applicationName)"
   - "Log a \(\.$type) diaper in \(.applicationName)"
   - "Record a \(\.$type) diaper in \(.applicationName)"
   - "Mark a \(\.$type) in \(.applicationName)"
   `shortTitle: "Log Diaper"`, `systemImageName: "drop.triangle.fill"` (or any close glyph).

4. **`perform()` calls `APIClient.shared.logDiaper(type:date:)`** with `type: parameter.rawValue` (`"pee"` / `"poo"`), `date: nil`. Server stamps the entry with current time.

5. **Auth gate, error handling, success dialog — same patterns as 3-1.**
   - Unauthenticated: `.result(dialog: "Open Formula Helper to sign in, then try again.")`
   - 401 from APIClient: same dialog.
   - Other errors: `.result(dialog: "Couldn't log the diaper — try again or open the app.")`
   - Success: `.result(dialog: "Logged a \(type.rawValue) diaper.")` — note the lowercase "pee"/"poo" reads naturally; Siri's TTS will pronounce them as expected.

6. **State refresh — same decision as 3-1 (likely option b, skip in-process refresh).** Whatever 3-1 picks, this story matches.

7. **No backend changes.** `POST /api/diaper` already exists; `APIClient.logDiaper` is wired.

8. **Manual verification on device:**
   - "Hey Siri, log a pee diaper in Formula Helper Dev" → success dialog within ~2s. Open app → Logs → Diapers → today shows the new entry with `type: "pee"`.
   - "Hey Siri, log a poo diaper in Formula Helper Dev" → same, but `type: "poo"`.
   - "Hey Siri, log a diaper in Formula Helper Dev" → Siri prompts "Pee or poo?" → answer "pee" → success.
   - Try a malformed parameter ("log a yellow diaper") → Siri reprompts.
   - Sign out → invoke → auth-required dialog.
   - Airplane mode → invoke → network-error dialog.

## Tasks / Subtasks

- [ ] **Task 1 — `DiaperType` AppEnum** (AC: 2)
  - [ ] Subtask 1.1: Create `ios/FormulaHelper/AppIntents/DiaperType.swift`. Define `enum DiaperType: String, AppEnum { case pee, poo }`.
  - [ ] Subtask 1.2: Implement `static var typeDisplayRepresentation: TypeDisplayRepresentation = "Diaper Type"`.
  - [ ] Subtask 1.3: Implement `static var caseDisplayRepresentations: [DiaperType: DisplayRepresentation]` mapping `.pee → "Pee"`, `.poo → "Poo"`.

- [ ] **Task 2 — `LogDiaperIntent`** (AC: 1, 4, 5)
  - [ ] Subtask 2.1: Create `ios/FormulaHelper/AppIntents/LogDiaperIntent.swift`.
  - [ ] Subtask 2.2: Define `struct LogDiaperIntent: AppIntent` with `@Parameter(title: "Type") var type: DiaperType`.
  - [ ] Subtask 2.3: Implement `perform()` mirroring 3-1's auth gate + error handling. Call `try await APIClient.shared.logDiaper(type: type.rawValue, date: nil)`.

- [ ] **Task 3 — Wire phrases** (AC: 3)
  - [ ] Subtask 3.1: In `AvantiLogShortcuts.appShortcuts`, append a second `AppShortcut(intent: LogDiaperIntent(), phrases: [...], shortTitle: "Log Diaper", systemImageName: "drop.triangle.fill")`.

- [ ] **Task 4 — Build + verify** (AC: 8)
  - [ ] Subtask 4.1: `cd ios && xcodegen generate && xcodebuild ...build` clean.
  - [ ] Subtask 4.2: `/sim-reload` for sanity.
  - [ ] Subtask 4.3: `/testflight-release` to push to dev TestFlight; run AC 8 matrix on-device.

## Dev Notes

### Relevant architecture patterns and constraints

- **`AppEnum` is the iOS 16+ way to expose a typed enum to Siri.** Siri uses `caseDisplayRepresentations` to match spoken words. "pee" and "poo" are short and unambiguous; no synonym handling needed.
- **`type.rawValue`** — DiaperType's raw values match exactly what `APIClient.logDiaper(type:)` expects (`"pee"` / `"poo"`). No translation needed.

### Source tree components to touch

- `ios/FormulaHelper/AppIntents/DiaperType.swift` (new)
- `ios/FormulaHelper/AppIntents/LogDiaperIntent.swift` (new)
- `ios/FormulaHelper/AppIntents/AvantiLogShortcuts.swift` (modified — append shortcut entry)

### Testing standards summary

Same as 3-1: manual on-device only.

### References

- Source: `ios/FormulaHelper/Networking/APIClient.swift::logDiaper(type:date:)`
- Sibling: `_bmad-output/implementation-artifacts/3-1-log-bottle-intent.md` for the foundation patterns this story reuses
- Apple, "Adopting Siri" / `AppEnum` documentation

## Dev Agent Record

### Agent Model Used

_(To be filled by dev-story agent)_

### Debug Log References

### Completion Notes List

### File List

## Open Questions / Clarifications

None — straightforward replication of 3-1's pattern with a typed enum parameter.
