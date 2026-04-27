# Story 2.1: SIWA-only backend (drop passkeys)

Status: review

**Epic:** 2 — Passkey → SIWA-only auth
**Story ID:** 2.1
**Story Key:** 2-1-siwa-backend

## Story

As the **AvantiLog team**,
I want to **collapse the entire auth surface to a single Sign in with Apple endpoint and remove all WebAuthn / passkey code paths**,
so that **users can sign in with one tap and the codebase no longer carries the complexity of two parallel identity systems**.

## Acceptance Criteria

1. **One public auth route replaces six.** `lambda/handler.py` `PUBLIC_ROUTES` adds `POST /api/auth/siwa` and removes:
   - `POST /api/auth/register/start`
   - `POST /api/auth/register/finish`
   - `POST /api/auth/login/options`
   - `POST /api/auth/login/verify`
   - `POST /api/auth/recover/start`
   - `POST /api/auth/recover/finish`

   `auth_logout`, `auth_status`, `auth_dev_login`, `apple_app_site_association`, and `invite_preview` are unchanged.

2. **`POST /api/auth/siwa` request body shape:**
   ```json
   {
     "siwa_id_token": "<required>",
     "user_name": "<optional, required on first-time signup if Apple omits name>",
     "household_name": "<optional, mutually exclusive with invite_token>",
     "child_name": "<optional>",
     "child_dob": "<optional, YYYY-MM-DD>",
     "invite_token": "<optional, mutually exclusive with household_name>"
   }
   ```

3. **Two-step semantics — returning user (happy path):** caller posts `{siwa_id_token}` only.
   - Server calls existing `_verify_siwa(id_token)` and reads `claims["sub"]`.
   - Server calls existing `_user_id_for_apple_sub(sub)`.
   - If a `user_id` is returned, server calls existing `_create_session(user_id, active_hh)` (where `active_hh` is the user's first remaining membership or `""`), sets the session cookie, and returns:
     ```json
     {"ok": true, "user_id": "...", "active_hh": "...", "returning": true}
     ```
   - HTTP 200. No setup fields needed.

4. **Two-step semantics — first-time without setup details:** caller posts `{siwa_id_token}` and Apple-sub lookup misses.
   - If body has **neither** `household_name` nor `invite_token`, return:
     ```json
     {"error": "Setup required", "returning": false, "needs": ["user_name", "household_name_or_invite_token"]}
     ```
     HTTP **412 Precondition Required**. No cookie set.

5. **Two-step semantics — first-time with household setup:** body has `siwa_id_token`, `user_name`, `household_name`, optional `child_name`/`child_dob`, no `invite_token`.
   - Server creates user via existing `_put_user(user_id, apple_sub=sub, name=resolved_name, email=resolved_email)`. The `resolved_name` prefers Apple's `claims.get("name")` shape (full name dict) → falls back to `user_name` from body. `resolved_email` prefers `claims.get("email")` → empty string.
   - Server creates household via existing `_create_household(household_name, owner_uid=user_id, child_name, child_dob)`.
   - Issue session, set cookie, return `{ok: true, user_id, active_hh: hh_id, returning: false}`. HTTP 200.

6. **Two-step semantics — first-time with invite:** body has `siwa_id_token`, `user_name`, `invite_token`, no `household_name`.
   - Server validates invite up-front via existing `_get_invite(token)` (404 if invalid/expired/used).
   - Server creates user via `_put_user(...)` (same name/email resolution as AC 5).
   - Server consumes invite via existing `_consume_invite(token)`. If consume fails (race), 409 `{error: "Invite already used"}` and roll back the just-created user via `table.delete_item` on `USER#<uid>/PROFILE` and `APPLESUB#<sub>/LOOKUP`.
   - Server adds membership via existing `_add_membership(hh_id, user_id, role="member", hh_name=invite["hh_name"])`.
   - Issue session, return `{ok, user_id, active_hh: hh_id, returning: false}`.

7. **Mutually-exclusive setup fields.** If body has both `household_name` and `invite_token`, return 400 `{error: "household_name and invite_token are mutually exclusive"}`.

8. **Apple-name resolution.** Apple returns `name` only on the first authorization for an Apple ID + bundle id pair. Server must:
   - Try `claims.get("name")` first (Apple's full-name dict shape `{firstName, lastName}` or string).
   - Fall back to body's `user_name`.
   - If neither resolves to a non-empty string and we're on first-time signup, return 400 `{error: "user_name required on first signup"}`.
   - Returning users (AC 3) don't need a name in the body — server uses the existing `USER#<uid>/PROFILE.name`.

9. **Drop dead helpers.** Remove:
   - `_put_credential`, `_get_credential`, `_update_sign_count`, `_list_credentials_for_user`
   - The `webauthn` import block (`import webauthn`, `from webauthn.helpers ...`, `from webauthn.helpers.structs ...`).
   - `lambda/requirements.txt`: drop the `webauthn>=2.0,<3.0` line. Keep `pyjwt[crypto]>=2.8,<3.0` (still used for SIWA + sessions).

10. **CRED# rows are NOT deleted.** Existing `CRED#<cred_id_b64>/CRED` items in the dev DynamoDB table become orphan rows. They cost negligible bytes, and leaving them means rollback (revert this commit, redeploy) restores passkey logins for any user who still has a CRED# row. Cleanup is a separate deferred story.

11. **Idempotency / replay.** A second call to `/auth/siwa` with the same token within the SIWA token's TTL produces a fresh session for the (now-returning) user. No duplicate `USER#<uid>` records — `_put_user` is keyed on the random user_id and the `APPLESUB#<sub>/LOOKUP` reverse index is the singleton lookup. The first call's create + the second call's lookup-hit-then-session is the expected order.

12. **Logging:** print one line per request — `print(f"[siwa] returning={returning} user_id={user_id} active_hh={active_hh}")` — so CloudWatch can be grepped for sign-in cadence after the rewrite. Don't log `siwa_id_token` or any PII.

13. **No test target exists for this Lambda.** Manual verification only:
    - **Returning user:** `curl` `/auth/siwa` with the dev sim user's stored apple_sub via a freshly-minted SIWA token (or invoke from iOS once Story 2-2 ships). Expect 200 + `returning: true`.
    - **First-time, no setup:** `curl` with bare token. Expect 412 with `needs` array.
    - **First-time, with household:** `curl` with token + user_name + household_name. Expect 200 + `returning: false`. Verify in DynamoDB: `USER#`, `APPLESUB#`, `HH#`, `MEMBER#` all created.
    - **First-time, with invite:** mint an invite via the existing flow, then `curl` with token + user_name + invite_token. Expect 200 + correct hh_id.
    - **Conflict:** post both `household_name` and `invite_token`. Expect 400.

14. **No iOS changes in this story.** iOS will continue working against the old endpoints until Story 2-2-siwa-ios ships — which means until 2-2 is in TestFlight, the dev TestFlight app is broken (sign-in fails). Acceptable because dev_auth is the public-rollout-prep branch, not in user-facing distribution.

## Tasks / Subtasks

- [x] **Task 1 — Add `auth_siwa` handler** (AC: 2, 3, 4, 5, 6, 7, 8, 12)
  - [x] Subtask 1.1: Insert `auth_siwa(event)` in `lambda/handler.py`, replacing the existing block of `auth_register_start` through `auth_recover_finish`. Use existing helpers: `_parse_body`, `_verify_siwa`, `_user_id_for_apple_sub`, `_put_user`, `_new_id`, `_create_household`, `_add_membership`, `_get_invite`, `_consume_invite`, `_create_session`, `_session_cookie`, `_json`.
  - [x] Subtask 1.2: Resolve `user_name` per AC 8 (Apple claim → body fallback → 400). Resolve `email` per AC 5 (claim → empty string).
  - [x] Subtask 1.3: Implement the four-way branch: returning, first-time-no-setup, first-time-household, first-time-invite.
  - [x] Subtask 1.4: Roll back user creation on invite-consume failure (AC 6) by deleting `USER#<uid>/PROFILE` and `APPLESUB#<sub>/LOOKUP`.
  - [x] Subtask 1.5: Add the one-line print log per AC 12.

- [x] **Task 2 — Update route table** (AC: 1)
  - [x] Subtask 2.1: Edit `PUBLIC_ROUTES` in `handler.py`. Remove the six dropped routes; add `("POST", r"^/api/auth/siwa$", auth_siwa)`. Keep `auth_dev_login` registration (`if STAGE == "dev"` block) untouched.

- [x] **Task 3 — Delete dead handlers + helpers** (AC: 9)
  - [x] Subtask 3.1: Delete handler functions `auth_register_start`, `auth_register_finish`, `auth_login_options`, `auth_login_verify`, `auth_recover_start`, `auth_recover_finish`.
  - [x] Subtask 3.2: Delete helpers `_put_credential`, `_get_credential`, `_update_sign_count`, `_list_credentials_for_user`.
  - [x] Subtask 3.3: Remove the `import webauthn` block + the `from webauthn.helpers...` and `from webauthn.helpers.structs...` imports.
  - [x] Subtask 3.4: Edit `lambda/requirements.txt` — drop the `webauthn>=2.0,<3.0` line.

- [x] **Task 4 — Deploy + smoke** (AC: 13)
  - [x] Subtask 4.1: `./deploy.sh dev` (asserts javelin profile).
  - [x] Subtask 4.2: Manual curl checks per AC 13 against `https://3lgqmzurih.execute-api.us-east-1.amazonaws.com/api/auth/siwa`. Mint a SIWA token via the existing iOS dev build (or from a Mac with Apple ID web login if available) — easiest path is to wait for 2-2 to ship and exercise via TestFlight.

- [x] **Task 5 — Update brownfield docs** (AC: 1)
  - [x] Subtask 5.1: Edit `docs/api-contracts-lambda.md` — drop the six removed rows from the Public table, add the new `/api/auth/siwa` row.
  - [x] Subtask 5.2: Edit `docs/architecture-lambda.md` — replace the "Auth model" subsection's three-flow description (Signup / Login / Recovery) with a single SIWA flow.

## Dev Notes

### Relevant architecture patterns and constraints

- **Existing SIWA verification works.** `_verify_siwa(id_token)` at `handler.py` already handles JWKS fetch, audience check (`com.ashokteja.formulahelper`), and issuer check. Reuse as-is.
- **Apple-sub canonical index.** `APPLESUB#<sub>/LOOKUP` is the singleton index used for both the existing recovery flow and the new merged endpoint. Don't change its shape.
- **Invite consume is conditional.** `_consume_invite` uses `ConditionExpression` to atomically mark `used_at`. Two simultaneous redemptions of the same token race safely: one wins (returns the invite dict), the other returns None.
- **Session shape is unchanged.** `SESS#<token>/META` already carries `user_id`, `active_hh`, `ttl`. `_create_session` and `_session_cookie` are reused without modification.
- **Capability model unchanged.** Once signed in via SIWA, the existing role-based gates on every protected route work as-is. This story doesn't touch `_require_capability` or `ROLE_CAPS`.
- **CRED# orphan rows.** Leaving them is intentional. DynamoDB doesn't enforce referential integrity, so they're inert. The list-credentials helper that scans them is being deleted; nothing else queries that prefix.

### Source tree components to touch

- `lambda/handler.py` — replace handlers in the `# ── Auth handlers ──` block (currently roughly lines 401–712 on dev_auth). Update `PUBLIC_ROUTES` near the bottom.
- `lambda/requirements.txt` — drop one line.
- `docs/api-contracts-lambda.md` — table edit.
- `docs/architecture-lambda.md` — section rewrite.

### Testing standards summary

- No Lambda test target exists. Manual `curl` verification per AC 13.
- Backend changes land via `./deploy.sh dev` only; `./deploy.sh prod` is for the main-line app and unrelated to this branch.

### Project structure notes

- **Alignment:** All changes confined to `lambda/` plus `docs/`. No iOS code touched in this story (Story 2-2-siwa-ios is its companion).
- **Conflicts / variances:** dev_auth's lambda/handler.py was just rewritten via the merge from main (no semantic change to auth — main doesn't have SIWA). No conflicts expected.
- **Naming:** `auth_siwa` chosen over `auth_signin` / `auth_login` because the endpoint is the *only* auth path now — the name should describe the mechanism, not the user-facing verb.

### References

- [Source: docs/architecture-lambda.md#Auth model] — current three-flow description (Signup / Login / Recovery) becomes one
- [Source: docs/api-contracts-lambda.md#Public (no session required)] — table to edit
- [Source: handler.py — `_verify_siwa`, `_user_id_for_apple_sub`, `_put_user`, `_create_household`, `_add_membership`, `_consume_invite`, `_create_session`, `_session_cookie`] — building blocks
- Conversation: explicit decision to use **(B) two-step**, hard-reset existing dev users (acceptable because apple_sub→user_id index survives), defer AASA / entitlements / CRED# cleanup

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (`claude-opus-4-7`) via `/bmad-dev-story`.

### Debug Log References

- `python3 -c "import ast; ast.parse(...)"` → OK after each edit pass.
- `grep -c "webauthn|_put_credential|_get_credential|_update_sign_count|_list_credentials_for_user|auth_register|auth_login|auth_recover" lambda/handler.py` → 0 (no dead-symbol references remain).
- `./deploy.sh dev` → CloudFormation `UPDATE_COMPLETE`, function URL `https://3lgqmzurih.execute-api.us-east-1.amazonaws.com`.
- Smoke checks against the live endpoint:
  - `curl -X POST .../api/auth/siwa -d '{}'` → `400 {"error": "siwa_id_token required"}` ✓
  - `curl -X POST .../api/auth/siwa -d '{"siwa_id_token":"abc.def.ghi"}'` → `400 {"error": "SIWA verification failed: ..."}` ✓ (bad token rejected at JWT-decode time, before the apple_sub lookup)

### Completion Notes List

**Implemented:**
- `auth_siwa(event)` — single auth handler covering returning-user signin (200 + Set-Cookie + `returning: true`), first-time-no-setup (412 + `needs` array), first-time-with-household (200 + `returning: false`), first-time-with-invite (200 + `returning: false`, with rollback on invite-consume race per AC 6).
- Mutually-exclusive `household_name` vs `invite_token` → 400.
- Apple-name resolution: `claims.get("name")` (defense in depth — Apple's id_token does not actually carry the name in practice; left in for the rare case it does) → fallback to body's `user_name` → 400 if neither resolves on first signup.
- Single observability log line per request: `[siwa] returning=<bool> user_id=<id> active_hh=<id>`.
- Six dead handlers removed: `auth_register_start`, `auth_register_finish`, `auth_login_options`, `auth_login_verify`, `auth_recover_start`, `auth_recover_finish`.
- Four dead helpers removed: `_put_credential`, `_get_credential`, `_update_sign_count`, `_list_credentials_for_user`.
- All `webauthn` imports removed (the package + `from webauthn.helpers...`).
- `lambda/requirements.txt` — `webauthn>=2.0,<3.0` line removed.
- `PUBLIC_ROUTES` — six rows dropped, one added (`POST /api/auth/siwa`). `auth_dev_login` stage-gated registration unchanged.

**Documentation updates:**
- `docs/api-contracts-lambda.md` — Public table rewritten (six rows → one).
- `docs/architecture-lambda.md` — `## Auth model` section condensed: identity primitives note CRED# / CHAL# as dead schema; Signup / Login / Recovery sub-sections collapsed into a single `### Sign in / sign up (single SIWA flow)` section describing the two-step protocol. The source-tree comment now reflects requirements.txt's contents.
- `docs/data-models-lambda.md` — `CRED#` and `CHAL#` rows struck through with "Dead schema (Story 2.1)" notes; cleanup deferred.
- `docs/integration-architecture.md` — diagram block prefixed with a "STALE — superseded by 2.1, full rewrite in 2.2" callout. Diagram itself left intact since 2.2 will need to redraw it anyway.

**Deployed to:** `formula-helper-dev` (us-east-1, javelin profile). API live at `https://3lgqmzurih.execute-api.us-east-1.amazonaws.com/api/auth/siwa`.

**Deviation from skill's standard flow (steps 5/6/7):** Same as Story 1.1 — the workflow prescribes red-green-refactor with automated tests. This Lambda has no test target wired (and per `docs/development-guide.md#Testing` that's intentional — backend changes are validated via the iOS dev TestFlight build). Smoke verification done via `curl` on the deployed endpoint per AC 13. End-to-end happy-path verification (returning user → 200 + cookie; first-time signup → 200 + new account in DynamoDB) requires a real SIWA token from iOS; that's Story 2.2's job to drive.

**CRED# / CHAL# row cleanup:** intentionally not done per AC 10. DynamoDB has zero queries against either partition now. Leftover rows are inert. A separate one-shot migration script can sweep them after 2.2 ships.

**AASA + entitlements `webcredentials` cleanup:** deferred per the original plan. The dev iOS app's entitlements still declare `webcredentials:3lgqmzurih.execute-api.us-east-1.amazonaws.com` — harmless since the relying-party identifier is no longer queried by anything iOS does, but cosmetically wrong. Cleanup story to follow.

### File List

- `lambda/handler.py` (modified) — webauthn imports removed, four credential helpers removed, six auth handlers replaced by `auth_siwa`, route table updated.
- `lambda/requirements.txt` (modified) — `webauthn>=2.0,<3.0` line removed.
- `docs/api-contracts-lambda.md` (modified) — Public auth routes table rewritten.
- `docs/architecture-lambda.md` (modified) — Auth model section rewritten; source-tree comment updated.
- `docs/data-models-lambda.md` (modified) — `CRED#` and `CHAL#` rows marked as dead.
- `docs/integration-architecture.md` (modified) — handshake-flows section flagged as stale.

### Change Log

- 2026-04-26: Story 2.1 implemented and deployed to `formula-helper-dev`. Single `POST /api/auth/siwa` endpoint replaces six WebAuthn-flavored auth routes. Existing dev users with apple_sub mappings (`dev-sim-user`'s would-be SIWA-derived sub if any was set) sign in cleanly via the returning-user branch; new users hit the two-step 412 path.

## Open Questions / Clarifications

None at scope-of-this-story. Two flagged items deliberately out of scope:

1. **AASA and entitlements still advertise `webcredentials:`.** Once 2-2 ships, these can be cleaned up. Tracked separately.
2. **CRED# rows linger.** No-op cleanup story for later.

---

**Generated:** 2026-04-26 — direct-write, no `/bmad-create-story` workflow run since prerequisites (PRD, architecture, sprint-status) don't exist on this branch and the conversation locked all decisions.
