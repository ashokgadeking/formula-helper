# Blind Hunter Findings

## High severity

- **`household_delete` soft-deletes but does not revoke other members' access** — The delete handler writes `deleted_at` on the HH#META record and clears `active_hh` **only on the caller's session**. Every other member's session still has `active_hh=<hh_id>`, and only `households_list` filters soft-deleted rows — per-resource endpoints (feedings/diapers/naps/state) are not shown to check `deleted_at`. A kicked/orphaned member can likely keep writing to a "deleted" household. Evidence: `lambda/handler.py:~2712` — `UpdateExpression="SET deleted_at = :t"` followed by only `if session.get("active_hh") == hh_id: … clear active_hh` for the caller only.

- **`auth_dev_login` route is `PUBLIC_ROUTES`-registered with only a runtime STAGE check** — The route is always registered. Protection is an `if STAGE != "dev": return 404`. If `STAGE` env is ever missing, misconfigured, or set to a value other than exactly `"dev"` (e.g. `"Dev"`, `"development"`, `"DEV"`), the 404 guard will still trigger… but the inverse is worse: if prod ever gets `STAGE=dev` accidentally, this mints sessions for `"dev-sim-user"` with no auth. The route should be conditionally *registered* at import time, not gated per-request. Evidence: `lambda/handler.py:~2544` — `if STAGE != "dev": return _json({"error": "Not found"}, 404)` and route table entry at `~2747`.

- **`household_member_update` allows demoting the last owner to member via role-check bypass path** — Guard rejects `new_role == "owner"` and rejects `target.role == "owner"`. Good. But `household_transfer` calls `_update_membership_role(..., session["user_id"], "admin")` on the current owner with zero check that target is actually an existing member of the household. An owner can call transfer with `user_id` of someone who was just kicked (mirror record deleted) — `target = table.get_item(...).get("Item")` would return None and return 404, so that's fine. However `_update_membership_role` for a stale/nonexistent user writes a brand-new row `USER#<uid>/HH#<hh>` and `HH#<hh>/MEMBER#<uid>` with just a `role` attribute set — reintroducing a ghost membership without name/joined_at. Evidence: `lambda/handler.py:~2473` — `_update_membership_role` uses `update_item` with `SET #r = :r` which creates the item if absent (DynamoDB default upsert behavior).

## Medium severity

- **Dev-only "bypass" button shipped in release-capable binary, gated only by a plist string** — `AuthView` shows "Dev Login (bypass)" when `IsDevStack == "YES"`. The DevRelease xcconfig sets `IS_DEV_STACK: "YES"`, so this ships in the Dev TestFlight build. If someone ever flips the Release config by mistake, or the plist substitution fails and reads literal `$(IS_DEV_STACK)` (which is not `"YES"` but also would be truthy as a non-nil string? actually no, the comparison is `== "YES"` so it'd be safe). Still: shipping a production-code path that calls `devLogin` is a concern. Evidence: `AuthView.swift:~733` + `APIClient.swift:~531` + `project.yml:~2383,2415`.

- **`leaveHousehold` on iOS falls back to `auth.logout()` if there's no next household, but backend doesn't log the user out** — `leave()` calls `APIClient.shared.leaveHousehold`, then if no other household remains, `await auth.logout()`. The user's server session is still valid (with empty active_hh); logout is called separately via `/api/auth/logout`. However `deleteHousehold` uses the same pattern — but after a destructive soft-delete, if the call to list or switch fails silently (`try?`), the UI may end up in a state where the user is "logged out" locally but server session lingers. Evidence: `SettingsView.swift:~2133-2147` — `let list = try? await APIClient.shared.listHouseholds()` with silent failure.

- **`redeem` silently swaps active household with `try?`** — `SettingsView.redeem` calls `switchHousehold` with `try?`; if the switch fails, the UI says "Joined. Switched to the new household." but you're still on the old one. User-facing message lies about state. Evidence: `SettingsView.swift:~1422-1429`.

- **`primaryButton` uses `signInWorking` for spinner but `isWorking` for disable state** — Two separate booleans gate the same button. When "Create Account" is pressed `isWorking` flips true (disabling the button) but `signInWorking` stays false — so the sign-in button shows its icon, not a spinner, yet is disabled. The sign-in button's spinner will never show during sign-up operations. That's confusing but fine. But on sign-in, `signInWorking = true` and `isWorking = true` are set in the button closure itself rather than before the label re-renders; `defer { signInWorking = false }` is also inside the closure. Given SwiftUI diffing, the spinner flash is unreliable. Evidence: `AuthView.swift:~796-800` and `~921-923`.

- **`showSignUpFlow` and `showJoinFlow` both use `fullScreenCover` with a guard `if let draft = …` — if the draft is nil the cover presents an empty view** — Presentation is tied to a Bool while the content requires an optional. If state sequencing causes the bool true but draft nil (e.g. re-entry), you get a blank full-screen cover with no dismiss affordance. Evidence: `AuthView.swift:~843-860`.

- **`deleteHousehold` never actually deletes household-owned data** — It only sets `deleted_at` on META. Membership rows remain, invites remain, feeding/diaper/nap/log records remain. Called "soft-delete" but the footer in the UI says "Logs, settings, and invites are retained but hidden" — the backend does not filter any of them. A member still in the `HH#<id>/MEMBER#*` rows who re-activates `active_hh` to that deleted id could still read/write logs if any route doesn't re-check `deleted_at`. Evidence: `lambda/handler.py:~2703-2725`.

- **`_update_membership_role` uses upsert, not conditional update** — Writes both forward+mirror rows unconditionally with `update_item`, which creates items if missing. Combined with race against a concurrent `_remove_membership`, a kicked user could reappear with a role attribute. Evidence: `lambda/handler.py:~2473`.

- **Lowercase-role comparisons inconsistent** — In iOS `canKick`/`canChangeRole` use `m.role.lowercased() == "owner"`, but backend `_require_capability` looks up `ROLE_CAPS.get(member.get("role", ""))` with **no** case normalization. If a row ever has role `"Owner"` (e.g. from some other code path) it maps to empty caps set — owner loses all privileges. Tight coupling to exact lowercase writes everywhere. Evidence: `lambda/handler.py:~2456` vs `SettingsView.swift:~1691`.

- **Invite `expires` is a float timestamp surfaced to the client directly** — `InvitePreview.expires: Double` and `InviteCreateResponse.expires: Double`. iOS computes `invite.expires - Date().timeIntervalSince1970`. No server/client clock-skew handling. Minor UX bug potential: shows "Expired" on a still-valid code if client clock is fast. Evidence: `AppState.swift:~452,457` and `SettingsView.swift:~2193`.

## Low severity

- **`LoginVerifyResponse` removed, replaced by `AuthOkResponse`, but `syncAfterAuth(ok:)` ignores its parameter entirely** — Signature takes `ok: AuthOkResponse` but body just calls `checkStatus()`. Parameter is unused. Either drop it or use it. Evidence: `AuthManager.swift:~183-186`.

- **`FormulaHelperApp.swift` removed the `auth.userName == "ashok"` hardcoded admin check** — Good cleanup, but confirms the codebase recently had a name-based admin. Any residual `== "ashok"` checks elsewhere should be audited. (I cannot check — diff only.) Evidence: `FormulaHelperApp.swift:~347` old lines.

- **`encodePathComponent` made `nonisolated`** — Fine, but the function is still called from actor-isolated code in path interpolation. Not a bug; just calling out the intentional hop. Evidence: `APIClient.swift:~704`.

- **`webauthnAttestationJSON` falls back to `Data()` if `rawAttestationObject` is nil** — Silently sends an empty attestation object to the server instead of throwing. Previously, the code explicitly threw `.invalidCredential`. Server will reject but the error surfaced to user will be a server 4xx, not a clear local error. Evidence: `AuthManager.swift:~269-280` — `(c.rawAttestationObject ?? Data()).base64URLEncoded`.

- **`startSignUp` logs SIWA `firstName` with `privacy: .public`** — First name is PII. `.public` logging means it lands in unified logs readable from Console.app for anyone with access. Should be `.private` or `.sensitive`. Evidence: `AuthView.swift:~884`.

- **`deploy.sh` referenced in git status as untracked** — Cannot review (no diff content for it here, it's untracked). Worth checking that account-ID assertion actually runs before `sam deploy` — noted in user memory but not verifiable from diff.

- **Hard-coded AWS API Gateway hostnames** `3lgqmzurih.execute-api.us-east-1.amazonaws.com` and `d20oyc88hlibbe.cloudfront.net` in `project.yml` per-config. Not secrets, but coupled across Info.plist + entitlement + xcconfig. A rename requires 3 places. Evidence: `project.yml:~2381-2414`.

- **`InviteShareSheet` copies token to `UIPasteboard.general`** — General pasteboard is shared across apps/iCloud universal clipboard. Invite tokens are bearer-ish credentials. Consider `UIPasteboard(name:, create:)` or at least `.setItems([...], options: [.localOnly: true, .expirationDate: …])`. Evidence: `SettingsView.swift:~2236`.

- **`household_transfer` not wired into capability map check order vs. route** — Route is registered but I don't see it in the iOS `APIClient`. Backend route exists, iOS has no way to call it. Either dead backend route or incomplete iOS. Evidence: `lambda/handler.py:~2758` vs `APIClient.swift` (no `transferHousehold` method in diff).

- **`ROLE_CAPS` dict typed with `set[str]`** — Python 3.9+ syntax OK for modern Lambda runtimes, just flagging. Evidence: `lambda/handler.py:~2450`.

- **TODO.md note about push notifications includes no redaction of design intent** — Fine, but mentions "APNs key in ASC" — low-value leak of ops plans in repo. Evidence: `TODO.md:~14`.

## Notes / non-issues I considered but dismissed

- `APIBaseURL` defaulting to `""` in Info.plist if the build var isn't substituted would make every request fail with an invalid URL — but `URL(string: "" + path)` returns non-nil for paths starting with `/`, then the force-unwrap on line 701 (`URL(string: Self.baseURL + path)!`) relies on that. Considered flagging but the failure mode is loud and during first request, not silent.
- `sortMembers` tiebreaker by `localizedCaseInsensitiveCompare` — fine.
- Removal of `DEV_STACK` compilation condition and replacing with Info.plist flag — reasonable refactor, not a bug.
- `ChallengeEnvelope` struct defined but never decoded (parsing is manual via JSONSerialization). Dead struct but trivial. Listed as Low would be noise.
