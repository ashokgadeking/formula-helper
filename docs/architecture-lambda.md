# Architecture — Lambda (`lambda/`)

## Executive summary

Single Python 3.12 Lambda function, `lambda/handler.py`, behind an HTTP API Gateway. All routes dispatch off `(method, rawPath)` through two tables (`PUBLIC_ROUTES`, `PROTECTED_ROUTES`) matched by `re.match` against regex path patterns. Session enforcement happens inside each protected handler via `_require_session`. Data lives in a single DynamoDB table (`FormulaHelper`) using a PK/SK composite key design — no GSIs currently.

Prod CloudFront sits in front of API Gateway for custom-domain serving and RP-ID stability. Dev skips CloudFront and hits API Gateway directly.

## File layout

```
lambda/
├── handler.py              # 1438 lines — entire backend
└── requirements.txt        # webauthn>=2.0,<3.0  ; pyjwt[crypto]>=2.8,<3.0
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
- **`APPLESUB#<apple_sub>` / `LOOKUP`** — reverse index for SIWA recovery.
- **`CRED#<cred_id_b64>` / `CRED`** — passkey credential (public key + sign count).
- **`SESS#<token>` / `META`** — session record with TTL (`SESSION_TTL_SECS = 30 days`). `active_hh` is mutable on the session.
- **`CHAL#<challenge_id>` / `<purpose>`** — one-shot WebAuthn challenge with 5-min TTL, deleted on use.

### Signup (new account)

1. Client does SIWA, passes `siwa_id_token` to `POST /api/auth/register/start`.
2. Handler verifies SIWA via `_verify_siwa` (JWKS from `https://appleid.apple.com/auth/keys`, audience = `com.ashokteja.formulahelper`).
3. Creates `USER#<uid>` + `APPLESUB#<sub>` (if not already present), creates the household (or joins via `invite_token`), issues a WebAuthn registration challenge, returns `{challenge_id, options}`.
4. Client runs the platform authenticator registration, posts the attestation to `POST /api/auth/register/finish`.
5. Handler verifies attestation with `py-webauthn`, stores the credential, issues a session cookie, returns `{ok, user_id, active_hh}`.

### Login (returning user)

1. `POST /api/auth/login/options` — resident-key discovery, no `allowCredentials`. Returns `{challenge_id, options}`.
2. Client does platform assertion.
3. `POST /api/auth/login/verify` — verifies, updates sign count, issues session.

### Recovery

Same as signup but keyed on the existing `APPLESUB` → user id, registers a new passkey for the existing account. Does not create a new user.

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
