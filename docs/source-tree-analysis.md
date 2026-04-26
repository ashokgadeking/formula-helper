# Source Tree — Documented Scope

```
formula-helper/
│
├── ios/                                        # iOS app (Swift / SwiftUI)
│   ├── project.yml                             #   xcodegen spec — SOURCE OF TRUTH
│   ├── FormulaHelper.xcodeproj/                #   generated; do not edit by hand
│   ├── ExportOptions.plist                     #   prod export options (dev uses /tmp/ExportOptions.plist)
│   ├── SETUP.md / DESIGN_OVERHAUL.md
│   ├── AuthKey_*.p8                            #   ASC API keys (don't commit beyond this repo)
│   ├── apple-app-site-association              #   local copy of AASA for dev
│   ├── build/                                  #   xcodebuild output (archives, ipa, exports)
│   │
│   ├── FormulaHelper/                          # ── main app target ─────────────────────
│   │   ├── FormulaHelperApp.swift              #   @main entry
│   │   ├── DesignSystem.swift                  #   color + font tokens
│   │   ├── Info.plist                          #   CFBundleVersion = $(CURRENT_PROJECT_VERSION)
│   │   ├── FormulaHelper.Dev.entitlements      #   Debug + DevRelease
│   │   ├── FormulaHelper.Prod.entitlements     #   Release
│   │   ├── Auth/AuthManager.swift              #   SIWA + passkey orchestration
│   │   ├── Networking/APIClient.swift          #   typed HTTP client
│   │   ├── Models/AppState.swift               #   Codable shapes for wire format
│   │   ├── Cache/CacheManager.swift            #   App Group UserDefaults snapshot
│   │   ├── Notifications/NotificationManager.swift
│   │   ├── LiveActivity/
│   │   │   └── FormulaActivityAttributes.swift #   shared with widget target
│   │   ├── Views/
│   │   │   ├── ContentView.swift               #   tab host + StateViewModel
│   │   │   ├── AuthView.swift                  #   signed-out experience
│   │   │   ├── LogsView.swift                  #   unified feeding/diaper/nap log
│   │   │   ├── TrendsView.swift                #   charts
│   │   │   └── SettingsView.swift              #   + HouseholdDetailView + InviteShareSheet
│   │   └── Resources/
│   │       ├── Assets.xcassets/                #   AppIcon, AppIcon-Dev, color sets
│   │       └── Fonts/Outfit-Variable.ttf
│   │
│   └── FormulaHelperWidgets/                   # ── widget / live activity extension ────
│       └── (Widget sources — parked per TODO)
│
├── lambda/                                     # ── AWS Lambda backend ─────────────────
│   ├── handler.py                              #   all routes, all data ops (1438 lines)
│   └── requirements.txt                        #   webauthn, pyjwt[crypto]
│
├── template.yaml                               # SAM — prod stack
├── template-dev.yaml                           # SAM — dev stack
├── samconfig-prod.toml                         # sam deploy config (stack + region pinning)
├── samconfig-dev.toml
├── deploy.sh                                   # GATE: asserts AWS account, then sam deploy
│
├── docs/                                       # BMAD-generated documentation (this folder)
│
├── TODO.md                                     # open work + parked items
├── README.md                                   # original product pitch (Pi-era architecture)
├── ios-prd.md                                  # original iOS PRD
├── public_rollout_plan.md                      # plan for public App Store availability
└── _bmad/                                      # BMAD module config (keep out of builds)
```

## Pi-scoped files (excluded from this documentation)

These still exist in the repo but are personal-only and should not be treated as product scope:

- `formula_app.py`, `formula_web.py` — Pi Flask kiosk
- `scale.py`, `api_client.py`, `migrate.py`, `lambda_backup.py`
- `web/`, `templates/`, `tests/`
- `setup_*.sh`, `wifi_watchdog.sh`
- `baby_files/`, `exports/`, `baby.png`, `bottle_vector.png`

If you find yourself reading any of these in response to a product question, stop — you're likely off-scope.

## Entry points

| Concern | Entry |
|---|---|
| iOS runtime | `ios/FormulaHelper/FormulaHelperApp.swift` → `ContentView` |
| iOS project definition | `ios/project.yml` |
| Backend request | `lambda/handler.py::lambda_handler` → regex router |
| Backend deploy | `./deploy.sh dev|prod` |
| TestFlight build | `testflight-release` skill, or commands in `deployment-guide.md` |
