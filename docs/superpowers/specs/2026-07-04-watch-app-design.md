# Apple Watch App — Design

**Date:** 2026-07-04
**Branch:** `watch-app`
**Status:** Awaiting user review

## Purpose

A watchOS companion app for AvantiLog so a parent can log and check feedings
without pulling out the phone — typically one-handed, baby in the other arm.

Scope decided (user was away; assumptions flagged in Open Questions):

- **v1 (this spec):** quick logging (feed / diaper / nap) + glanceable status
  (time since last feed, countdown, today's totals).
- **Phase 2 (out of scope here):** watch-face complication via a watchOS
  widget extension, wrist-side countdown alerts.

## Approaches considered

1. **Direct-to-API watch app with session relay (recommended, chosen).**
   The watch talks to the existing CloudFront/Lambda API itself. The phone
   relays the 30-day session token once via WatchConnectivity; the watch
   injects it as the `session` cookie. Works even when the phone is asleep or
   out of reach (WiFi/LTE), reuses the whole existing API surface, zero
   backend changes.
2. **Phone-proxy via WatchConnectivity.** Watch sends messages; the phone
   makes the API calls. No auth work on the watch, but every action needs the
   phone reachable and the iOS app alive in the background — flaky exactly
   when you want the watch (phone in another room).
3. **Status-only mirror.** Complication + read-only state, no logging.
   Least work, but misses the main use-case (logging one-handed).

## Architecture

New xcodegen target `FormulaHelperWatch` (SwiftUI, watchOS 11.0, bundle id
`com.ashokteja.formulahelper.watchkitapp`), embedded in the iOS app.

### Shared code (compiled into both targets)

- `Models/AppState.swift` — response models, unchanged.
- `Networking/APIClient.swift` — unchanged. On the watch, the synced session
  token is inserted into `HTTPCookieStorage.shared` as a `session` cookie for
  the API host at launch, so the actor works as-is.

### Watch-only code (`ios/FormulaHelperWatch/`)

- `WatchApp.swift` — app entry, WCSession activation.
- `SessionSync.swift` (watch side) — receives the session token from
  `applicationContext`, stores it in UserDefaults, installs the cookie.
- `WatchRootView.swift` — single scrolling screen:
  - Header: time since last feed (or countdown remaining if active), today's
    totals (ml, diaper count, nap count).
  - Two preset feed buttons (from `settings.preset1_ml`/`preset2_ml`, same
    fallbacks as iOS: 90/120), plus a crown-adjustable custom amount.
  - Diaper buttons: Pee / Poo (one tap, `logDiaper`).
  - Nap button (one tap, `logNap()` with nil duration — same as iOS).
- `WatchViewModel.swift` — fetches `/api/state` on activation/foreground,
  optimistic local update after each log, then refetch.

### iOS-side addition

- `SessionRelay.swift` — on app foreground and after successful login, reads
  the `session` cookie from `HTTPCookieStorage.shared` and pushes it via
  `WCSession.updateApplicationContext` (durable, delivered even if the watch
  app is closed). Also re-pushed when the cookie value changes.

### Feed logging semantics

Watch preset buttons call `startFeeding(ml:)` (same as the iOS home-screen
cards) so the countdown timer starts, matching phone behavior. The custom
crown amount also uses `startFeeding`.

## Data flow

1. Phone login → session cookie → relayed to watch via applicationContext.
2. Watch launch/foreground → install cookie → `GET /api/state` → render.
3. Tap log button → optimistic UI bump + haptic → API call → silent refetch.
4. API 401 → clear stored token, show "Open AvantiLog on your iPhone to
   sign in" screen; recovery is automatic next time the phone app opens.

## Error handling

- **No session yet:** dedicated "sign in on iPhone" screen (not an alert).
- **Network failure on log:** roll back optimistic update, error haptic +
  brief toast; no retry queue in v1 (user just taps again).
- **Stale state:** header recomputes "time since last feed" every minute via
  `TimelineView`; data refetches on foreground.

## Testing

- Unit tests for the session-cookie install + 401-reset logic (watch target).
- Manual: watch simulator paired with iPhone simulator for the relay path;
  the existing `sim-reload` flow covers the iOS side. Real-device check
  before any TestFlight build (watch apps upload with the same archive).

## Open questions / assumptions to confirm

1. **Scope assumption:** quick logging + glanceable status is the right v1;
   complication and wrist alerts deferred to phase 2.
2. **watchOS 11.0 minimum** — matches the iOS 18 baseline. Needs to be ≤ the
   OS on Ashok's actual watch.
3. Feed buttons start the countdown timer (`/api/start`), same as phone.
