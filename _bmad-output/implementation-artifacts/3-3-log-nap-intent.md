# Story 3.3: Log a nap via Siri

Status: ready-for-dev

**Epic:** 3 — Siri logging via App Intents
**Story ID:** 3.3
**Story Key:** 3-3-log-nap-intent
**Depends on:** Story 3-1-log-bottle-intent (foundation: `AvantiLogShortcuts`, auth/error patterns).

## Story

As a **parent who just got the baby down**,
I want to **say "Hey Siri, log a nap" (optionally "for 45 minutes")**,
so that **the start of the nap is captured without disturbing the baby by tapping a phone**.

## Acceptance Criteria

1. **`LogNapIntent: AppIntent`** at `ios/FormulaHelper/AppIntents/LogNapIntent.swift`. Same shape as `LogBottleIntent`/`LogDiaperIntent`.

2. **One optional parameter: `durationMinutes: Int?`.** Marked `@Parameter(title: "Duration (minutes)", description: "How long the nap is expected to last, in minutes. Leave blank to log a nap with no duration.")` and made optional via Swift's `Int?` type. Range guard: nil OR (1 ≤ duration ≤ 480 minutes / 8 hours). Out-of-range throws a typed validation error.

3. **Phrases added to `AvantiLogShortcuts.appShortcuts`.** Append a third entry:
   - "Log a nap in \(.applicationName)"
   - "Log a nap for \(\.$durationMinutes) minutes in \(.applicationName)"
   - "Record a nap in \(.applicationName)"
   - "Mark a nap in \(.applicationName)"
   `shortTitle: "Log Nap"`, `systemImageName: "moon.zzz.fill"`.

4. **`perform()` calls `APIClient.shared.logNap(date:durationMins:)`** with `date: nil`, `durationMins: durationMinutes`. The server's `post_nap` accepts a missing `duration_mins` (writes nap with no duration).

5. **Auth gate, error handling, dialog — same patterns as 3-1.**
   - Unauthenticated → "Open Formula Helper to sign in, then try again."
   - 401 → same.
   - Other errors → "Couldn't log the nap — try again or open the app."
   - Success with duration → `.result(dialog: "Logged a \(duration)-minute nap.")`
   - Success without duration → `.result(dialog: "Logged a nap.")`

6. **State refresh — same decision as 3-1.**

7. **No backend changes.** `POST /api/nap` already exists; `APIClient.logNap` is wired.

8. **Manual verification on device:**
   - "Hey Siri, log a nap in Formula Helper Dev" → success dialog "Logged a nap." Open app → Logs → Naps → today shows the entry with no duration.
   - "Hey Siri, log a nap for 45 minutes in Formula Helper Dev" → success "Logged a 45-minute nap." Entry has `duration_mins: 45`.
   - "Hey Siri, log a nap for 600 minutes" (out of range) → Siri rejects or reprompts.
   - Sign out → invoke → auth-required dialog.
   - Airplane mode → invoke → network-error dialog.

## Tasks / Subtasks

- [ ] **Task 1 — `LogNapIntent`** (AC: 1, 2, 4, 5)
  - [ ] Subtask 1.1: Create `ios/FormulaHelper/AppIntents/LogNapIntent.swift`.
  - [ ] Subtask 1.2: Define `struct LogNapIntent: AppIntent` with `@Parameter(title: "Duration (minutes)", default: nil) var durationMinutes: Int?`.
  - [ ] Subtask 1.3: Implement `perform()`. Auth gate first. Range-validate `durationMinutes` if non-nil. Call `try await APIClient.shared.logNap(date: nil, durationMins: durationMinutes)`. Error and success dialogs match AC 5.

- [ ] **Task 2 — Wire phrases** (AC: 3)
  - [ ] Subtask 2.1: In `AvantiLogShortcuts.appShortcuts`, append a third `AppShortcut(intent: LogNapIntent(), phrases: [...], shortTitle: "Log Nap", systemImageName: "moon.zzz.fill")`.

- [ ] **Task 3 — Build + verify** (AC: 8)
  - [ ] Subtask 3.1: `cd ios && xcodegen generate && xcodebuild ...build` clean.
  - [ ] Subtask 3.2: `/sim-reload` sanity.
  - [ ] Subtask 3.3: `/testflight-release`; run AC 8 matrix on device.

## Dev Notes

### Relevant architecture patterns and constraints

- **Optional `Int` parameter.** App Intents support `Int?` parameters via `@Parameter`'s `default:` argument set to `nil`. Siri won't reprompt for a missing optional — phrases that don't include `\(\.$durationMinutes)` cleanly produce a nil-duration nap.
- **Phrase ambiguity check.** Siri picks the most specific phrase match. If a user says "log a nap for 45 minutes" Siri prefers the `\(\.$durationMinutes)` phrase; "log a nap" alone matches the no-parameter phrase. Verified by Apple's matching algorithm — no extra disambiguation needed in the intent.

### Source tree components to touch

- `ios/FormulaHelper/AppIntents/LogNapIntent.swift` (new)
- `ios/FormulaHelper/AppIntents/AvantiLogShortcuts.swift` (modified — append shortcut entry)

### Testing standards summary

Same as 3-1, 3-2: manual on-device only.

### References

- Source: `ios/FormulaHelper/Networking/APIClient.swift::logNap(date:durationMins:)`
- Sibling: `_bmad-output/implementation-artifacts/3-1-log-bottle-intent.md`

## Dev Agent Record

### Agent Model Used

_(To be filled by dev-story agent)_

### Debug Log References

### Completion Notes List

### File List

## Open Questions / Clarifications

None.
