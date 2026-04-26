# Deployment Guide

## Two environments, two pipelines

| Env | AWS profile | SAM template | Samconfig | ASC app | TestFlight group | Bundle id | Display name |
|---|---|---|---|---|---|---|---|
| **dev** | `javelin` | `template-dev.yaml` | `samconfig-dev.toml` | AvantiLog Dev (`6763331013`) | id `0a6ec3ce-e656-4ec9-985c-28ac54e55db4` | `com.ashokteja.formulahelper.dev` | Formula Helper Dev |
| **prod** | `viper` | `template.yaml` | `samconfig-prod.toml` | AvantiLog (_look up id_) | _look up_ | `com.ashokteja.formulahelper` | Formula Helper |

ASC API key (shared): id `V4A6S35VU5`, issuer `27f687d5-8112-4c07-8028-9eb390c30934`, private key at `~/.appstoreconnect/private_keys/AuthKey_V4A6S35VU5.p8`.

Apple Team id: `TV6FL9FHCE`.

## Backend deploy

Always via `deploy.sh`, which asserts the active AWS account before running `sam deploy`:

```
./deploy.sh dev
./deploy.sh prod
```

The script does not skip hooks, does not use `--no-confirm-changeset` for prod. If prod deploy asks you to confirm a changeset, read it — CloudFront distributions are slow to redo if you break them.

## iOS deploy (TestFlight)

The canonical path is the `testflight-release` skill:

```
/testflight-release dev
/testflight-release prod
```

It handles: version bump (`CURRENT_PROJECT_VERSION` + 1), xcodegen regen, archive, export, altool upload, ASC polling until `processingState == VALID`, and the beta-group attach (the step ASC does not do automatically).

### Manual path (if the skill is unavailable)

Dev:

```bash
cd ios
# 1. Bump ios/project.yml: CURRENT_PROJECT_VERSION
# 2. Regenerate + archive
xcodegen generate
rm -rf build/AvantiLogDev.xcarchive build/export
xcodebuild -project FormulaHelper.xcodeproj -scheme FormulaHelper \
  -configuration DevRelease -destination generic/platform=iOS \
  archive -archivePath build/AvantiLogDev.xcarchive
# 3. Confirm version
defaults read build/AvantiLogDev.xcarchive/Products/Applications/FormulaHelper.app/Info CFBundleVersion
# 4. Export
xcodebuild -exportArchive -archivePath build/AvantiLogDev.xcarchive \
  -exportPath build/export -exportOptionsPlist /tmp/ExportOptions.plist
# 5. Upload
xcrun altool --upload-app -f build/export/FormulaHelper.ipa -t ios \
  --apiKey V4A6S35VU5 --apiIssuer 27f687d5-8112-4c07-8028-9eb390c30934
# 6. Poll ASC until processingState == VALID
python3 /tmp/asc_build_status.py
# 7. Attach to dev beta group via ASC API
#    POST /v1/betaGroups/0a6ec3ce-e656-4ec9-985c-28ac54e55db4/relationships/builds
#    Body: {"data":[{"type":"builds","id":"<build id>"}]}  — expect HTTP 204
```

Prod uses `-configuration Release`, `build/FormulaHelper.xcarchive`, `ios/build/ExportOptions.plist`, and the prod beta group id (look up before shipping).

### Guardrails

- **Never swap configs mid-flow.** If you started dev, finish dev.
- **Duplicated `CFBundleVersion` gets rejected by ASC.** If altool errors with `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE`, re-bump and retry.
- **Prod uploads are not idempotent.** Don't ship prod without confirming.
- **The beta group attach is not optional.** Skipping it leaves the build VALID but invisible in the TestFlight app on devices.

## What deploys don't change

- DynamoDB tables are never recreated. The tables `FormulaHelper` (prod) and `FormulaHelper-dev` (dev) are `Retain`-attached implicitly; if you need to change schema, go in via the AWS Console, never through stack recreation.
- `NTFY_TOPIC`, `VAPID_*`, and `PI_API_KEY` env vars are legacy Pi integration bits. Leave them; removing means untangling the Pi app's independent usage.

## Rollback

- **Backend:** redeploy previous HEAD via `git checkout <sha> && ./deploy.sh <env>`. Lambda has zero migrations so rollback is safe if the data shape hasn't changed.
- **iOS:** TestFlight builds stay available in the app until explicitly expired in ASC. "Rolling back" = telling testers to install the previous build from the TestFlight app. For App Store submissions, you'd need to submit the previous build number for review.

## Observability

- CloudWatch Logs group `/aws/lambda/<FunctionName>` has all stdout/stderr from handlers plus the stack traces from `dispatch()`'s catch-all.
- No structured logging library. `print(...)` is what you get. Worth switching to `logging` before scaling the user count.
- No dashboards or alarms wired.
