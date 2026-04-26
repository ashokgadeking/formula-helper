# iOS Component Inventory

SwiftUI views, grouped by role. All views use tokens from `DesignSystem.swift` (`Color.primaryBackground`, `Color.greenFill`, `Font.outfit(...)`, `appFont(...)`).

## Screens (top-level)

| View | File | Purpose |
|---|---|---|
| `ContentView` | `Views/ContentView.swift` | Root tab host; owns `StateViewModel` |
| `AuthView` | `Views/AuthView.swift` | Signed-out experience. Buttons: Sign In with Passkey, Create Account, Join with Invite, Recover with Apple ID. Dev-only: Dev Login bypass (gated on `IsDevStack == "YES"`). |
| `LogsView` | `Views/LogsView.swift` | Unified log list (feedings/diapers/naps), per-day navigation, edit + delete via swipe |
| `TrendsView` | `Views/TrendsView.swift` | Bar charts (feedings), vertical 24h timeline (diapers), optional weight overlay |
| `SettingsView` | `Views/SettingsView.swift` | Household, Timer, Presets, Account, About |
| `HouseholdDetailView` | `Views/SettingsView.swift` (same file) | Pushed from Settings. Members + Invite (owners only) + Danger Zone. |

## Supporting / inline components

| Component | File | Purpose |
|---|---|---|
| `SignUpFlowView` | `AuthView.swift` | Paged signup: name → household name → child details. Accepts optional invite token to skip household/child pages. |
| `InviteCodeSheet` | `AuthView.swift` | Invite code entry sheet used from both Auth (join flow) and Settings (redeem). |
| `InviteShareSheet` | `SettingsView.swift` | Displays newly-created invite code with explicit Copy-to-Clipboard button that writes only the token (not RTFD). |
| `SettingsRow` | `SettingsView.swift` | Standard icon + title + optional trailing text row used throughout Settings. |
| `TimerDetailView` | `SettingsView.swift` | Countdown duration setting. |

## Managers / services (non-View)

| Type | File | Responsibility |
|---|---|---|
| `AuthManager` | `Auth/AuthManager.swift` | Singleton `@MainActor ObservableObject`. Drives `AuthState`. Wraps `ASAuthorizationController` for SIWA + WebAuthn. |
| `APIClient` | `Networking/APIClient.swift` | Typed HTTP methods. Reads `APIBaseURL` from Info.plist. |
| `StateViewModel` | `Views/ContentView.swift` | Holds latest `AppStateResponse`; `refresh()` refetches. |
| `CacheManager` | `Cache/CacheManager.swift` | App Group UserDefaults cache of last state for widget + live activity. |
| `NotificationManager` | `Notifications/NotificationManager.swift` | Local notification scheduling for bottle expiry. |

## Design system tokens (`DesignSystem.swift`)

Colors (asset-catalog-backed):
- Background: `.primaryBackground`, `.secondaryBackground`, `.elevatedBackground`
- Label: `.primaryLabel`, `.secondaryLabel`, `.tertiaryLabel`
- Separator: `.opaqueSeparator`
- Accent/Action: `.greenFill`, `.greenBorder`

Fonts (Outfit variable, bundled in `Resources/Fonts/Outfit-Variable.ttf`):
- `.outfit(_ size: CGFloat, weight:)` — raw usage
- `.appFont(.body | .footnote | ...)` — semantic styles

## Conventions

- Any new screen: `NavigationStack` + `ZStack { Color.primaryBackground.ignoresSafeArea(); List { ... } .listStyle(.insetGrouped).scrollContentBackground(.hidden) }`. Use `.listRowBackground(Color.elevatedBackground)` on rows.
- Any new button: reuse `SettingsRow` if it fits; or use `Color.greenFill` + `Color.greenBorder` for primary actions.
- Destructive actions: `Button(role: .destructive)` with a `.confirmationDialog`. Swipe actions: `.swipeActions(edge: .trailing, allowsFullSwipe: false) { Button(role: .destructive) { ... } label: { Image(systemName: "trash.fill") } }`. Matches the existing LogsView delete pattern.
- No new `.md` files, no new planning docs — `TODO.md` is the single parked-items register.
- Never edit `FormulaHelper.xcodeproj` directly; edit `project.yml` and run `xcodegen generate`.
