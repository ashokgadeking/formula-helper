# Epic 4: Bookoo scale auto-log

**Branch:** `dev_bookoo` (off main, public-rollout-track sibling to `dev_auth` / `dev_siri`).
**Status:** scoped, story 4-1 ready-for-dev.

## Goal

When the user mixes a bottle on a Bookoo Mini Scale, the iOS app should detect the prep, derive the bottle size from the formula grams added, and auto-log the bottle to the server without any phone interaction. Specifically: a hands-free overnight workflow where the user's phone may be in another room and they only have one free hand on the baby.

The success state is "open lock screen at 3am → notification says 'Logged 120 ml bottle · timer started'".

## Why now

The dashboard's quick-tap buttons and the new Siri intent both still require touching or speaking. At 3am with one hand on a baby and the other actively mixing formula, neither is realistic. The scale is already on the workflow path — it's how the user measures the exact formula grams added. BLE-bridging the scale to the iOS log endpoint removes the last manual step.

## User's actual workflow (verified 2026-05-31)

1. Dispense water (e.g. 120 ml) into an empty bottle.
2. Put bottle on scale, power scale on.
3. Scale auto-tares to 0 g with bottle + water on it.
4. Add formula powder: 8.3 g per 60 ml = 16.6 g for 120 ml. Sometimes off by ±0.2 g.
5. Lift bottle, start feeding.
6. Scale eventually auto-shuts off after 5 min.

The observable BLE signal is:
- weight tares to 0 → climbs to stable positive (~16.6 g) → drops sharply to negative when bottle is lifted.

ml is derivable as `round(peak_g × 60 / powder_per_60 / 10) × 10` — rounds to the nearest 10 ml so the off-by-0.2 g case still resolves to the intended size. `powder_per_60` is already in `AppSettings` from server state (default 8.3).

## Scope decisions (locked from conversation)

| | Decision |
|---|---|
| **Hardware** | Bookoo Mini Scale only (one BLE service UUID `0FFE`, weight char `FF11`, command char `FF12`). Greater Goods baby scale (the weight-log scale) is a separate scope — not this epic. |
| **Number of scales** | Support N≥2 paired scales (user has one upstairs + one downstairs). Whichever powers on first is the active one. Each session pins to the peripheral that fired it (for the post-log beep). |
| **Auto-log mode** | Fully silent overnight (Option A from conversation). No foreground confirmation. Local notification fires on success. Override path = user opens app and manually edits/deletes via Logs view if needed. |
| **Background BLE** | Required. Enables `bluetooth-central` background mode + state restoration so iOS relaunches the app on scale power-on even when force-quit. |
| **Server calls on success** | Both `APIClient.logEntry(ml:)` AND `APIClient.startFeeding(ml:)`. Latter kicks the 65-min expiry timer that the dashboard / widget / Siri all already consume. |
| **Beep / confirmation** | Send `CMD_START_TIMER` (0x04) back to the scale on successful log. Audible scale-side cue that the iOS state is in sync. Doesn't tare (bottle's already off, don't want to disturb zero). |
| **Pairing** | First-time pairing is a foreground flow in Settings. Bookoo's own iOS app pairing doesn't transfer — user accepts re-pairing both scales once inside AvantiLog. |
| **ml derivation** | `round(peak_g × 60 / powder_per_60 / 10) × 10`. Floor at 30 ml, ceiling at 300 ml. Out-of-range readings are discarded (state machine resets). |
| **Powder ratio source** | `AppSettings.powder_per_60` from cached state. If state is unavailable (cold launch), fall back to 8.3. |

## Out of scope this epic

- Greater Goods baby weight scale.
- iOS scale-side calibration / firmware updates.
- Live-weight display on the dashboard / widget during a prep (would require foreground BLE, separate story if desired later).
- Customer-tunable detection thresholds (stable window, lift-drop threshold) — hardcode v1, tune from real usage.
- Apple Watch surface (separate epic).

## Story list

- **4-1: Bookoo auto-log foundation** — CoreBluetooth manager, packet parser, state machine, multi-scale pairing UI, background BLE entitlement, end-to-end log + beep + notification.
- **4-2 (future, not in this epic):** Live weight on dashboard while foregrounded, manual log-with-edit confirmation panel for daytime use.
- **4-3 (future):** Settings switch to disable auto-log per scale (e.g. user wants the downstairs scale paired but only to track weight, not auto-log).
