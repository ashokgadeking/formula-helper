# Epic 3: Siri logging via App Intents

**Branch:** `dev_siri` (off main, public-rollout track sibling to `dev_auth`).
**Status:** scoped, stories 3-1/3-2/3-3 ready-for-dev.

## Goal

Let users log a bottle, diaper, or nap by talking to Siri without opening the app:

- "Hey Siri, log a 100ml bottle"
- "Hey Siri, log a pee diaper" (or "log a poo diaper")
- "Hey Siri, log a nap" (optional duration)

Each command writes to the user's currently-active household via the existing log endpoints.

## Why now

The dashboard's quick-tap buttons are great when you have a free hand. At 3am with one hand on a baby and one on a bottle, voice is faster. Siri is the lowest-friction input on iOS and pairs well with the watch / HomePod surfaces we'll likely add later.

## Scope decisions (locked from conversation)

| | Decision |
|---|---|
| **API surface** | App Intents (iOS 16+). Rules out the deprecated SiriKit Custom Intents path. |
| **Commands in v1** | Three log intents only: bottle, diaper, nap. No read-only queries ("how much eaten today?", "next bottle?") in this epic. |
| **Auth handling** | Fail gracefully. If the session cookie is missing/expired, intent returns a dialog: "Open Formula Helper to sign in first." No queueing. |
| **Active household** | Silently use whatever the session's `active_hh` is. No prompt-for-household flow. Multi-household power users can switch in Settings before invoking Siri. |
| **Confirmation** | None for log commands — the spoken phrase is the confirmation. Reset-timer / delete intents (out of scope this epic) would warrant confirmation when added. |
| **Donations** | Use `AppShortcutsProvider` for the three intents so Siri/Shortcuts auto-suggest. No predictive `donate()` calls per-action in v1; revisit if Siri suggestions feel weak. |
| **Background execution** | In-app intents — `perform()` runs in the app's process. App may briefly foreground but the intent itself responds without leaving Siri's UI. No separate Intents Extension target. Simpler and sufficient for these three commands. |

## Stories

| ID | Title | Scope |
|---|---|---|
| `3-1-log-bottle-intent` | Log a bottle via Siri | First intent, carries the foundation: `AppShortcutsProvider`, common error/auth helper, project.yml wiring, the bottle intent itself, donation phrases. |
| `3-2-log-diaper-intent` | Log a diaper via Siri | Pee/poo parameter. Reuses the foundation from 3-1. |
| `3-3-log-nap-intent` | Log a nap via Siri | Optional duration parameter. Reuses the foundation from 3-1. |

Ship sequence: 3-1 first (foundation + first working intent for end-to-end verification on device), then 3-2 and 3-3 can ship in parallel or in either order.

## Out of scope (deferred)

- **Read-only query intents** ("how much has the baby eaten today?", "when's the next bottle?"). Real value but each is its own response surface (`IntentResultDialog` + structured data); separate epic.
- **Watch app shortcut surfaces.** App Intents will appear on watch automatically once the project has a watch target — we don't have one yet.
- **Apple Intelligence Foundation Model integration.** App Intents discovered via Apple Intelligence is iOS 18.1+ and largely automatic once the intents exist. Worth doing nothing extra; verify after shipping.
- **Sign-in via Siri.** Triggering SIWA from a voice intent is an awkward flow; we just bounce the user to the app.
- **Logging entries to a non-active household.** Single-household users have no problem. Multi-household users can switch first. If real users complain, we add an `IntentParameter` for household; not before.
- **Custom Apple Watch complication driving intents.** Watch app altogether is parked.

## Verification path

Each story's manual matrix runs on-device (Siri doesn't work in the iOS Simulator with full fidelity). All three together are verified on a Dev TestFlight build before merging to main.
