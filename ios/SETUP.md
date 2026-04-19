# iOS Phase 1 Setup

## Step 1 — Create Xcode project

1. **Xcode → File → New → Project → iOS App**
   - Product Name: `FormulaHelper`
   - Bundle Identifier: `com.YOURNAME.formulahelper` (pick something, note it down)
   - Language: Swift, Interface: SwiftUI
   - Minimum Deployments: iOS 18.0
   - Save into: `formula-helper/ios/`

2. **Signing & Capabilities tab** for the `FormulaHelper` target:
   - Add **Associated Domains**: `webcredentials:d20oyc88hlibbe.cloudfront.net`
   - Add **App Groups**: `group.com.YOURNAME.formulahelper`

3. Note your **Team ID** from the Signing section (10-char string like `ABC123DEF4`)

## Step 2 — Add source files

Drag each file from `ios/FormulaHelper/` into the Xcode project, checking
"Copy items if needed" and "Add to target: FormulaHelper".

File groups to add:
- `FormulaHelperApp.swift` (replaces the generated one — delete the generated version first)
- `Models/AppState.swift`
- `Networking/APIClient.swift`
- `Auth/AuthManager.swift`
- `Cache/CacheManager.swift`
- `Views/ContentView.swift`
- `Views/AuthView.swift`

Delete the auto-generated `ContentView.swift` Xcode created — it's replaced by ours.

## Step 3 — Update placeholders

In `CacheManager.swift`, replace:
```swift
private let groupID = "group.com.YOURNAME.formulahelper"
```
with your actual App Group ID (e.g. `group.com.ashok.formulahelper`).

## Step 4 — Deploy the AASA file

This is required for passkeys to work. Without it, iOS will refuse to use the passkey
for `d20oyc88hlibbe.cloudfront.net`.

1. Edit `ios/apple-app-site-association` — replace `TEAMID` and `com.YOURNAME.formulahelper`
   with your actual Team ID and bundle ID.

2. Upload to the S3 bucket **without** a file extension, at the path
   `.well-known/apple-app-site-association`, with content-type `application/json`:

```bash
aws s3 cp ios/apple-app-site-association \
  s3://formula-helper-web/.well-known/apple-app-site-association \
  --content-type application/json \
  --profile viper
```

3. CloudFront may need a behavior to forward `/.well-known/apple-app-site-association`
   without stripping headers. If the CloudFront distribution is just an S3 origin,
   the file will be accessible at:
   `https://d20oyc88hlibbe.cloudfront.net/.well-known/apple-app-site-association`

   Verify by opening that URL in a browser — it should return your JSON.

## Step 5 — Build & run

Connect your iPhone (or use Simulator for initial testing — passkeys work in Simulator
via iCloud Keychain). Press Run.

On first launch you'll see the auth screen. Tap "Register Passkey" with your name `ashok`.

---

## Known limitations / Phase 2 items

- Settings screen (gear icon) is wired up as a no-op button stub — implemented in Phase 2
- Next feeding estimate not shown yet — Phase 2
- Reset timer accessible only via web app for now — Phase 2
- Weight logging — Phase 2
