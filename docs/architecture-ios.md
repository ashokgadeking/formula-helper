# Architecture — iOS (`ios/`)

## Executive summary

Single-target SwiftUI app (iOS 18+, Swift 6.0) with a widget extension. Uses xcodegen to regenerate `FormulaHelper.xcodeproj` from `ios/project.yml`. Three build configurations (`Debug`, `DevRelease`, `Release`) drive three logical environments: Debug → dev stack with auto-signing and dev bundle id; DevRelease → manually-signed AvantiLog Dev for TestFlight; Release → manually-signed AvantiLog for App Store.

## Source tree

```
ios/FormulaHelper/
├── FormulaHelperApp.swift              # @main entry, wires AuthManager + StateViewModel
├── DesignSystem.swift                  # color tokens + Outfit font helpers
├── Info.plist                          # uses $(CURRENT_PROJECT_VERSION) + custom keys
├── FormulaHelper.Dev.entitlements      # Debug + DevRelease
├── FormulaHelper.Prod.entitlements     # Release
├── Auth/
│   └── AuthManager.swift               # SIWA + passkey flows, ASAuthorizationController glue
├── Networking/
│   └── APIClient.swift                 # URLSession singleton, JSON helpers, route methods
├── Models/
│   └── AppState.swift                  # Codable payload shapes + Household/Member/Invite models
├── Cache/
│   └── CacheManager.swift              # App Group UserDefaults cache of last /api/state
├── Views/
│   ├── ContentView.swift               # Root tab container + StateViewModel
│   ├── AuthView.swift                  # signed-out screen + paged signup flow
│   ├── LogsView.swift                  # feedings/diapers/naps log tab
│   ├── TrendsView.swift                # charts
│   └── SettingsView.swift              # Household, timer, presets, account — incl. HouseholdDetailView + Danger Zone
├── Notifications/
│   └── NotificationManager.swift       # local notification scheduling for bottle expiry
├── LiveActivity/
│   └── FormulaActivityAttributes.swift # shared with widget extension
└── Resources/
    ├── Assets.xcassets/                # AppIcon, AppIcon-Dev, color sets
    └── Fonts/Outfit-Variable.ttf
```

## Build configuration map

| Config | Bundle id | Display name | Signing | API base URL | RP ID | Notes |
|---|---|---|---|---|---|---|
| Debug | `com.ashokteja.formulahelper` | Formula Helper | Automatic | `https://3lgqmzurih.execute-api.us-east-1.amazonaws.com` (dev API GW) | dev hostname | Wired to dev stack — `IS_DEV_STACK=YES`, Dev entitlements, dev icon catalog. Used in simulator (SIWA is broken in sim, so auth testing goes through DevRelease on-device). |
| DevRelease | `com.ashokteja.formulahelper.dev` | Formula Helper Dev | Manual, `AvantiLog Dev AppStore` profile | dev host | dev host | AvantiLog Dev TestFlight app (ASC id `6763331013`) |
| Release | `com.ashokteja.formulahelper` | Formula Helper | Manual, `FormulaHelperAppStore` profile | `https://d20oyc88hlibbe.cloudfront.net` | CloudFront host | AvantiLog production TestFlight + App Store |

Anything read as `$(...)` in Info.plist (`APIBaseURL`, `RPID`, `IsDevStack`, `APP_DISPLAY_NAME`) is injected from the config's build settings in `project.yml`, not hardcoded.

## Key architectural patterns

### Auth (`Auth/AuthManager.swift`)

- `AuthState` enum: `.loading`, `.authenticated(userName, userId, activeHh)`, `.unauthenticated`. `@MainActor` `AuthManager.shared` exposes `authState` as `@Published`.
- Three credential flows all funnel through `perform(request:)`, a `withCheckedThrowingContinuation` wrapper around `ASAuthorizationController`:
  1. **signIn()** — `loginOptions()` → `performAssertion()` → `loginVerify()` (passkey)
  2. **beginSignUp() + completeSignUp()** — SIWA first for identity, then `registerStart()` → `performRegistration()` → `registerFinish()` (passkey). Accepts optional `inviteToken` to join an existing household.
  3. **recover()** — SIWA → `recoverStart()` → new passkey registration → `recoverFinish()`. Does not create a new account; reattaches to the existing user keyed by `apple_sub`.
- `requestSiwaCredential()` requests `.fullName` and `.email` scopes. **Apple only returns `fullName` on the first authorization for a given Apple ID ↔ bundle id pair** — subsequent calls return nil. This is Apple behavior, not a bug; the signup flow treats the name field as editable.
- `ASAuthorizationControllerDelegate` methods are nonisolated and hop back to main for continuation resume. Known warnings about main-actor isolation on `UIApplication.connectedScenes.windows.first { isKeyWindow }` — pre-existing, not blocking.

### Networking (`Networking/APIClient.swift`)

- `APIClient.shared` singleton. Uses `URLSession.shared` with JSON encode/decode helpers.
- Base URL read from `Bundle.main.object(forInfoDictionaryKey: "APIBaseURL")` at startup.
- Convenience methods per endpoint (`listHouseholds`, `createInvite`, `redeemInvite`, `listMembers`, `kickMember`, `startFeeding`, `logEntry`, …). See `api-contracts-lambda.md` for the full surface.
- All protected endpoints carry a session cookie/token set by login; the iOS client relies on `URLSession`'s default cookie storage.

### State (`Views/ContentView.swift` — `class StateViewModel`)

- `ObservableObject` holding the last `AppStateResponse`.
- `refresh()` fetches `/api/state`, updates published properties, and drives UI reactivity.
- Used from every feature view via `@ObservedObject var vm: StateViewModel`.

### Cache (`Cache/CacheManager.swift`)

- Caches last `AppStateResponse` + `fetchedAt` in App Group UserDefaults so the widget + live activity can render without a network hit.

### Design system (`DesignSystem.swift`)

- `Color.primaryBackground`, `.secondaryBackground`, `.elevatedBackground`, `.primaryLabel`, `.secondaryLabel`, `.tertiaryLabel`, `.opaqueSeparator`, `.greenFill`, `.greenBorder` — all resolved from asset catalog color sets.
- `Font.outfit(size, weight:)` + `.appFont(style)` helpers wrap the Outfit variable font.

### Settings / Household (`Views/SettingsView.swift`)

- Settings root `List` has sections: Household, Timer, Presets, Account, About.
- Household section renders a `NavigationLink` that pushes `HouseholdDetailView` for the active household. Members are **prefetched** during `loadHouseholds()` and handed to the detail view as initial state, so they render immediately on navigation.
- `HouseholdDetailView` has three sections:
  - **Members** — sorted owner → admin → member, then alphabetically. Avatar initials. Swipe-trailing red trash action on kickable rows (owner viewing non-owner, non-self). Chevron-left hint glyph on kickable rows; footer text "Swipe left on a member to remove them."
  - **Invite** — only rendered when `isOwner` (`household.role.lowercased() == "owner"`).
  - **Danger Zone** — Leave (always), Delete (owners only). Matching confirmation dialogs + an alert when an owner tries to leave without transferring ownership.
- "Redeem invite code" stays on the Settings root so it's reachable without an active household.

### Notifications (`Notifications/NotificationManager.swift`)

- Schedules a local notification at bottle countdown expiry. Currently local-only; push (APNs) is parked (see `TODO.md` → Household).

### Widget / Live Activity

- `FormulaHelperWidgets` target is an embedded `app-extension`. Shares `FormulaActivityAttributes.swift` + the cached `AppStateResponse` via App Group.

## Known quirks

- Widget `CFBundleVersion` is hardcoded to `1` while the parent app uses `$(CURRENT_PROJECT_VERSION)`. Xcode emits a warning on archive; Apple accepts the build. Worth fixing eventually.
- SourceKit intermittently emits spurious "Cannot find type X in scope" and "No such module UIKit" diagnostics when files are edited in isolation — the build itself is clean. Safe to ignore those specific messages.
- `project.yml` is the source of truth. After any edit there, run `cd ios && xcodegen generate` before building.
