---
name: testflight-release
description: Ship a new TestFlight build for AvantiLog Dev or AvantiLog Prod. Handles version bump, archive, export, upload, processing wait, and — critically — attaching the build to the internal beta group (the step ASC does not do automatically).
---

# testflight-release

End-to-end TestFlight release. Takes one argument: `dev` or `prod`.

## Constants (per env)

Always read these from `ios/project.yml` / `/tmp/ExportOptions.plist` where possible; the table below is the fallback.

| env  | configuration | bundle id                          | asc app id   | beta group id                            | export options              |
|------|---------------|------------------------------------|--------------|------------------------------------------|-----------------------------|
| dev  | DevRelease    | com.ashokteja.formulahelper.dev    | 6763331013   | 0a6ec3ce-e656-4ec9-985c-28ac54e55db4     | `/tmp/ExportOptions.plist`  |
| prod | Release       | com.ashokteja.formulahelper        | _look up_    | _look up_                                | `ios/build/ExportOptions.plist` (needs one) |

If prod values aren't known, stop and ask — don't guess. Prod uploads are not idempotent.

ASC API key: `V4A6S35VU5`, issuer `27f687d5-8112-4c07-8028-9eb390c30934`, private key at `~/.appstoreconnect/private_keys/AuthKey_V4A6S35VU5.p8`.

## Steps

1. **Confirm env.** If the user said "ship a build" without specifying, ask dev or prod — do not default. For prod, also ask for explicit confirmation because it's user-visible.

2. **Bump `CURRENT_PROJECT_VERSION`** in `ios/project.yml` by +1. Example: `"30"` → `"31"`. Note the new number; use it for logging.

3. **Regenerate + archive.** From `ios/`:
   ```
   xcodegen generate
   rm -rf build/AvantiLogDev.xcarchive build/export   # or FormulaHelper.xcarchive for prod
   xcodebuild -project FormulaHelper.xcodeproj -scheme FormulaHelper \
     -configuration <DevRelease|Release> -destination generic/platform=iOS \
     archive -archivePath build/<ArchiveName>.xcarchive
   ```
   Abort if not `** ARCHIVE SUCCEEDED **`.

4. **Verify version in archive.** Sanity check:
   ```
   defaults read build/<ArchiveName>.xcarchive/Products/Applications/FormulaHelper.app/Info CFBundleVersion
   ```
   Must equal the new number. If it shows `1`, the Info.plist is not substituting `$(CURRENT_PROJECT_VERSION)` — fix project.yml before continuing.

5. **Export.**
   ```
   xcodebuild -exportArchive -archivePath build/<ArchiveName>.xcarchive \
     -exportPath build/export -exportOptionsPlist <ExportOptionsPath>
   ```

6. **Upload.**
   ```
   xcrun altool --upload-app -f build/export/FormulaHelper.ipa -t ios \
     --apiKey V4A6S35VU5 --apiIssuer 27f687d5-8112-4c07-8028-9eb390c30934
   ```
   Grab the `Delivery UUID` — that's the build id for the next steps.

7. **Wait for processing.** Poll ASC `/v1/builds?filter[app]=<APP_ID>&sort=-uploadedDate&limit=1` until `attributes.processingState == "VALID"`. Typically 2–5 min. Use `/tmp/asc_build_status.py` if present; otherwise inline a small Python+`jwt` script.

8. **Attach to beta group.** This is the step ASC does NOT do automatically — skipping it means the build is VALID but invisible in the TestFlight app on device.
   ```
   POST /v1/betaGroups/<GROUP_ID>/relationships/builds
   Body: { "data": [{ "type": "builds", "id": "<BUILD_ID>" }] }
   ```
   Expect HTTP 204. If 409/already-attached, treat as success.

9. **Report.** Tell the user: env, new build number, build id, and that it should appear in the TestFlight app within ~1 min.

## Guardrails

- Never use `--amend` or force-push git as part of this flow.
- Never swap configurations (dev↔prod) mid-flow; if the user started with dev, finish with dev.
- If step 4 shows a stale version, stop — do not upload. A duplicated bundle version gets rejected by ASC and burns time.
- If altool fails with `ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE` on `cfBundleVersion`, the version bump didn't take. Go back to step 2.
