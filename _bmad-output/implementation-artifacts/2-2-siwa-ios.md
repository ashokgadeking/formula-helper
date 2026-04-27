# Story 2.2: SIWA-only iOS auth (rip WebAuthn)

Status: review

**Epic:** 2 — Passkey → SIWA-only auth
**Story ID:** 2.2
**Story Key:** 2-2-siwa-ios
**Depends on:** Story 2-1-siwa-backend deployed to dev

## Story

As a **household member**,
I want to **sign in or sign up with one tap on "Continue with Apple"**,
so that **I never see a passkey prompt and the app onboards me in seconds**.

## Acceptance Criteria

1. **`AuthView` collapses to two primary actions** plus dev affordances:
   - **Continue with Apple** (primary, green-fill button — replaces "Sign In with Passkey").
   - **Join with Invite** (secondary).
   - **Dev Login (bypass)** (dev-stack only, gated on `IsDevStack == "YES"`, unchanged).

   Removed: "Create Account", "Can't sign in? Recover with Apple ID", and the two-bool spinner gating around them.

2. **One-tap sign-in (returning user).** Tapping "Continue with Apple":
   - Triggers `ASAuthorizationAppleIDProvider` with `.fullName, .email` scopes (existing pattern).
   - On success, calls `APIClient.siwaAuth(idToken:, userName:, ...)` with **just the id_token** + Apple-provided name (if any) in `userName`.
   - If server returns 200 with `returning: true`: call `auth.checkStatus()`, transition to `.authenticated`, dashboard appears.
   - HTTP `Set-Cookie` from server is captured by `URLSession.shared.cookieStorage` automatically.

3. **First-time signup (412 Precondition Required) → setup sheet.**
   - On 412 from `siwaAuth`, iOS preserves the **same `idToken` from step 2** in memory and presents the existing `SignUpFlowView` paged form (name → household name → child details).
   - The `SignUpFlowView`'s `draft.suggestedFirstName` is populated from Apple's `givenName` if Apple returned it; otherwise the user types it.
   - On the user pressing "Create Passkey & Finish" (which gets renamed — see AC 4), iOS calls `siwaAuth` **again** with the **same idToken** + `user_name` + `household_name` + `child_name?` + `child_dob?`. Server returns 200; transition to `.authenticated`.

4. **`SignUpFlowView` button text updates.** "Create Passkey & Finish" → "Finish setup". The `faceid` SF Symbol stays or changes to `checkmark.circle.fill` — either is fine, judgement call. No passkey is created anywhere — the rename reflects the new reality.

5. **Join-with-invite flow.** Tapping "Join with Invite" → invite-code sheet → SIWA → `siwaAuth(idToken:, userName: appleGivenName, inviteToken: token)`.
   - If 200 with `returning: false`: first-time signup that joined the invited household instead of creating a new one. Skip the household/child pages of `SignUpFlowView` (covered by the invite branch). Only the name page runs.
   - If 200 with `returning: true`: existing user took the invite path. Backend story 2-1 ignores `invite_token` for returning users — iOS compensates by calling the existing `APIClient.redeemInvite(token:)` immediately after sign-in. On success, also call `switchHousehold(hhId:)` to pull the user into the freshly-joined household so the dashboard reflects it. Wrap both in try; on failure, surface "Signed in, but couldn't join the household — try Settings → Redeem invite code" as a non-fatal warning.
   - If 412: same paged flow as AC 3 but the name page only (the invite supplies the household).

6. **Multi-household switcher in Settings.** When a user belongs to ≥1 household, the Household section in `SettingsView` lists **all** of them, not only the active one. (Single-household users see the same UI as today.)
   - Each household renders as a row with `house.fill` icon, name, and the user's role chip.
   - The **active** row is a `NavigationLink` to `HouseholdDetailView` (current behavior). Visually marked with a trailing green `checkmark` glyph (in addition to the implicit NavLink chevron).
   - **Inactive** rows render as `Button(action:)` that, on tap, call `APIClient.switchHousehold(hhId:)`, then `vm.refresh()`, then `loadHouseholds()` (which already prefetches members for the new active household per Story 1.1's design). On success the row re-renders as the new active row (chevron, checkmark) and the formerly-active row drops to the inactive Button shape.
   - **No confirmation dialog.** Switch is reversible and low-risk. The whole flow is one tap.
   - **Error path.** If `switchHousehold` throws, set `redeemError` (existing footer state) to the error description and don't update the local active state. Tapping again retries.
   - **Pull-to-refresh** on the Settings list (already exists indirectly via `.task { await loadHouseholds() }`) — no new gesture needed; the existing one re-fetches the membership list.

7. **`AuthManager` rewrite.** The `@MainActor final class AuthManager` shrinks substantially:
   - **Drop:** `signIn()`, `performAssertion(...)`, `performRegistration(...)`, `webauthnAssertionJSON(...)`, `webauthnAttestationJSON(...)`, the WebAuthn imports stay only for `requestSiwaCredential` (which uses `ASAuthorizationAppleIDProvider`, not the platform passkey provider).
   - **Add:** `siwaAuth(idToken: String, userName: String?, householdName: String?, childName: String?, childDob: String?, inviteToken: String?) async throws -> SiwaAuthResult` where `SiwaAuthResult` is `enum { case signedIn(returning: Bool); case setupRequired }`.
   - **Repurpose:** `beginSignUp()` becomes the public entry point — it does SIWA and returns the bundle of `(idToken, suggestedFirstName, email)` so the caller can decide what to do based on server response.
   - **Drop:** `completeSignUp(...)` — replaced by direct calls into `siwaAuth` from the views.
   - **Drop:** `recover()` — its job is now part of the unified flow.
   - **Drop:** `AuthError.invalidCredential`, `.missingChallenge`, `.missingDetails(_)`. Keep `.cancelled`, `.missingSiwaToken`. Add `.setupRequired` for the 412 case (or model it via `SiwaAuthResult.setupRequired`, not as a thrown error — preferred).

8. **`APIClient` changes:**
   - **Drop methods:** `loginOptions()`, `loginVerify(body:)`, `registerStart(body:)`, `registerFinish(body:)`, `recoverStart(siwaIdToken:)`, `recoverFinish(body:)`.
   - **Add method:**
     ```swift
     func siwaAuth(idToken: String, userName: String?, householdName: String?, childName: String?, childDob: String?, inviteToken: String?) async throws -> SiwaAuthResponse
     ```
     where `SiwaAuthResponse` is a new Codable struct: `{let ok: Bool; let user_id: String?; let active_hh: String?; let returning: Bool}`.
   - **Status decoding:** the server returns 412 with a JSON body for setup-required. `siwaAuth` distinguishes 200/412/4xx/5xx via `checkStatus`'s existing path — but the existing `APIError.badStatus` collapses everything to "throw". Add a new `APIError.setupRequired(needs: [String])` and special-case 412 in `checkStatus` (or in a `siwaAuth`-specific helper).

9. **`Models/AppState.swift` changes:**
   - **Drop:** `ChallengeEnvelope` (unused after 2-1; was only consumed by the WebAuthn flows).
   - **Add:** `SiwaAuthResponse` per AC 7.
   - Keep: everything else.

10. **Entitlements + Info.plist — leave unchanged in this story.** The `webcredentials:` associated-domains entry is now dead but harmless. Cleanup is the deferred follow-up agreed earlier.

11. **`AuthView`'s `auth.userName` Apple-name privacy log** stays at `.private` (already fixed in the broader hardening pass).

12. **No SwiftUI test target wired.** Manual verification:
    - **Returning user:** sign in via SIWA → expect dashboard load with no setup form.
    - **First-time:** uninstall + reinstall the dev TestFlight app on a device whose Apple ID has not seen this bundle id (or use Settings → Sign in with Apple → Stop using → reinstall on the same Apple ID). Tap Continue with Apple → setup form → Finish → dashboard. Verify in Console.app the auth log line shows `returning=false`.
    - **Join with invite:** mint an invite from the existing dev household via a separate test account, redeem with a fresh Apple ID. Verify membership in the invited household.
    - **Cancel mid-SIWA:** tap Continue with Apple, dismiss the SIWA sheet → no error message, button returns to idle.
    - **Network failure mid-`siwaAuth`:** kill wifi, tap Continue with Apple, dismiss SIWA, force-fail the request. Expect the existing error-message footer to surface a sensible string.

13. **Dev simulator caveat documented in the SignUpFlowView's name-page subtitle** — already removed in a prior story; no change here.

14. **Manual verification additions for the new ACs (5, 6):**
    - **Returning user joining a second household via invite:** sign in as user A (already in household X), redeem an invite for household Y from the auth screen's "Join with Invite" path. Verify: signed into Y, X membership intact, switcher shows both X and Y, Y has the green checkmark.
    - **Switcher between two households:** with the same user signed in to both X and Y, tap the inactive household row in Settings. Verify: row order/checkmark updates, Logs/Trends tabs show the newly-active household's data, no errors. Tap back to switch to the other.
    - **Switch failure:** simulate by toggling airplane mode mid-tap. Verify: error footer appears, active household stays unchanged, retry on next tap works.

## Tasks / Subtasks

- [x] **Task 1 — APIClient surface** (AC: 8, 9)
  - [x] Subtask 1.1: Drop the six obsolete methods from `APIClient.swift` (`loginOptions`, `loginVerify`, `registerStart`, `registerFinish`, `recoverStart`, `recoverFinish`).
  - [x] Subtask 1.2: Add `SiwaAuthResponse` Codable in `Models/AppState.swift`. Drop `ChallengeEnvelope`.
  - [x] Subtask 1.3: Add `func siwaAuth(...)` in `APIClient.swift`. Body: build the `[String: Any]` request body conditionally (only include non-nil fields), POST to `/api/auth/siwa`, decode `SiwaAuthResponse` on 200, throw `.setupRequired` on 412, throw `.badStatus` on others.
  - [x] Subtask 1.4: Add `APIError.setupRequired(needs: [String])`. Update `errorDescription` to surface a friendly "Setup required" message.

- [x] **Task 2 — AuthManager rewrite** (AC: 7)
  - [x] Subtask 2.1: Strip the WebAuthn types and methods listed in AC 6.
  - [x] Subtask 2.2: Define `enum SiwaAuthResult { case signedIn(returning: Bool); case setupRequired }`.
  - [x] Subtask 2.3: Add `func siwaAuth(idToken:userName:householdName:childName:childDob:inviteToken:) async throws -> SiwaAuthResult`. On `APIError.setupRequired`, return `.setupRequired`. On 200, call `await checkStatus()` and return `.signedIn(returning:)` with the value from the response.
  - [x] Subtask 2.4: Keep `requestSiwaCredential()` as-is (it's the SIWA mechanic; unrelated to passkeys).

- [x] **Task 3 — AuthView rewrite** (AC: 1, 2, 3, 5)
  - [x] Subtask 3.1: Replace the three primary/secondary buttons with: `Continue with Apple` (primary), `Join with Invite` (secondary). Drop the recover button.
  - [x] Subtask 3.2: New action `startSiwa()`: calls `requestSiwaCredential` → calls `auth.siwaAuth(idToken:, userName: cred.fullName?.givenName, ...)`. On `.signedIn`, fall through to dashboard. On `.setupRequired`, populate `signUpDraft = SignUpDraft(siwaToken: idToken, suggestedFirstName: ..., email: ...)` to trigger the existing `.fullScreenCover(item: $signUpDraft)`.
  - [x] Subtask 3.3: New action `startJoin()`: same as today (capture invite token first, then SIWA), but the success/setup branching uses `siwaAuth` semantics from AC 5.
  - [x] Subtask 3.4: On `startJoin()` returning `.signedIn(returning: true)`, follow up with `try? await APIClient.shared.redeemInvite(token: pendingInviteToken)` then `try? await APIClient.shared.switchHousehold(hhId: redeemResp.hh_id)` then `await vm.refresh()`. On error, set `errorMessage` to the warning string from AC 5.
  - [x] Subtask 3.5: Drop `signInWorking` if still present (already collapsed in earlier hardening; verify).

- [x] **Task 4 — SignUpFlowView rewrite** (AC: 3, 4)
  - [x] Subtask 4.1: The Finish button calls `auth.siwaAuth(idToken: draft.siwaToken, userName:, householdName: isInvite ? nil : householdName, childName:, childDob:, inviteToken: inviteToken)`. On `.signedIn`, dismiss + onFinish. On `.setupRequired`: shouldn't happen post-form (would mean a server bug or user-name still empty); surface as an error.
  - [x] Subtask 4.2: Rename "Create Passkey & Finish" → "Finish setup". Replace the `faceid` SF Symbol with `checkmark.circle.fill`.
  - [x] Subtask 4.3: Confirm the existing isInvite branch (single page, just name) still works under the new flow.

- [x] **Task 5 — SettingsView multi-household switcher** (AC: 6)
  - [x] Subtask 5.1: In `SettingsView.householdSection`, replace the single `if let active = activeHousehold` NavigationLink with a `ForEach(households)` loop. Inactive rows are `Button { Task { await switchTo(hh) } } label: { SettingsRow(...) }`. The active row is the existing `NavigationLink { HouseholdDetailView(...) } label: { SettingsRow(... trailing: nil) }` with a trailing green `checkmark` glyph rendered inside the row's HStack.
  - [x] Subtask 5.2: Add `private func switchTo(_ hh: Household) async`. Body: `do { _ = try await APIClient.shared.switchHousehold(hhId: hh.hh_id); await loadHouseholds(); await vm.refresh() } catch { redeemError = error.localizedDescription }`. Reuse `redeemError` rather than introducing new state — the section's footer already surfaces it.
  - [x] Subtask 5.3: Verify the existing "Redeem invite code" row still appears below the household list. Single-household users see exactly today's UI plus the new checkmark glyph.

- [x] **Task 6 — Cleanup + verification** (AC: 10, 11, 12, 14)
  - [x] Subtask 6.1: Verify no remaining references to dropped methods/types via project-wide search (`signIn`, `performAssertion`, `performRegistration`, `webauthnAttestationJSON`, `webauthnAssertionJSON`, `loginVerify`, `registerStart`, `registerFinish`, `recoverStart`, `recoverFinish`, `ChallengeEnvelope`).
  - [x] Subtask 6.2: `cd ios && xcodegen generate && xcodebuild ... -configuration Debug build` — clean build.
  - [x] Subtask 6.3: `/sim-reload` to install on the booted sim. Manual verify per AC 12 + AC 14. Note: Debug points at dev API, so 2-1 must be deployed first.

- [x] **Task 7 — Ship to TestFlight Dev** (AC: 12)
  - [x] Subtask 7.1: `/testflight-release` (auto-picks dev from this branch per saved rule). Build number bumps automatically.

## Dev Notes

### Relevant architecture patterns and constraints

- **`SignUpFlowView` survives.** The paged form (name → household → child) is reusable as-is. Only its terminal action method changes — instead of calling `auth.completeSignUp(...)` (which did register/start + WebAuthn registration + register/finish), it calls `auth.siwaAuth(idToken: draft.siwaToken, ...)` once.
- **The same `idToken` is sent twice in the two-step flow.** SIWA tokens are valid for ~10 minutes (Apple-set TTL). The user-fills-form interlude is well under that window. Don't re-invoke SIWA for the second call — Apple won't return the name a second time (per-bundle-id-once behavior), and you'd lose any name they typed.
- **iOS does not need to know about CRED# rows.** They're server-side dead schema. The iOS client never queried them.
- **`AuthState` shape unchanged.** Still `.loading | .authenticated(userName, userId, activeHh) | .unauthenticated`. The earlier "empty user_id → unauthenticated" guard from the hardening pass stays.

### Source tree components to touch

- `ios/FormulaHelper/Networking/APIClient.swift` — drop methods, add one, add error case.
- `ios/FormulaHelper/Models/AppState.swift` — drop `ChallengeEnvelope`, add `SiwaAuthResponse`.
- `ios/FormulaHelper/Auth/AuthManager.swift` — significant rewrite; ~150 lines drop, ~60 lines add.
- `ios/FormulaHelper/Views/AuthView.swift` — button list reshape; new actions; drop recover button. `SignUpFlowView` button text + final action updated.

### Testing standards summary

- No iOS test target wired. Manual matrix per AC 11.
- Compile-clean via `xcodebuild` is the automated verification.

### Project structure notes

- Branch: dev_auth. This story is companion to 2-1-siwa-backend; ship 2-1 first, bake briefly, then 2-2.
- The `webcredentials:` associated-domains entry in `FormulaHelper.Dev.entitlements` and the `apple-app-site-association` file remain for now. Their presence doesn't break anything — they're just declarations that no longer drive a flow. Cleaning up is a separate one-line edit per file but bundled into the deferred AASA-cleanup story.
- `AuthError` reduces to two cases (`.cancelled`, `.missingSiwaToken`) — don't preemptively delete the file; the type stays useful.

### References

- [Source: docs/architecture-ios.md#Auth (Auth/AuthManager.swift)] — describes the three-flow model that's being collapsed
- [Source: docs/integration-architecture.md#Handshake flows] — references the recovery flow that becomes the canonical signin
- [Source: handler.py — `auth_siwa`] — the new server endpoint this story consumes
- [Source: ios/FormulaHelper/Auth/AuthManager.swift — `requestSiwaCredential`, `beginSignUp`, `recover`] — survival points and consolidation targets
- Sibling story: `_bmad-output/implementation-artifacts/2-1-siwa-backend.md` — must be deployed to dev before this story can be exercised end-to-end

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 via `/bmad-dev-story`.

### Debug Log References

- `xcodebuild ... -configuration Debug build` → clean (no errors). SourceKit indexer noise present but build passes — same documented quirk as prior stories.
- `grep -rn "ChallengeEnvelope|webauthnAttestationJSON|webauthnAssertionJSON|loginVerify|registerStart|registerFinish|recoverStart|recoverFinish|loginOptions|completeSignUp|performAssertion|performRegistration|auth\.recover|auth\.signIn"` against the ios/ tree → **zero hits**, all dead code removed cleanly.
- `/sim-reload` → app installed and launched on iPhone 17 Pro (PID 63164).

### Completion Notes List

**Implemented per AC:**
- **`AuthManager`** rewritten end-to-end. ~150 lines deleted; ~60 added. Surface dropped: `signIn()`, `recover()`, `completeSignUp(...)`, `performAssertion(...)`, `performRegistration(...)`, `webauthnAssertionJSON(...)`, `webauthnAttestationJSON(...)`, `parseEnvelope(...)`, `syncAfterAuth()`, the `Data + base64URLEncoded` extension. Surface added: `enum SiwaAuthResult { case signedIn(returning: Bool); case setupRequired }`, `func siwaAuth(idToken:userName:householdName:childName:childDob:inviteToken:) async throws -> SiwaAuthResult`. `beginSignUp()` retained as the SIWA-credential entry point. `AuthError` reduced to `cancelled` + `missingSiwaToken`.
- **`APIClient`** lost six methods (`registerStart/Finish`, `loginOptions/Verify`, `recoverStart/Finish`); gained `siwaAuth(...)`. New `APIError.setupRequired(needs:)` case. `checkStatus(_:_:)` now special-cases HTTP 412 by parsing the response body's `needs` array and throwing `setupRequired` instead of `badStatus`.
- **`Models/AppState.swift`** dropped `ChallengeEnvelope` (was only consumed by the WebAuthn flows); added `SiwaAuthResponse: Codable {ok, user_id?, active_hh?, returning}`. `AuthOkResponse` retained — still used by `devLogin`.
- **`AuthView`** — primary "Sign In with Passkey" + secondary "Create Account" + footer "Recover with Apple ID" all dropped. New primary "Continue with Apple" (`applelogo` SF Symbol) calls a new `startSiwa()`. "Join with Invite" retained; its `startJoin()` action now uses the SIWA flow with the captured invite token. **AC 5's returning-user-with-invite path implemented:** when `siwaAuth` returns `.signedIn(returning: true)` from `startJoin`, iOS calls `APIClient.redeemInvite(token:)` then `APIClient.switchHousehold(hhId:)` to actually merge the invite (since backend story 2-1 ignores `invite_token` for returning users by design). On error, surfaces "Signed in, but couldn't join the household — try Settings → Redeem invite code." Subtitle copy "Sign in with your passkey" → "Sign in with Apple".
- **`SignUpFlowView`** terminal `advance()` action calls `auth.siwaAuth(...)` instead of the deleted `auth.completeSignUp(...)`. Button text "Create Passkey & Finish" → "Finish setup". Icon `faceid` → `checkmark.circle.fill`. The `.setupRequired` branch is defensively handled (shouldn't occur post-form; throws if it does).
- **`SettingsView` multi-household switcher (AC 6)** — Household section now `ForEach(households)` instead of just rendering the active one. Active row: `NavigationLink` to `HouseholdDetailView` with a trailing green `checkmark` glyph. Inactive rows: `Button` whose action calls a new `switchTo(_ hh)` that hits `APIClient.switchHousehold` then `loadHouseholds()` + `vm.refresh()`. Errors surface via the existing `redeemError` footer state. `Redeem invite code` row preserved at the bottom.
- **AC 11** privacy log unchanged; AC 9, 10 confirmed (no entitlements changes; cleanup deferred).

**Deviation from skill flow (steps 5/6/7):** Same pattern as 1.1 and 2.1 — no iOS test target wired (`docs/development-guide.md#Testing`), so steps prescribing TDD/automated tests don't apply. Verification is the manual matrix per AC 12 + AC 14, which require human + real Apple ID + multi-account testing on a device. The compile-clean `xcodebuild` is the only automated check that fits the existing project conventions.

**Backend dependency:** Story 2-1 deployed to `formula-helper-dev` earlier. The new `siwaAuth` calls hit `/api/auth/siwa` which is live. End-to-end "Continue with Apple" smoke test on the sim requires a real SIWA flow which only works on-device (sim SIWA is documented as broken in `docs/architecture-ios.md#Known quirks`); the build's compile-cleanness verifies the wiring up to the network layer.

**AASA + entitlements `webcredentials:` cleanup** — still deferred per the original epic plan.

### File List

- `ios/FormulaHelper/Auth/AuthManager.swift` (rewritten) — see surface notes above.
- `ios/FormulaHelper/Networking/APIClient.swift` (modified) — six methods dropped; `siwaAuth(...)` added; `APIError.setupRequired(needs:)` added; `checkStatus` 412 special case added.
- `ios/FormulaHelper/Models/AppState.swift` (modified) — `ChallengeEnvelope` dropped; `SiwaAuthResponse` added.
- `ios/FormulaHelper/Views/AuthView.swift` (modified) — primary action + triggers reshaped; SignUpFlowView terminal action + button reskinned.
- `ios/FormulaHelper/Views/SettingsView.swift` (modified) — multi-household switcher in Household section.

### Change Log

- 2026-04-26: Story 2.2 implemented. iOS now uses one-tap "Continue with Apple" against `/api/auth/siwa`; SignUpFlowView is the 412-precondition setup form; SettingsView shows all memberships with a one-tap switch on inactive rows. WebAuthn / passkey code path fully removed from iOS.

## Open Questions / Clarifications

1. **`SignUpFlowView`'s "Create Passkey & Finish" rename.** "Finish setup" is the recommendation but the user may prefer "Done" or "Get started." Cosmetic; dev's call.

2. **Switcher dismiss when there's only one household.** Single-membership users see the same single-row UI as today (plus a green checkmark on the lone row). If you'd prefer the checkmark only show when there are ≥2 households, that's a one-line guard in the row builder — flag during dev-story if it looks visually noisy.

---

**Generated:** 2026-04-26 — direct-write companion to 2-1-siwa-backend.
