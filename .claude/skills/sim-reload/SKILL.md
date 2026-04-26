---
name: sim-reload
description: Rebuild the iOS app (Debug) and reload it on the currently-booted simulator. Handles xcodegen, build, uninstall, install, terminate, launch in one command.
---

# sim-reload

Reload the iOS Debug build onto the currently-booted simulator end-to-end. Use whenever the user asks to reinstall the app, reload the sim, or verify a change visually.

## Steps

1. **Find the booted simulator.** Run:
   ```
   xcrun simctl list devices booted
   ```
   Parse out the first `(Booted)` device UUID. If none is booted, tell the user to boot a simulator and stop — do not pick one arbitrarily.

2. **Regenerate the project.** From `ios/`:
   ```
   xcodegen generate
   ```

3. **Build Debug for that simulator.** From `ios/`:
   ```
   xcodebuild -project FormulaHelper.xcodeproj -scheme FormulaHelper -configuration Debug \
     -destination 'platform=iOS Simulator,id=<UUID>' build
   ```
   Tail the last ~5 lines. If it's not `** BUILD SUCCEEDED **`, stop and surface the errors.

4. **Reinstall + relaunch.** The built app is at:
   ```
   ~/Library/Developer/Xcode/DerivedData/FormulaHelper-buapsqbceiplqlafejzjmutrjxdx/Build/Products/Debug-iphonesimulator/FormulaHelper.app
   ```
   (If DerivedData path doesn't match, fall back to `xcodebuild -showBuildSettings` → `BUILT_PRODUCTS_DIR`.)

   Run in one shell:
   ```
   xcrun simctl uninstall <UUID> com.ashokteja.formulahelper 2>/dev/null
   xcrun simctl install <UUID> "$APP"
   xcrun simctl terminate <UUID> com.ashokteja.formulahelper 2>/dev/null
   xcrun simctl launch <UUID> com.ashokteja.formulahelper
   ```

5. **Confirm.** Report booted sim name, new PID, and that the app is live.

## Notes

- Bundle ID is always `com.ashokteja.formulahelper` for Debug (dev bundle `com.ashokteja.formulahelper.dev` is only used for DevRelease TestFlight builds, not simulator).
- Ignore SourceKit `Cannot find type` diagnostics that appear during Edit — they're a stale index; only trust xcodebuild's exit.
- If xcodegen says no project spec found, you're in the wrong cwd — it must run from `ios/`.
