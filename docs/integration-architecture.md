# Integration Architecture

```
┌─────────────────────────┐                 ┌──────────────────────────────────────────┐
│        iOS app          │                 │                 AWS                      │
│  (AvantiLog / ... Dev)  │   HTTPS JSON    │                                          │
│                         │  ────────────▶  │  CloudFront (prod only)                  │
│  APIClient.swift        │                 │      └──▶ API Gateway HTTP API           │
│  cookie-based session   │  ◀────────────  │             └──▶ Lambda (handler.py)     │
│                         │                 │                   ├── boto3 ──▶ DynamoDB │
│  ASAuthorization:       │                 │                   └── JWKS  ──▶ Apple    │
│   - SIWA (signup/recov) │                 │                         (appleid.apple.com)
│   - Platform passkey    │                 │                                          │
└─────────────────────────┘                 └──────────────────────────────────────────┘
```

## Transport

- TLS 1.2+, JSON request + response.
- Cookies for session (`URLSession.shared` default cookie jar on iOS). There is no bearer-token mode.
- Content-Type: `application/json` on POST/PUT; GET bodies ignored.

## Host / RP mapping

The WebAuthn Relying Party ID **must equal the API host the iOS client talks to** — passkeys are scoped to the RP ID and will silently fail if there's a mismatch.

| Environment | API base URL | RP ID (iOS Info.plist + Lambda env) |
|---|---|---|
| Prod | `https://d20oyc88hlibbe.cloudfront.net` | `d20oyc88hlibbe.cloudfront.net` |
| Dev  | `https://3lgqmzurih.execute-api.us-east-1.amazonaws.com` | `3lgqmzurih.execute-api.us-east-1.amazonaws.com` |

The iOS app picks the pair via build configuration (`Debug` / `DevRelease` / `Release`) — see `architecture-ios.md` for the config table.

## Handshake flows

> **STALE as of Story 2.1.** The passkey + register/login/recover handshake described below was replaced by a single SIWA-only `POST /api/auth/siwa` endpoint. See `architecture-lambda.md#Sign in / sign up (single SIWA flow)` for the current model. Story 2.2 will rewrite this section once the iOS side ships.

### Passkey sign-in (legacy — superseded)

```
iOS                            Lambda                         Apple authenticator
 │  POST /api/auth/login/options  │                               │
 │  ─────────────────────────────▶│                               │
 │                                │  create challenge, store CHAL# │
 │  {challenge_id, options}       │                               │
 │  ◀─────────────────────────────│                               │
 │  ASAuthorization assertion     │                               │
 │  ─────────────────────────────────────────────────────────────▶│
 │  signed assertion              │                               │
 │  ◀─────────────────────────────────────────────────────────────│
 │  POST /api/auth/login/verify   │                               │
 │  ─────────────────────────────▶│                               │
 │                                │  verify, pop CHAL, update     │
 │                                │  sign count, write SESS#      │
 │  Set-Cookie: session=...       │                               │
 │  {ok, user_id, active_hh}      │                               │
 │  ◀─────────────────────────────│                               │
```

### Signup (new user, new household)

```
iOS SIWA sheet ──▶ siwa_id_token
     │
     ▼
POST /api/auth/register/start  {siwa_id_token, user_name, household_name, child_name, child_dob}
     │
     │  Lambda verifies SIWA (JWKS from appleid.apple.com), creates USER + APPLESUB + HH + owner MEMBER,
     │  issues WebAuthn registration challenge
     ▼
{challenge_id, options}
     │
     ▼
ASAuthorization registration ──▶ attestation
     │
     ▼
POST /api/auth/register/finish  {challenge_id, credential}
     │
     │  Lambda verifies attestation, stores CRED, issues session
     ▼
Set-Cookie + {ok, user_id, active_hh}
```

Variations:
- **Join with invite**: same flow, but `register/start` body includes `invite_token` and omits `household_name` / `child_*`. Lambda consumes the invite + adds the caller as a member of the existing household.
- **Recovery**: SIWA id_token → `recover/start` looks up `APPLESUB#<sub>` → recover/finish adds a new passkey to the existing user. No new user, no new household.

## Cross-cutting concerns

### Idempotency

- Invites: `_consume_invite` conditional update on `used_at = ''`. Safe against double-tap.
- Feedings / diapers / naps: SK is unique (`<kind>#<ts>_<rand>`). Retries at the transport layer produce duplicates.

### Clock trust

- Session TTL, challenge TTL, invite TTL are all server-side (`_now()` using server time). iOS clock is not trusted.
- Bottle countdown uses a server-set `countdown_end` epoch; iOS displays `remaining_secs` computed server-side in `/api/state`.

### Error surface

iOS `APIClient` decodes `{error: string}` and surfaces `error.localizedDescription` to the UI. Backend returns HTTP 4xx/5xx with that shape; transport-level failures (offline, TLS) bubble up as `URLError`.

### Push notifications

Not wired. Parked in `TODO.md` → Household. When added, APNs registration goes via `UNUserNotificationCenter` + a new `/api/devices/register` endpoint storing `DEVICE#<token>` records on the user, and Lambda sends via APNs HTTP/2 directly (no SNS). See the TODO entry for the two flavors (in-app vs APNs) still to decide.

### App Check / attestation

Not implemented. The backend trusts that requests come from the iOS app via cookie session; there is no device attestation. This is acceptable for the current audience but is a pre-public-launch item.
