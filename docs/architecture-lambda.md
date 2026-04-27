# Architecture — Lambda (`lambda/`)

## Executive summary

Single Python 3.12 Lambda function, `lambda/handler.py`, behind an HTTP API Gateway. All routes dispatch off `(method, rawPath)` through two tables (`PUBLIC_ROUTES`, `PROTECTED_ROUTES`) matched by `re.match` against regex path patterns. Session enforcement happens inside each protected handler via `_require_session`. Data lives in a single DynamoDB table (`FormulaHelper`) using a PK/SK composite key design — no GSIs currently.

Prod CloudFront sits in front of API Gateway for custom-domain serving and RP-ID stability. Dev skips CloudFront and hits API Gateway directly.

## File layout

```
lambda/
├── handler.py              # 1438 lines — entire backend
└── requirements.txt        # pyjwt[crypto]>=2.8,<3.0   (was webauthn + pyjwt; webauthn dropped in Story 2.1)
```

Boto3 is implicit (provided by the Lambda runtime).

## Dispatcher

```
lambda_handler(event, context)
  ├── method = event.requestContext.http.method
  ├── path   = event.rawPath
  ├── _match_route(PUBLIC_ROUTES, method, path)      # returns handler + named captures
  │    └── dispatch(handler, params)                 # injects event.pathParameters
  ├── _match_route(PROTECTED_ROUTES, method, path)
  │    └── dispatch(handler, params)                 # each handler calls _require_session
  └── fallthrough → 404
```

`dispatch()` wraps the call in try/except and returns a JSON 500 with `str(e)` on any unhandled exception (plus a stack trace to CloudWatch).

See `api-contracts-lambda.md` for the full route list.

## Auth model

### Identity primitives

- **`USER#<uid>` / `PROFILE`** — canonical user record (`user_id`, `apple_sub`, `name`, `email`, `created_at`).
- **`APPLESUB#<apple_sub>` / `LOOKUP`** — reverse index from the Apple-issued subject to the user_id; canonical lookup for both signin and signup.
- **`SESS#<token>` / `META`** — session record with TTL (`SESSION_TTL_SECS = 30 days`). `active_hh` is mutable on the session.

Pre-Story-2.1 the auth model also had `CRED#<cred_id_b64>` / `CRED` (passkey credentials) and `CHAL#<challenge_id>` / `<purpose>` (one-shot WebAuthn challenges). Both partitions are now dead — the table may still hold orphan `CRED#` rows from earlier signups but nothing reads them. Cleanup is deferred.

### Sign in / sign up (single SIWA flow)

There is exactly one auth endpoint: `POST /api/auth/siwa`. Two-step protocol from the client's perspective:

**Step 1 — bare token:** client posts `{siwa_id_token}`. Server verifies the token via `_verify_siwa` (JWKS from `https://appleid.apple.com/auth/keys`, audience `com.ashokteja.formulahelper`), reads `claims["sub"]`, and looks up `APPLESUB#<sub>`.

- **Returning user (apple_sub maps to a user_id):** issues a session cookie, returns `200 {ok, user_id, active_hh, returning: true}`. `active_hh` is the user's first remaining membership (or `null` if they were kicked from everywhere).
- **First-time (no apple_sub mapping yet):** returns `412 Precondition Required` with `{error: "Setup required", returning: false, needs: ["user_name", "household_name_or_invite_token"]}`. No cookie, no user created.

**Step 2 — full setup:** client re-posts `{siwa_id_token, user_name, household_name OR invite_token, child_name?, child_dob?}` (same id_token reused — SIWA tokens are short-lived but valid for several minutes, plenty of time to fill a form). Server creates `USER#<uid>` + `APPLESUB#<sub>`, creates the household (or consumes the invite + adds membership), issues a session cookie, returns `200 {ok, user_id, active_hh, returning: false}`.

Edge cases handled in `auth_siwa`:
- Both `household_name` and `invite_token` set → `400`.
- Invite-consume races with another redemption → `409` and rolls back the just-created user/applesub rows so no orphans linger.
- Apple's id_token does not normally include the user's name (delivered out-of-band on the iOS side via `ASAuthorizationAppleIDCredential.fullName`). Server tries `claims.get("name")` as defense in depth, falls back to body's `user_name`. Empty resolved name on first signup → `400`.

### Recovery

Identical to sign-in. The user re-authorizes with Apple, server matches `apple_sub` → existing `user_id`, session issued. No separate "recovery" code path.

### Capability model

```python
ROLE_CAPS = {
  "owner":  {"invite", "kick", "change_role", "transfer_ownership", "delete_household", "log", "leave"},
  "admin":  {"invite", "kick", "log", "leave"},
  "member": {"log", "leave"},
}
```

`_require_capability(session, hh_id, action)` is the gate on household-scoped mutations. Note the backend enforces per-household roles — an owner of household A has no elevated rights in household B.

## Household data model

- **`HH#<hid>` / `META`** — household metadata (name, owner_uid, child_name, child_dob).
- **`HH#<hid>` / `SETTINGS`** — countdown_secs, preset1_ml, preset2_ml, ss_timeout_min. Defaults are written at household creation.
- **`HH#<hid>` / `MEMBER#<uid>`** — mirror record for member lookups (role, joined_at).
- **`USER#<uid>` / `HH#<hid>`** — forward record for "what households am I in" queries (role, hh_name, joined_at).

Every membership mutation writes **both** the forward and mirror records (`_add_membership`, `_remove_membership`, `_update_membership_role`). If they ever diverge, data becomes inconsistent — keep this invariant in mind when adding new mutations.

## Event data (per household)

- **`HH#<hid>` / `FEED#<ts>_<rand>`** — feeding entry (`ml`, `leftover`, `text`, `date`, `created_by`).
- **`HH#<hid>` / `DIAPER#<ts>_<rand>`** — `type` ∈ {`pee`, `poo`}.
- **`HH#<hid>` / `NAP#<ts>_<rand>`** — `duration_mins`.
- **`HH#<hid>` / `WEIGHT#<date>`** — weight entry (`lbs`).
- **`HH#<hid>` / `TIMER`** — current running bottle state (mixed_at, mixed_ml, countdown_end, ntfy_sent).
- **`HH#<hid>` / `INVITE#<token>`** *(actually stored under `INVITE#<token>`/`META` at the top level, see below)* — invite tokens.

### Invites

- **`INVITE#<token>` / `META`** — `hh_id`, `hh_name`, `inviter_uid`, `expires`, `used_at`, `ttl`. 7-day default TTL. `_consume_invite` uses a conditional update to atomically mark `used_at`, preventing double-redemption.

## Known DynamoDB scan points (cost/scale watch-list)

- `_list_credentials_for_user` uses a `scan + filter`. Fine at dev volume; add a GSI on `user_id` before public launch.
- No other scans present in the protected path.

## Environment variables

Set via SAM `template.yaml` / `template-dev.yaml`. Values (including `PI_API_KEY`, `VAPID_*`) currently live in the templates themselves — treat them as secrets and do not copy them into this documentation set. Prod and dev have separate values.

| Var | Purpose |
|---|---|
| `TABLE_NAME` | DynamoDB table (prod: `FormulaHelper`, dev: `FormulaHelper-dev`) |
| `RP_ID`, `RP_ORIGIN` | WebAuthn relying party — must match the API host seen by the client |
| `SIWA_AUDIENCE` | `com.ashokteja.formulahelper` (same value in both stacks; SIWA audience is the bundle id) |
| `STAGE` | `dev` or `prod` |
| `NTFY_TOPIC`, `VAPID_*`, `PI_API_KEY` | legacy/Pi — unused by the public iOS app |

## Testing

There is no Lambda-side unit test suite in the documented scope; `tests/` is Pi-only. Backend changes are validated via `./deploy.sh dev` + iOS DevRelease TestFlight testing.
