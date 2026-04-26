# Edge Case Hunter — Review 1

Scope: diff at `_bmad-output/implementation-artifacts/review-1/diff.patch`. Focus: household role management (Story 1.1), dev-login filter, SIWA recovery paths, iOS flows.

## High

## Soft-deleted households still accept reads and writes
**Path walked:** Owner A deletes household H (soft-delete sets `deleted_at`). Member B's session still has `active_hh == H`. B calls `POST /api/feedings`, `POST /api/diapers`, `POST /api/naps`, `PUT /api/households/H/members/…`, `POST /api/invites`, `GET /api/state`, etc.
**Observed behavior:** Every data route uses `_require_member` (handler.py:156), which only checks the `HH#<id> / MEMBER#<uid>` row exists. It never loads HH META nor inspects `deleted_at`. Membership rows are NOT removed on `household_delete` (handler.py:889–911), so the mirror record is still there. Every logging endpoint will happily write to the deleted household (`handler.py:1015–1257`). `invite_create` will mint a usable invite for a deleted household. `household_member_update`, `household_member_remove`, `household_transfer` also still succeed.
**Why it's wrong:** Soft-delete must gate all reads/writes, not just `households_list`. Otherwise "deleted" is a UI-only illusion; members keep producing orphan data and new invitees can join a phantom household.
**Severity:** High

## Owner deletes household, non-owner members stranded with orphan `active_hh`
**Path walked:** Owner deletes H. Member B's session still points at H (only the caller's session is cleared — handler.py:903–910). B opens the app next.
**Observed behavior:** `/api/households` filters H out. `/api/state` still reads from H (writes succeed because of the finding above). iOS `SettingsView.activeHousehold` falls back to `households.first` — *different* from `session.active_hh`. A log write from the UI goes to `session.active_hh` = H (server uses session, not the client's chosen hh), so UI and data diverge silently.
**Why it's wrong:** On delete, the server should either (a) invalidate all non-owner sessions' `active_hh == H`, or (b) have data routes verify the HH is alive before accepting writes (ties into the first finding).
**Severity:** High

## `_update_membership_role` accepts arbitrary role strings when called indirectly
**Path walked:** `PUT /api/households/{hh}/members/{uid}` with `{"role": "Owner"}` (capital O). `new_role not in ROLE_CAPS` check (handler.py:805) is case-sensitive, so "Owner" → 400. But `{"role": "OWNER"}` etc. also fail. However `{"role": "admin"}` passes while `target.role` check compares `target.get("role") == "owner"` exactly. A future code path that calls `_update_membership_role` with an unchecked role will silently stamp whatever string into both records.
**Observed behavior:** `_update_membership_role` (handler.py:187) has no role whitelist of its own. All safety relies on callers validating `new_role in ROLE_CAPS` first. Also, `ROLE_CAPS` check rejects unknown roles, but nothing enforces that both forward + mirror records actually exist before updating — `table.update_item` will silently create a partial item if the key is missing.
**Why it's wrong:** Two risks: (1) divergent role bits if one of the two keys is missing (update_item does an implicit upsert — creates a bare `{role}` item without joined_at/hh_id/hh_name). (2) Validation centralization: helper should enforce the whitelist itself.
**Severity:** High

## Transfer ownership is non-atomic; partial failure leaves two owners or zero owners
**Path walked:** `household_transfer` runs three writes: promote target to owner, demote caller to admin, update HH META owner_uid (handler.py:880–886). If the second write fails (throttle, transient error, Lambda timeout between calls), you end up with two owners. If the third fails, owner_uid META disagrees with the mirror records.
**Observed behavior:** No transaction wrapper (no `transact_write_items`), no compensating rollback. The function returns 500 to the client but state is half-committed.
**Why it's wrong:** The "one owner" invariant is explicitly relied on by `canKick`, `canChangeRole`, `kick`, role update (`Cannot demote owner directly`), and delete. Two-owner state lets two admins keep demoting each other; zero-owner state breaks deletion and invites forever.
**Severity:** High

## Race: concurrent transfers create two owners
**Path walked:** Owner A invokes transfer → B at the same moment as owner A2 (if dual-owner state ever exists, or via retry). Or: owner A transfers → B while B simultaneously kicks C — no conditional check on A's role being owner at write time.
**Observed behavior:** `_update_membership_role` issues unconditional `SET #r = :r`. No `ConditionExpression` like `#r = :expected_role`.
**Why it's wrong:** Any mutation changing ownership-related role should be a conditional write keyed to the currently-read role to prevent lost updates and invariant violations.
**Severity:** High

## `household_delete` does not verify household is not already deleted
**Path walked:** Owner calls DELETE twice (double-tap, or second client). Second call overwrites `deleted_at` with a newer timestamp.
**Observed behavior:** Plain `SET deleted_at = :t` (handler.py:898). Also, once `deleted_at` is set, the owner's membership row still exists with `role=owner`, and capability check still passes — so a still-authenticated owner can keep calling `/leave`, `/transfer`, `/members/...`, `/delete` on a deleted household. `/transfer` on a deleted HH would revive ownership for another user on a supposedly-deleted resource.
**Why it's wrong:** All household-admin routes must reject if HH is soft-deleted. Also idempotency: second delete should 204/409, not silently timestamp-stomp.
**Severity:** High

## Invite redeemable into a soft-deleted household
**Path walked:** Owner creates invite. Owner deletes household. User B (or a new signup via register_start) redeems.
**Observed behavior:** `invite_redeem` (handler.py:945) and `auth_register_finish` (handler.py:530) call `_get_invite` + `_consume_invite` but never load HH META to check `deleted_at`. `_add_membership` writes a membership row into a deleted HH. For a new-signup flow, the user is created and gets an orphan membership — no other HH to fall back to.
**Why it's wrong:** Should verify HH alive before consuming the invite, and invalidate outstanding invites when a household is deleted.
**Severity:** High

## Dev-login creates runaway "Sim Household" records if every owned HH has been deleted
**Path walked:** Dev user A owns H1, deletes it. Dev-login runs again. Filter skips H1 (deleted). Creates "Sim Household" H2. Delete H2. Next dev-login → H3. Each run leaks a household.
**Observed behavior:** `auth_dev_login` (handler.py:676) only skips but never reclaims or resurrects. `_list_memberships` also returns the memberships of deleted households; they stay in USER# partition forever.
**Why it's wrong:** Leaks rows; also prevents the documented "reuse an OWNED household if one exists" from actually reusing — because soft-delete is permanent without a reversal path. Either hard-delete on dev-login tear-down, or clear `deleted_at` when reclaiming.
**Severity:** High (dev-only route, but it's called often during UI testing → rapid row accumulation, and future "restore via support" tooling would resurrect the oldest Sim HH)

## Medium

## Client supplies target_uid for transfer without verifying target is still a member
**Path walked:** Owner A picks B from member list (stale cache), B is kicked between render and tap.
**Observed behavior:** `household_transfer` does `get_item(MEMBER#target)` and 404s if missing. Good. But if a race happens *after* the get (kick in parallel), `_update_membership_role` upserts a new MEMBER record with just `role=owner` and no `joined_at`, `user_id` field, etc. See finding "`_update_membership_role` upsert" above.
**Observed behavior detail:** Specifically `_update_membership_role` will recreate the row DynamoDB-style (`update_item` with a missing key creates the item). So a kicked user could be resurrected as owner of a household.
**Severity:** Medium

## `household_member_update` trusts client-supplied `role` string; no demotion of self prevented
**Path walked:** Owner A PUTs their own user_id with `role=member`.
**Observed behavior:** `change_role` capability check passes (A is owner). The `target` row is A's own membership; it has `role=owner`, so the demote-owner branch returns 400 (handler.py:812). Fine for that case. But if A PUTs `role=admin` for themselves: they are owner → `target.role == 'owner'` → 400. OK. What if A PUTs themselves with `role=member` and they are currently admin in a weird post-transfer state (shouldn't happen normally, but see non-atomic transfer above)? No self-guard at all; will demote self to member, losing the only-admin status.
**Why it's wrong:** Explicit self-demotion guard missing; would be defense in depth against invariant-break states.
**Severity:** Medium

## `household_leave` writes `active_hh = ""` but doesn't pick a next one
**Path walked:** User in 3 households leaves current. Session `active_hh` is set to empty string.
**Observed behavior:** handler.py:854–860. Next request that uses `session.active_hh` (e.g., `/api/state`, `/api/feedings`) will hit `_require_member(session, "")` → 403. UI has to re-call `/api/households/switch` explicitly. iOS `leave()` *does* call `switchHousehold` (SettingsView line around 2137), but only if the list response lands correctly. If `listHouseholds` fails after the leave succeeds, iOS calls `auth.logout()` — so the user is logged out even though they still have other households. Spurious logout.
**Why it's wrong:** Server should pick the next viable membership and set it, not leave it empty. Or iOS should retry the list before assuming no memberships.
**Severity:** Medium

## iOS `deleteHousehold`/`leave` logout user on transient network failure
**Path walked:** Owner deletes HH, then `listHouseholds()` throws (timeout).
**Observed behavior:** `list?.households.first(where:...)` short-circuits through `try?`, returning nil, which triggers `await auth.logout()` (diff lines 2143, 2160). A transient read error now forcibly logs out the user instead of keeping them with their remaining household memberships.
**Why it's wrong:** Distinguish "no other households" from "couldn't fetch list". The former is logout-worthy; the latter should retry or just refresh.
**Severity:** Medium

## iOS `auth.authState.userId` nil/empty is treated as valid comparator
**Path walked:** `authState` is `.authenticated(userName: "", userId: "", activeHh: nil)` because `authStatus()` returned user_id=null/empty (new server rolled back? or stage mismatch).
**Observed behavior:** `canKick`/`canChangeRole` compare `m.user_id == auth.authState.userId`. If both are empty strings and the member has `user_id=""` (corrupt row, or from migrated data), the guard accidentally passes "don't kick self" even for a non-self member. More importantly, if userId is empty, Owner sees "kick self" enabled on any user because the `==` is string-based and empty != any real uid, so no protection loss — but the capability UI becomes confusing.
**Why it's wrong:** iOS should fall back to `.unauthenticated` if userId/activeHh essentials are missing rather than entering a half-authenticated state.
**Severity:** Medium

## Invite "already a member" check precedes `_consume_invite`, but not atomic
**Path walked:** User B in two simultaneous tabs redeems the same invite for a household they're already a member of via other path.
**Observed behavior:** `invite_redeem` (handler.py:957) does a point read for existing membership, then calls `_consume_invite` (conditional on `used_at=""`). Between those, the membership could be added by the register_finish flow on a parallel signup (unlikely but possible for multi-device), leading to invite being consumed AND 409 mismatch state.
**Why it's wrong:** Low-probability race; worst case invite is burned but user is a member, which is fine. Flag only because the ordering is backwards — consume first, then idempotent add_membership — would be safer.
**Severity:** Medium

## `household_member_update` — empty/missing body `role` becomes "", rejected but error is misleading
**Path walked:** Client sends `{}`.
**Observed behavior:** `(data.get("role") or "").strip()` → "". `"" not in ROLE_CAPS` → 400 "Invalid role". Acceptable.
**Why it's wrong:** Not wrong per se, but 400 should say `role required` for empty string. Minor UX.
**Severity:** Low — noting only.

## Unicode / length unbounded for household/user/child names, invite tokens
**Path walked:** User names themselves with 10,000-char string or emoji-heavy input. `auth_register_start` trims but does not cap length. `child_name` unbounded. `household_name` unbounded.
**Observed behavior:** Strings go straight into DynamoDB items. DynamoDB item size limit is 400KB total — well above any iOS input, but echoing a giant name on `/households` response could bloat payloads or break `user_display_name` in WebAuthn options.
**Why it's wrong:** Defensive bound check (e.g., 80 chars user_name, 80 hh, 80 child) missing. Not exploitable today but a public-release prep item.
**Severity:** Medium

## SIWA recovery succeeds for a user that never completed registration (no CRED yet)
**Path walked:** User starts register_start (SIWA succeeded, pre-minted `user_id`, challenge stored). They abandon before register_finish. Later they hit "Can't sign in? Recover with Apple ID".
**Observed behavior:** `auth_recover_start` (handler.py:614) looks up `_user_id_for_apple_sub(claims["sub"])`. But `_put_user` is only called in register_finish — so no USER row was created, no APPLESUB lookup row exists. Result: `user_id` is None → 404 "No account associated with this Apple ID". OK.
**Observed behavior:** But the scarier case: two abandoned SIWA registrations with different `user_id`s that never completed. Then user actually completes register — they got a clean account. Good. So this is safe. Verified.
**Severity:** Non-finding (handled).

## Low

## `InviteShareSheet.expiresText` uses wall-clock at render time, never refreshes
**Path walked:** User leaves the share sheet open across midnight / past expiry.
**Observed behavior:** `expiresText` computed once per body render; no timer. An expired token will still show "Expires in X min". Cosmetic only — server rejects the expired token on redeem.
**Severity:** Low

## iOS `childDob` DatePicker default is 3 months ago but timezone is local
**Path walked:** User in UTC+14 submits DOB. `isoDate` formats the `Date` with UTC timezone (diff line ~1282).
**Observed behavior:** A user selecting "today" in NZ could get yesterday's UTC date. Off-by-one for baby's DOB.
**Severity:** Low

## `canChangeRole` / `canKick` swallow the `household_member_remove` admin-vs-admin rule
**Path walked:** Admin actor A views member list; sees admin B with kick swipe enabled.
**Observed behavior:** iOS `canKick` only gates `isOwner` (diff line ~1908), so admins see no kick affordance regardless. Server also blocks admin→admin kick (handler.py:836). Divergent rules: iOS is stricter than server (admins can kick members per ROLE_CAPS but iOS hides the swipe). iOS `canChangeRole` also only allows owners.
**Why it's wrong:** Admin role is essentially non-functional in the iOS UI — admins have server capabilities (`invite`, `kick non-admin`) they can't exercise from the app. Epic/sprint decision, but worth flagging.
**Severity:** Low

## Dev-login picks "first owned HH" but ordering is DynamoDB natural; no guarantee of stability
**Path walked:** Dev user has two owned HHs.
**Observed behavior:** `_list_memberships` returns items in query order (partition-sorted by SK). Since SKs are `HH#<uuid-ish>`, order depends on UUID. Comment says "so the dev user always lands as owner" — they always do. But the *specific* HH they land in changes between runs.
**Severity:** Low

## `household_member_remove` 400 vs 403 semantic confusion
**Path walked:** Member M calls DELETE /api/households/H/members/M (self).
**Observed behavior:** Capability check: member role has no `"kick"` → 403 Forbidden. Never reaches the self-check's 400 "Use /leave to remove yourself". Fine for members. For owners kicking self: capability passes → 400 "Use /leave". Fine. For admins: cap passes → self-check 400. Fine. Verified.
**Severity:** Non-finding.

## iOS `InviteCodeSheet` only trims whitespace, allows malformed tokens
**Path walked:** User pastes a stray "\n" or URL prefix "https://.../invites/xyz".
**Observed behavior:** Sent as-is to `/api/invites/{trimmed}/redeem`; server 404s. OK, just poor UX. Consider stripping protocol/path.
**Severity:** Low

## Non-findings I verified

- `invite_redeem` already-a-member check returns 409 correctly (handler.py:957).
- `household_member_remove` blocks kicking owner and admin-vs-admin (handler.py:833–837).
- `household_transfer` rejects self-transfer and missing target (handler.py:875).
- `_consume_invite` uses `ConditionExpression` for atomic one-shot redemption (handler.py:391).
- `auth_dev_login` correctly 404s on non-dev stages (handler.py:679).
- `auth_register_start` rejects duplicate Apple sub (handler.py:442).
- `households_list` filters soft-deleted HHs from the response (handler.py:729).
- iOS `leave`/`delete` flows clear `memberToKick`/`memberForRoleChange` on dialog dismiss.
- WebAuthn `expected_rp_id` and `expected_origin` are enforced on all verify paths.
- `iosCanKick` blocks kicking self (the `m.user_id == auth.authState.userId` guard).
- `auth_logout` clears the session cookie.
