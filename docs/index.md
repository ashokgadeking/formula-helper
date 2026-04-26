# Formula Helper — Project Documentation Index

**Generated:** 2026-04-23 (BMAD document-project, deep scan)
**Scope:** iOS app + AWS Lambda backend. The Raspberry Pi Flask kiosk (`formula_app.py`, `web/`, `templates/`, `tests/`, `setup_*.sh`, `scale.py`) is personal-only and deliberately excluded from this documentation set.

## Project Overview

- **Type:** monorepo, multi-part
- **Shipping product:** AvantiLog (App Store name; internal name "Formula Helper")
- **Primary language(s):** Swift (iOS), Python (Lambda)
- **Architecture:** iOS client ↔ AWS serverless backend (CloudFront → HTTP API Gateway → single Lambda → DynamoDB). Passkey-first auth, SIWA used as recovery identity only.

## Parts

| Part | Path | Type | Stack |
|---|---|---|---|
| `ios` | `ios/` | Mobile (SwiftUI) | Swift 6.0, SwiftUI, iOS 18+, WebAuthn / passkeys, SIWA, xcodegen |
| `lambda` | `lambda/` + `template.yaml` / `template-dev.yaml` | Serverless backend | Python 3.12, AWS Lambda, HTTP API Gateway, DynamoDB, CloudFront, SAM |

Integration: iOS hits `https://d20oyc88hlibbe.cloudfront.net/api/*` (prod) or the API Gateway URL directly (dev), all routed through the same Lambda handler.

## Generated Documentation

- [Project Overview](./project-overview.md)
- [Architecture — iOS](./architecture-ios.md)
- [Architecture — Lambda](./architecture-lambda.md)
- [Integration Architecture](./integration-architecture.md)
- [Source Tree Analysis](./source-tree-analysis.md)
- [API Contracts](./api-contracts-lambda.md)
- [Data Models (DynamoDB)](./data-models-lambda.md)
- [iOS Component Inventory](./component-inventory-ios.md)
- [Development Guide](./development-guide.md)
- [Deployment Guide](./deployment-guide.md)
- [Project Parts (machine-readable)](./project-parts.json)

## Existing Documentation (pre-BMAD)

- [README.md](../README.md) — product pitch, feature list, Pi-era architecture
- [ios-prd.md](../ios-prd.md) — original iOS PRD
- [public_rollout_plan.md](../public_rollout_plan.md) — plan for moving from personal Pi to App Store
- [TODO.md](../TODO.md) — current open work + parked items
- [ios/SETUP.md](../ios/SETUP.md) — iOS dev setup
- [ios/DESIGN_OVERHAUL.md](../ios/DESIGN_OVERHAUL.md) — iOS design principles

## Quick Reference

- **App Store apps:** `AvantiLog` (prod, `com.ashokteja.formulahelper`, ASC app `_look up_`) and `AvantiLog Dev` (dev, `com.ashokteja.formulahelper.dev`, ASC app `6763331013`)
- **Prod host:** `d20oyc88hlibbe.cloudfront.net` (also RP ID and RP origin)
- **Dev host:** `3lgqmzurih.execute-api.us-east-1.amazonaws.com`
- **AWS profiles:** `viper` = prod, `javelin` = dev
- **Apple team:** `TV6FL9FHCE`
- **Deploy:** `./deploy.sh dev` or `./deploy.sh prod` (asserts account ID before `sam deploy`)
- **TestFlight:** use the `testflight-release` skill or the commands in `deployment-guide.md`

## Getting Started for Future Agents

1. Read `project-overview.md` for product context.
2. For **backend work**: start with `api-contracts-lambda.md` + `data-models-lambda.md` + `architecture-lambda.md`.
3. For **iOS work**: start with `architecture-ios.md` + `component-inventory-ios.md`.
4. For **anything crossing the wire**: include `integration-architecture.md`.
5. Deploys always go through `./deploy.sh` (durable user rule — do not bypass).
