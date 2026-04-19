# Formula Helper — iOS App PRD

## Overview

Native SwiftUI app for iPhone, mirroring the existing web app's functionality with additions exclusive to mobile: Dynamic Island Live Activities, home/lock screen widgets, and APNs push notifications. The web app and iOS app share the same AWS backend (API Gateway + Lambda + DynamoDB).

**Primary devices:** iPhone 17 Pro, iPhone 17 Pro Max
**Distribution:** TestFlight (internal), App Store optional later
**Minimum target:** iOS 18+
**Developer account:** Apple Developer Program (personal/individual)

---

## Goals

- Full parity with the web app for logging, state tracking, and settings
- Zero-delay state display via local cache (matching web app behavior)
- Passkey authentication via platform authenticator (Face ID)
- Live Activity in Dynamic Island showing active feeding countdown
- Home screen and lock screen widgets for glanceable state
- APNs push for bottle expiry alerts (replacing ntfy.sh on iOS)
- Shared passkeys between web and iOS via Associated Domains

---

## Non-Goals

- Android app
- Apple Watch app (not in scope for v1)
- Offline-first / full sync — requires connectivity for all writes
- iPad layout optimization

---

## Architecture

### Xcode Targets

| Target | Type | Purpose |
|--------|------|---------|
| `FormulaHelper` | iOS App | Main app |
| `FormulaHelperLiveActivity` | Notification Service Extension | Dynamic Island + Lock Screen Live Activity |
| `FormulaHelperWidget` | Widget Extension | Home screen + Lock Screen widgets |

### Shared Data (App Groups)
All three targets share an App Group (`group.com.yourname.formulahelper`) for:
- Cached state (UserDefaults)
- Last-fetch timestamp

### API Client
Single `APIClient.swift` used by the app target; widgets and Live Activities consume cached state only (no direct API calls).

---

## Phases

### Phase 1 — Scaffold + Auth + Core State
**Goal:** App launches, authenticates via passkey, and displays the current bottle state.

**Deliverables:**
- Xcode project with all three targets scaffolded
- `APIClient.swift` — typed Swift wrapper over existing REST API
- `AuthManager.swift` — WebAuthn/passkey registration and login via `AuthenticationServices`
- `StateModel.swift` — mirrors the JSON shape from `/api/state`
- `ContentView.swift` — banner (bottle mixed, timer), last fed row, next feeding estimate
- `CacheManager.swift` — read/write App Group UserDefaults; adjusts `remaining_secs` by elapsed time on restore
- Associated Domains entitlement pointing to CloudFront domain
- Backend: serve `apple-app-site-association` (AASA) file from CloudFront/S3

**API endpoints used:**
- `POST /api/auth/login-options`
- `POST /api/auth/login-verify`
- `POST /api/auth/register-options`
- `POST /api/auth/register-verify`
- `GET /api/state`

**Acceptance criteria:**
- Cold launch shows cached state instantly (no blank screen)
- Face ID registers and authenticates successfully
- Active session persists across app restarts (cookie jar persisted)
- Banner timer counts down live

---

### Phase 2 — Logging + Diaper + Settings
**Goal:** All write actions available in the app.

**Deliverables:**
- Log feeding sheet (preset amounts + custom amount input)
- Edit / delete log entry
- Pee / Poo diaper buttons + delete
- Settings screen (Timer tab: reset timer; Users tab: invite, list, revoke passkey, remove user — ashok only)
- Weight log entry (manual, matching web app)

**API endpoints used:**
- `POST /api/start`
- `POST /api/log`, `PUT /api/log/{sk}`, `DELETE /api/log/{sk}`
- `POST /api/diaper`, `DELETE /api/diaper/{sk}`
- `POST /api/weight`
- `POST /api/reset-timer`
- `GET/POST/DELETE /api/auth/allowed-users`
- `GET/DELETE /api/auth/credentials`, `DELETE /api/auth/credentials/{cred_id}`

**Acceptance criteria:**
- All log actions round-trip to DynamoDB correctly
- Settings restricted to ashok (same as web)
- Optimistic UI update on write (don't wait for poll)

---

### Phase 3 — Live Activity (Dynamic Island)
**Goal:** Active feeding countdown visible in Dynamic Island and Lock Screen without opening the app.

**Deliverables:**
- `FeedingActivityAttributes.swift` — `ActivityAttributes` conformance with `ContentState` (remaining secs, ml mixed)
- `LiveActivityView.swift` — compact leading/trailing, minimal, expanded, and lock screen layouts
- App starts Live Activity on `POST /api/start` response
- App updates Live Activity on each poll (remaining secs, expired flag)
- App ends Live Activity when timer expires or reset
- Backend: ActivityKit push token endpoint (`POST /api/apns/live-activity`) to allow server-push updates

**Dynamic Island layouts:**

| View | Content |
|------|---------|
| Compact leading | Bottle icon |
| Compact trailing | Countdown timer `MM:SS` |
| Minimal | Countdown timer |
| Expanded | Bottle mixed label + countdown + next feeding estimate |
| Lock Screen | Full card: last fed, ml mixed, countdown |

**Acceptance criteria:**
- Live Activity appears within 1s of starting a feeding
- Timer stays accurate when app is backgrounded
- Live Activity dismissed automatically on expiry

---

### Phase 4 — Widgets
**Goal:** Glanceable state on home screen and lock screen without opening the app.

**Deliverables:**
- `FormulaEntry.swift` — `TimelineEntry` with state snapshot
- `FormulaProvider.swift` — `TimelineProvider` fetching from cache (App Group); refreshes every 5 min via background task
- Widget views:

| Kind | Sizes | Content |
|------|-------|---------|
| Home screen | Small, Medium | Last fed time, ml mixed, next feeding estimate |
| Lock Screen inline | — | "Last fed Xh Xm ago" |
| Lock Screen circular | — | Bottle icon + time since |
| Standby | Full screen | Large banner matching app style |

**Acceptance criteria:**
- Widget updates within 5 min of a new feeding being logged
- Tapping widget deep-links to app home screen
- Standby widget readable at a glance in landscape

---

### Phase 5 — APNs Push Notifications
**Goal:** Replace ntfy.sh alerts with native iOS push for bottle expiry.

**Deliverables:**
- APNs push certificate / auth key registered in Apple Developer portal
- Backend: `POST /api/apns/register` — store APNs device token in DynamoDB
- Backend: expiry notification sent via APNs when bottle timer expires (Lambda scheduled event or triggered on state poll)
- App registers for push on first launch (after auth)
- Notification payload: "Bottle expired — time to make a fresh one"

**Acceptance criteria:**
- Notification arrives within 60s of expiry
- Tapping notification opens app home screen
- No notification if app is foregrounded
- ntfy.sh dependency removed from Lambda (or kept as fallback for Pi)

---

### Phase 6 — Polish + TestFlight
**Goal:** App ready for internal TestFlight distribution on both devices.

**Deliverables:**
- App icon (all required sizes)
- Launch screen / splash consistent with web app palette
- Haptic feedback on log actions
- Error handling and offline state messaging
- TestFlight build uploaded
- Both devices added as internal testers

**Acceptance criteria:**
- Passes App Store Connect automated checks
- Installs cleanly on iPhone 17 Pro and iPhone 17 Pro Max
- No crashes on cold launch, background, or foreground

---

## Backend Changes Required

| Change | Phase | Notes |
|--------|-------|-------|
| Serve `apple-app-site-association` via CloudFront | 1 | Required for Associated Domains / shared passkeys |
| `POST /api/apns/live-activity` — store ActivityKit push token | 3 | Enables server-push Live Activity updates |
| `POST /api/apns/register` — store APNs device token | 5 | Per-device, stored in DynamoDB |
| APNs notification send on bottle expiry | 5 | Lambda → APNs HTTP/2 API |

All other backend endpoints are already implemented and compatible.

---

## Data Model Additions (DynamoDB)

```
PK=APNS#<user_name>  SK=DEVICE#<token>   → APNs device token
PK=APNS#<user_name>  SK=LIVE#<token>     → ActivityKit push token
```

---

## Tech Stack

| Layer | Choice |
|-------|--------|
| Language | Swift 6 |
| UI | SwiftUI |
| Auth | `AuthenticationServices` (ASWebAuthenticationSession + platform passkey) |
| Networking | `URLSession` with async/await |
| Live Activities | `ActivityKit` |
| Widgets | `WidgetKit` |
| Push | `UserNotifications` + APNs HTTP/2 |
| State sharing | `UserDefaults` (App Group) |
| Minimum iOS | 18.0 |

---

## Open Questions

1. **Team ID / bundle ID**: needs to be set before Associated Domains can be configured on the backend.
2. **APNs auth key vs certificate**: auth key (`.p8`) preferred — doesn't expire, single key for all apps.
3. **ntfy.sh**: keep as Pi-only notification channel, or remove entirely once APNs is live?
4. **Weight tracking**: CSV upload from Greater Goods scale — in scope for v1 iOS or deferred?
