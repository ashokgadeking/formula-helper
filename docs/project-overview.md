# Project Overview

## What it is

**AvantiLog** (internal name: Formula Helper) is a household-shared baby logging app for feedings, diapers, naps, and weight trends. It ships as a native iOS app backed by a serverless AWS API with passkey-based authentication and multi-household data scoping.

The product began as a personal Raspberry Pi kiosk and is being migrated to public availability as an iOS app. The Pi codebase still exists in this repo but is personal-only and is **excluded** from this documentation set (see `public_rollout_plan.md` for context).

## Why it exists

- Newborn tracking at 3am needs to be one-handed and instant. Forms and menus lose.
- Both parents must see the same state instantly on their own devices — shared-phone workflows fail when one parent is holding a baby.
- Data must survive device loss. Passkeys + SIWA recovery cover "I got a new phone" without a password reset flow.

## What's shipping

- Passkey login (WebAuthn), SIWA as recovery-only identity
- Household model with roles: `owner`, `admin`, `member`. Multi-household per user, active-household switching.
- Invite-token signup flow for adding members to an existing household
- Feeding logs (ml, leftover, date, created_by), diaper logs (pee/poo), nap logs (duration), manual weight logs
- Countdown timer on the current bottle with expiry notification
- Trends views (formula daily totals; diaper 24h timeline; optional correlation overlays)
- Settings screen with household detail (members list, invite, leave/delete under "Danger Zone")

## Repository layout (documented parts only)

```
formula-helper/
├── ios/                                 # Swift/SwiftUI iOS app
│   ├── FormulaHelper/                   #   sources
│   ├── FormulaHelperWidgets/            #   widget + live activity extension
│   ├── project.yml                      #   xcodegen spec (source of truth)
│   └── SETUP.md / DESIGN_OVERHAUL.md
├── lambda/
│   ├── handler.py                       # single Lambda (all routes)
│   └── requirements.txt                 # webauthn, pyjwt
├── template.yaml                        # SAM — prod stack
├── template-dev.yaml                    # SAM — dev stack
├── deploy.sh                            # scripted `sam deploy` gate
├── samconfig-dev.toml / samconfig-prod.toml
└── docs/                                # this BMAD-generated documentation
```

## Tech stack summary

| Category | Technology | Notes |
|---|---|---|
| iOS language | Swift 6.0 | Main actor isolation warnings present in `AuthManager.swift` window-lookup |
| iOS UI | SwiftUI | List/NavigationStack + custom DesignSystem.swift |
| iOS fonts | Outfit (variable) | Bundled in `Resources/Fonts` |
| iOS auth | WebAuthn platform authenticator (passkey) + ASAuthorizationAppleIDProvider | Passkey for login, SIWA only on first signup + recovery |
| iOS project gen | xcodegen | `ios/project.yml` is the source of truth — don't edit the `.xcodeproj` by hand |
| iOS distribution | TestFlight (AvantiLog + AvantiLog Dev apps) | See deployment guide |
| Backend runtime | Python 3.12 on AWS Lambda | Single handler, regex-dispatched routes |
| HTTP front | API Gateway HTTP API → Lambda integration | |
| Data store | DynamoDB, single table `FormulaHelper` (PK/SK) | See `data-models-lambda.md` |
| CDN | CloudFront (prod) — serves `/api/*` and static web | Dev hits API Gateway directly |
| Auth lib | `webauthn` 2.x (py-webauthn) + `pyjwt[crypto]` for SIWA | |
| IaC | AWS SAM | Two stacks: dev + prod |
| Deploy tool | `./deploy.sh dev|prod` | Asserts AWS account ID before `sam deploy` |

## Durable rules (from user memory)

- Always deploy via `./deploy.sh dev|prod` — never raw `sam deploy`.
- AWS profiles: `viper` = prod, `javelin` = dev.
- Don't add Pi features to AvantiLog product scope.
- Simulator SIWA is broken — dev on-device testing goes through the TestFlight Dev app.
- Parked: Home Screen widget, push notifications for household join/leave.
