# Story 3.1: Log a bottle via Siri (App Intents foundation)

Status: ready-for-dev

**Epic:** 3 — Siri logging via App Intents
**Story ID:** 3.1
**Story Key:** 3-1-log-bottle-intent

## Story

As a **parent with one hand on a baby**,
I want to **say "Hey Siri, log a 100ml bottle" and have it recorded immediately**,
so that **I don't have to put the baby down or open the app to track a feeding**.

## Acceptance Criteria

1. **iOS 16+ App Intent.** A new `LogBottleIntent: AppIntent` struct lives at `ios/FormulaHelper/AppIntents/LogBottleIntent.swift`. Uses the AppIntents framework (modern path), not SiriKit Custom Intents.

2. **One required parameter: `ml: Int`.** Marked `@Parameter(title: "Amount (ml)", description: "Milliliters in the bottle.")`. Range guard rejects ≤ 0 and > 999 with a typed error so Siri re-prompts cleanly.

3. **Phrase set discoverable to Siri.** A new `AvantiLogShortcuts: AppShortcutsProvider` struct lives at `ios/FormulaHelper/AppIntents/AvantiLogShortcuts.swift`. It declares phrases for `LogBottleIntent` including:
   - "Log a bottle in \(.applicationName)"
   - "Log a \(\.$ml) ml bottle in \(.applicationName)"
   - "Record a \(\.$ml) bottle in \(.applicationName)"
   - "Log \(\.$ml) milliliters in \(.applicationName)"
   `\(.applicationName)` resolves to the build's display name (`Formula Helper Dev` on DevRelease, `Formula Helper` on Release) so Siri matches the right phrase per build flavor.

4. **`perform()` calls the existing `APIClient.shared.logEntry(ml:date:)`** — no new endpoint. Uses the current Date() for `date` (as a server-formatted string). The optimistic-state logic in `StateViewModel.startFeeding` is *not* used here — Siri logs are write-and-confirm, not start-a-timer.

5. **Auth gate.** Before calling APIClient, the intent checks `AuthManager.shared.authState`:
   - If `.authenticated`: proceed.
   - If `.unauthenticated` or `.loading`: return `.result(dialog: "Open Formula Helper to sign in, then try again.")`. Do not throw — Siri handles a successful return with a dialog more gracefully than an error.

6. **Network/server error handling.** If `APIClient.logEntry` throws:
   - On `APIError.badStatus(401, _)`: same "Open Formula Helper to sign in" dialog.
   - On any other `APIError` or network error: `.result(dialog: "Couldn't log the bottle — try again or open the app.")`. Don't surface the raw error string to the user.

7. **Success dialog.** On success: `.result(dialog: "Logged \(ml) milliliters.")`. Siri reads this aloud. Keep it short — Siri's TTS gets cut off after a few seconds.

8. **State refresh after success.** Call `await StateViewModel.shared.refresh()` (or equivalent) so the dashboard's "since last bottle" card and Logs view reflect the new entry the next time the user opens the app. **Subtask flag:** `StateViewModel` is currently scoped per-`ContentView` via `@StateObject`. There is no shared singleton today. Decision in dev-story: either (a) introduce `StateViewModel.shared` as the canonical instance, or (b) skip the in-process refresh and rely on the next app foreground / 30s poll to pick up the entry. Option (b) is acceptable for v1 — flag as a TODO if we go with it.

9. **Project structure.** Create new directory `ios/FormulaHelper/AppIntents/`. `project.yml`'s `FormulaHelper` target's `sources:` already pulls everything under `FormulaHelper/`, so xcodegen picks it up with no additional config. Verify via `xcodegen generate` + xcodebuild that the new files compile cleanly into the main app target.

10. **No new entitlements, no new Info.plist keys, no provisioning profile changes.** App Intents on iOS 16+ work out of the box for an app target without extra configuration. (If iOS 17/18 ever requires `NSUserActivityTypes` or similar, address then.)

11. **Donation auto-handled.** The `AppShortcutsProvider` declaration registers the phrases with iOS automatically on first launch. No explicit `donate()` calls in v1.

12. **Manual verification on device** (Siri does not work reliably in the iOS Simulator):
    - Sign in to the dev TestFlight app at least once so the session cookie is present in `URLSession.shared.cookieStorage`.
    - Lock the device. Say "Hey Siri, log a 100ml bottle in Formula Helper Dev" → Siri responds with the success dialog within ~2s.
    - Open the app, navigate to Logs → Formula → today. Verify the entry is present with `ml = 100`.
    - Say "Log a bottle in Formula Helper Dev" without specifying ml → Siri prompts "What's the amount?" → answer "120" → success dialog.
    - Sign out (Settings → Account → Logout) → say "Log a 100ml bottle in Formula Helper Dev" → Siri responds with the "Open Formula Helper to sign in" dialog. App is *not* required to launch.
    - Toggle airplane mode → invoke intent → Siri responds with the network-error dialog.
    - Say "log a 99999 ml bottle" → Siri prompts again or rejects.

## Tasks / Subtasks

- [ ] **Task 1 — Foundation: AppShortcutsProvider** (AC: 3, 11)
  - [ ] Subtask 1.1: Create `ios/FormulaHelper/AppIntents/AvantiLogShortcuts.swift` with a `struct AvantiLogShortcuts: AppShortcutsProvider`. Empty `appShortcuts` array initially; populate after Task 2.
  - [ ] Subtask 1.2: Add `import AppIntents` at the top.

- [ ] **Task 2 — `LogBottleIntent`** (AC: 1, 2, 4, 5, 6, 7)
  - [ ] Subtask 2.1: Create `ios/FormulaHelper/AppIntents/LogBottleIntent.swift`.
  - [ ] Subtask 2.2: Define `struct LogBottleIntent: AppIntent` with `static var title`, `static var description`, and `@Parameter(title: ..., description: ...) var ml: Int` (type Int because `MeasurementUnit.milliliters` would force a Foundation Measurement parameter and the user phrase "100ml" parses cleaner as a plain Int).
  - [ ] Subtask 2.3: Implement `func perform() async throws -> some IntentResult`:
    1. Range check `ml > 0 && ml <= 999`; throw a typed validation error if not (use `IntentError.invalidParameter(...)` or a struct conforming to `LocalizedError`).
    2. Read `await AuthManager.shared.authState`. If not authenticated, return `.result(dialog: ...)` with the auth-required copy.
    3. Call `try await APIClient.shared.logEntry(ml: ml, date: nil)` (server fills `date` with `_now_ct()`).
    4. On `APIError.badStatus(401, _)` thrown by `APIClient`, return the auth-required dialog.
    5. On any other thrown error, return `.result(dialog: "Couldn't log the bottle — try again or open the app.")`.
    6. On success, return `.result(dialog: "Logged \(ml) milliliters.")`.

- [ ] **Task 3 — Wire shortcut phrases** (AC: 3)
  - [ ] Subtask 3.1: In `AvantiLogShortcuts.appShortcuts`, return `[AppShortcut(intent: LogBottleIntent(), phrases: [...], shortTitle: "Log Bottle", systemImageName: "drop.fill")]`. Use `\(.applicationName)` in phrases.

- [ ] **Task 4 — State refresh decision** (AC: 8)
  - [ ] Subtask 4.1: Choose option (a) `StateViewModel.shared` singleton, or (b) skip in-process refresh and rely on next-foreground. Document the decision in Dev Notes when this story is implemented.
  - [ ] Subtask 4.2 (option a only): Refactor `StateViewModel` to expose `static let shared` and migrate `ContentView` to use it instead of `@StateObject`.
  - [ ] Subtask 4.3 (option a only): Call `await StateViewModel.shared.refresh()` from `LogBottleIntent.perform()` after success.

- [ ] **Task 5 — Build + verify** (AC: 9, 10, 12)
  - [ ] Subtask 5.1: `cd ios && xcodegen generate && xcodebuild ... -configuration Debug build` — clean.
  - [ ] Subtask 5.2: `/sim-reload`. Confirm app launches and existing functionality works (sanity).
  - [ ] Subtask 5.3: `/testflight-release` (auto-picks dev from this branch per saved rule). Note: dev_siri is off main, but the saved rule routes `dev_*` branches to dev TestFlight. Verify branch-name routing still picks dev for `dev_siri`. If not, manually invoke with `dev` arg.
  - [ ] Subtask 5.4: Run the on-device manual matrix from AC 12 against TestFlight Dev.

## Dev Notes

### Relevant architecture patterns and constraints

- **No backend changes.** `APIClient.shared.logEntry(ml:date:)` already exists and hits `POST /api/log` (or `/api/feedings` on dev_auth's household-scoped path — but `dev_siri` is off main so we use main's flat single-user model). The endpoint stamps the entry with the server's current time when `date` is null.
- **Auth state on iOS.** `AuthManager.shared` is a `@MainActor final class`. `authState` is `@Published`. Reading it from `LogBottleIntent.perform()` requires hopping to the main actor: `await MainActor.run { AuthManager.shared.authState }`. The `perform()` is `async throws`, so this is straightforward.
- **No optimistic-state path.** The dashboard's `startFeeding` does optimistic UI updates. Siri intents are different — there's no UI to optimistically update, and Siri's response shouldn't be tied to UI rendering. Just call the network and respond.
- **`/sim-reload` is dev-only.** Real Siri end-to-end testing requires physical device + TestFlight Dev build because the simulator's Siri integration is partial.
- **AppShortcutsProvider is auto-discovered.** No need to register it in Info.plist or anywhere else — iOS scans the binary for the `AppShortcutsProvider` conformance at install time.

### Source tree components to touch

- `ios/FormulaHelper/AppIntents/AvantiLogShortcuts.swift` (new)
- `ios/FormulaHelper/AppIntents/LogBottleIntent.swift` (new)
- `ios/FormulaHelper/Views/ContentView.swift` (modified, only if option (a) for state refresh): refactor `vm` to consume `StateViewModel.shared`.
- `ios/project.yml` — no change. `sources: - path: FormulaHelper` already includes the new directory.

### Testing standards summary

- No iOS test target wired (`docs/architecture-ios.md#Known quirks`). Manual matrix per AC 12 is the entire verification.
- App Intents have a `unit-testable` `perform()` in principle; introducing tests here is out of scope until the test target itself is set up.

### Project structure notes

- **Alignment:** new top-level group under `FormulaHelper/AppIntents/`. xcodegen treats source directories declaratively — anything under `sources: - path: FormulaHelper` is included.
- **Conflicts / variances:** Story 3-2 and 3-3 will add files in the same directory. Foundation (AppShortcutsProvider) ships with this story; later stories just append to its `appShortcuts` array.
- **Naming:** intent struct `LogBottleIntent`. Phrases say "log a bottle" — natural-language consistency. Don't overload with "feeding" (the data model says feeding, but users say bottle).

### References

- Apple, "Adopting App Intents to support system experiences" — `https://developer.apple.com/documentation/appintents`
- Apple, "Designing App Shortcuts" — phrase guidelines (use `applicationName`, keep short, use parameter `\(\.$x)` syntax)
- Source: `ios/FormulaHelper/Networking/APIClient.swift::logEntry(ml:date:)` — the call this intent makes
- Source: `ios/FormulaHelper/Auth/AuthManager.swift` — `authState` read pattern
- Source: `ios/project.yml` — `sources: - path: FormulaHelper` confirms no project-file edit needed

## Dev Agent Record

### Agent Model Used

_(To be filled by dev-story agent)_

### Debug Log References

### Completion Notes List

### File List

## Open Questions / Clarifications

1. **`StateViewModel.shared` refactor (AC 8 / Task 4).** Adding a singleton is a small but real architectural change. Acceptable?
   - **Lighter alternative:** post a `Notification.Name("siriIntentCompleted")` from `perform()`, observe in `StateViewModel.load()`. Less invasive but feels overengineered for a 30-second-poll-anyway state.
   - **Recommended:** option (b) — skip the refresh, let the existing scenePhase + 30s poll handle reconciliation. Document as a known-30s-staleness if user opens the app within seconds of the Siri command.

2. **Phrase set length.** The four phrases in AC 3 are a starting set. Apple's HIG suggests ≤ 5 phrases per shortcut. Open to expanding ("Add a 100ml feeding", "Mark a 100 milliliter bottle", etc.) if the basic set feels brittle in dogfooding.

3. **Localized strings.** All intent strings are English-only here. Localization is out of scope until there's an actual second language target.
