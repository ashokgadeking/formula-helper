# Code Review Triage — Review 1

Scope: full uncommitted dev_auth working tree (2777-line diff, 12 files).
Reviewers: Blind Hunter + Edge Case Hunter + Acceptance Auditor (Story 1.1 only).
Failed layers: none.
Acceptance Auditor verdict on Story 1.1: **ship it** (all 10 ACs satisfied).

## Merged findings (overlap across layers)

| # | Title | Sources | Bucket |
|---|---|---|---|
| 1 | Soft-delete is cosmetic — no data route checks `deleted_at` | blind+edge | **patch** |
| 2 | `_update_membership_role` upserts bare ghost rows + accepts non-whitelisted roles if caller skips validation | blind+edge | **patch** |
| 3 | `household_transfer` is non-atomic — partial failure leaves 0 or 2 owners | edge | **patch** |
| 4 | iOS `leave`/`delete` flows log user out on any transient list-fetch error | blind+edge | **patch** |
| 5 | iOS `redeem` uses `try?` on `switchHousehold`, then lies in the toast ("Switched to…" when it didn't) | blind | **patch** |
| 6 | Dev-login accumulates orphan Sim Households across deletes | edge | **defer** |

## Singleton findings

### Patch (unambiguous fix, no decision needed)

| # | Title | Source | Approx scope |
|---|---|---|---|
| 7 | `auth_dev_login` is registered in `PUBLIC_ROUTES` unconditionally; runtime-gated by `STAGE != "dev"`. Register the route only when stage is dev at import time. | blind | Small; `handler.py` route registration |
| 8 | `ROLE_CAPS` lookup is case-sensitive; capability check silently grants no caps on a cased mismatch. Normalize with `.lower()` on read. | blind | Trivial; `handler.py` one line |
| 9 | `household_leave` sets `active_hh = ""` without picking a next membership. Server should pick one or iOS must always re-switch. | edge | Small; `handler.py::household_leave` |
| 10 | iOS `AuthState` accepts empty `userId` from `/auth/status` as authenticated; treat empty as unauthenticated in `checkStatus`. | edge | Trivial; `AuthManager.swift::checkStatus` |
| 11 | `syncAfterAuth(ok:)` takes an `AuthOkResponse` it never uses. Drop the parameter. | blind | Trivial; `AuthManager.swift` |
| 12 | `webauthnAttestationJSON` silently sends `Data()` when `rawAttestationObject` is nil. Throw `AuthError.invalidCredential` instead. | blind | Trivial; `AuthManager.swift` |
| 13 | `startSignUp` logs SIWA first name with `privacy: .public`. PII — switch to `.private`. | blind | One line; `AuthView.swift` |
| 14 | `primaryButton` spinner binds to `signInWorking` but disable state uses `isWorking`; sign-up disables the sign-in button without showing its spinner. Consolidate or align. | blind | Small; `AuthView.swift` |
| 15 | `fullScreenCover(isPresented:)` + `if let draft = …` can render an empty cover if state diverges. Switch to `.fullScreenCover(item: $draft)`. | blind | Small; `AuthView.swift` |
| 16 | iOS child DOB formats with UTC — users near date boundary get off-by-one. Format in local timezone. | edge | One line; `SettingsView.swift` or the signup DOB formatter |

### Defer (real but not in scope for this review / pre-existing concerns)

| # | Title | Source | Reason for deferring |
|---|---|---|---|
| 17 | Dev-login leaks Sim Households over time | edge | Dev-only; bounded after soft-delete gating (#1) lands. Revisit only if row count becomes operational. |
| 18 | Names (user / household / child) unbounded in length / charset | edge | Public-release prep; not triggerable today. |
| 19 | Invite expiry uses float Unix timestamp; no client-clock-skew handling | blind | Server enforces; worst case is a cosmetic "Expired" flash. |
| 20 | `household_transfer` has no iOS client method yet (`APIClient.transferHousehold` missing) | blind | Already planned as Story 1.2 in the wrap-up epic. Not a regression. |
| 21 | Hard-coded API Gateway + CloudFront hostnames in `ios/project.yml` per-config | blind | Intentional pinning — coupled to RP_ID invariant. Leaving. |
| 22 | `InviteShareSheet` copies token to `UIPasteboard.general` (shared across apps + iCloud universal clipboard) | blind | Sensitive-enough to harden (`.setItems` with `.localOnly`+expiry). Defer until auth-hardening pass. |
| 23 | `InviteShareSheet.expiresText` doesn't refresh across midnight / expiry | edge | Cosmetic; server rejects an expired token on redeem. |
| 24 | `InviteCodeSheet` accepts URL-prefixed invite tokens without cleaning | edge | UX polish. |
| 25 | Admin role is essentially non-functional in iOS (admins have server caps `invite`+`kick` but no UI to exercise) | edge | Explicit epic-scoping — Story 1.1 is owner-only. Revisit after wrap-up epic closes if admin UX is needed. |
| 26 | `household_member_update` has no explicit self-demotion guard | edge | Defense-in-depth; current invariants prevent reaching a state where it matters. |

### Dismissed (noise / non-findings / already handled)

- **Invite "already a member" race in `invite_redeem`** (edge) — low-probability, worst case is an unused-invite burn. Reviewer themselves flagged as "ordering is backwards, but fine." Dismissed.
- **`household_member_update` empty-role 400 says "Invalid role" instead of "role required"** (edge) — trivial UX; reviewer marked Low themselves.
- **Residual `name == "ashok"` admin checks** (blind L) — grep-verified clean: no such check remains in the iOS tree.
- **`encodePathComponent` marked `nonisolated`** (blind L) — not a bug; intentional.
- **`deploy.sh` untracked, account-ID guard unverifiable** (blind L) — out of diff scope; script is covered by user memory + in-repo test.
- **`ROLE_CAPS: dict[str, set[str]]` typing** (blind L) — Python 3.12 runtime supports this. Not a bug.
- **TODO.md mentions "APNs key in ASC"** (blind L) — no secret leaked; just a reminder that a key must exist. Dismissed.
- **Dev Login button ships in Dev TestFlight** (blind M) — intentional, gated on `IsDevStack` plist key. Not prod-reachable; `com.ashokteja.formulahelper.dev` is not the App Store binary.
- **Dev-login "first owned HH" ordering unstable** (edge L) — dev-only; ordering doesn't matter operationally.
- **SIWA recovery for abandoned registration** (edge) — reviewer verified it's handled safely (`_user_id_for_apple_sub` returns None → 404).

## Summary counts

- **patch** (fix now, unambiguous): **16** findings (6 merged + 10 singletons)
- **defer** (real, not in scope): **10**
- **decision_needed**: 0
- **dismiss**: 10

## The single biggest issue

**#1 — Soft-delete is cosmetic.** Flagged independently by both blind and edge-case hunters. `household_delete` writes `deleted_at` only on the HH META row; `_require_member` (and therefore every protected household-scoped route except `households_list`) never consults it. Net effect:

- Members of a deleted household keep reading `/api/state`, writing feedings/diapers/naps, minting invites, changing roles, and being kicked / transferred — all on a ghost resource.
- Non-caller sessions still have `active_hh = H` after the delete; the client UI shows "no household" but the server keeps accepting writes to H.
- Invites minted before the delete still redeem into the tombstoned household, pulling new users into a ghost.
- The dev-login "reuse owned + alive" filter we just shipped works, but it's swimming against this leak.

This is the highest-priority item across the entire review. Fix shape: introduce `_require_alive_member(session, hh_id)` that does the existing `_require_member` check plus loads HH META and rejects if `deleted_at` is set; use it everywhere today's code uses `_require_member`. Same change should land in `_consume_invite` or `invite_redeem`.
