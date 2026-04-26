# Development Guide

## Prerequisites

- **Xcode 16** with iOS 18 SDK
- **macOS 15+** (tooling works on 14 but TestFlight flow was validated on 15/26)
- **xcodegen** (`brew install xcodegen`)
- **AWS CLI v2** with configured profiles `viper` (prod) and `javelin` (dev)
- **AWS SAM CLI** (`brew install aws-sam-cli`)
- **Python 3.12** with `pip` (for any local Lambda experimentation)

## iOS — local dev loop

1. Edit `ios/project.yml` or any source file.
2. From `ios/`:
   ```
   xcodegen generate
   ```
   (Only needed if you changed `project.yml`; editing source is fine without it.)
3. Open `FormulaHelper.xcodeproj` in Xcode, or use the `sim-reload` skill for a one-shot rebuild-and-reload on the booted simulator:
   ```
   /sim-reload
   ```
4. The Debug config uses the dev stack API automatically.

### Simulator caveat

SIWA does not work in the iOS simulator. For any auth-touching work, rebuild the DevRelease target and test on-device via the AvantiLog Dev TestFlight app (see `deployment-guide.md`).

## Lambda — local dev loop

There is no local Flask/sam-local loop wired in. Iterate via:

1. Edit `lambda/handler.py`.
2. `./deploy.sh dev` — this is the only sanctioned deploy path. It asserts the active AWS account matches the dev profile before running `sam deploy`, so you can't accidentally deploy dev code to prod.
3. Tail logs:
   ```
   aws --profile javelin logs tail /aws/lambda/<FunctionName> --follow
   ```
   The function name is output by `sam deploy` — or get it from `sam list stack-outputs` using `samconfig-dev.toml`.
4. Test through the iOS DevRelease build or via curl against the dev API Gateway URL.

## Conventions

### Versioning

- `ios/project.yml` holds `CURRENT_PROJECT_VERSION` and `MARKETING_VERSION`. `CURRENT_PROJECT_VERSION` bumps per TestFlight upload (ASC rejects duplicates). `MARKETING_VERSION` is the user-visible 1.0.0.
- Lambda has no versioning; deploys are from HEAD.

### Git hygiene

- Do not commit `*.p8` keys (they're in `.gitignore`-adjacent locations).
- Don't commit `ios/build/`.
- `./deploy.sh` is checked in and safe to edit.

### Code style

- Swift: standard SwiftUI conventions. Shared tokens live in `DesignSystem.swift`. Avoid hex colors in views.
- Python: standard library + boto3 + webauthn + pyjwt. No linter configured; keep the current handler style (snake_case, helper `_` prefix for private).
- Comments: don't write comments that restate what the code does. Comments should explain non-obvious invariants. Don't add PR-description-style comments in source.

### Testing

- No iOS test target is wired. Manual testing via TestFlight.
- The `tests/` directory belongs to the Pi Flask app and is **not** run for the iOS/Lambda scope.
- Full product test suite is in TODO.md (deferred until touch-screen parity no longer matters).

## Common tasks — quick reference

| Task | Command |
|---|---|
| Rebuild iOS project file | `cd ios && xcodegen generate` |
| Build Debug for simulator | `cd ios && xcodebuild -project FormulaHelper.xcodeproj -scheme FormulaHelper -configuration Debug -destination 'generic/platform=iOS Simulator' build` |
| Reload app on simulator | `/sim-reload` (skill) |
| Archive DevRelease | `cd ios && xcodebuild -project FormulaHelper.xcodeproj -scheme FormulaHelper -configuration DevRelease -destination generic/platform=iOS archive -archivePath build/AvantiLogDev.xcarchive` |
| Ship to TestFlight (dev) | `/testflight-release dev` |
| Ship to TestFlight (prod) | `/testflight-release prod` |
| Deploy backend (dev) | `./deploy.sh dev` |
| Deploy backend (prod) | `./deploy.sh prod` |
| Lambda log tail (dev) | `aws --profile javelin logs tail /aws/lambda/<FnName> --follow` |

## Durable rules worth repeating

1. Always deploy via `./deploy.sh`. Never raw `sam deploy`.
2. Don't commit AWS/ASC keys to git.
3. Don't hand-edit `FormulaHelper.xcodeproj`.
4. Bump `CURRENT_PROJECT_VERSION` on every TestFlight upload; ASC rejects duplicates.
5. SIWA-dependent testing happens on-device (DevRelease TestFlight), not in the simulator.
