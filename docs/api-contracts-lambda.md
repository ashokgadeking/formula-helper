# API Contracts — Lambda

All routes are matched in order against `PUBLIC_ROUTES` first, then `PROTECTED_ROUTES`. Path parameters use `(?P<name>...)` named captures and are injected into `event.pathParameters`. Bodies are JSON. Session is read from the cookie set on login.

Base URLs:
- **Prod:** `https://d20oyc88hlibbe.cloudfront.net`
- **Dev:**  `https://3lgqmzurih.execute-api.us-east-1.amazonaws.com`

## Public (no session required)

| Method | Path | Handler | Purpose |
|---|---|---|---|
| GET | `/.well-known/apple-app-site-association` | `apple_app_site_association` | SIWA / universal links association JSON |
| GET | `/apple-app-site-association` | `apple_app_site_association` | Legacy mirror of the above |
| GET | `/api/auth/status` | `auth_status` | Returns `{authenticated, user_id?, user_name?, active_hh?}` for the current cookie |
| POST | `/api/auth/siwa` | `auth_siwa` | Body: `{siwa_id_token, user_name?, household_name?, child_name?, child_dob?, invite_token?}`. Two-step: returning user → 200 `{ok, user_id, active_hh, returning: true}` + Set-Cookie. First-time without setup → 412 `{error: "Setup required", returning: false, needs: [...]}`. First-time with `household_name` or `invite_token` → 200 + session cookie + `{returning: false}`. `household_name` and `invite_token` are mutually exclusive (400 if both). |
| POST | `/api/auth/logout` | `auth_logout` | Clears session. |
| POST | `/api/auth/dev-login` | `auth_dev_login` | Dev-stack-only bypass. Not wired in prod templates. |
| GET | `/api/invites/{token}` | `invite_preview` | Returns `{hh_name, inviter_name, expires}`. Used by iOS before redeem. |

## Protected (session + capability checks inside handler)

### Households

| Method | Path | Handler | Capability | Body / Notes |
|---|---|---|---|---|
| GET | `/api/households` | `households_list` | — | Returns `{active_hh?, households: [{hh_id, name, role}]}` |
| POST | `/api/households` | `households_create` | — | Body: `{name}`. Creates + makes the caller owner. |
| POST | `/api/households/switch` | `households_switch` | — | Body: `{hh_id}`. Must be a member. Sets session.active_hh. |
| GET | `/api/households/{hh_id}/members` | `household_members_list` | member | Returns `{members: [{user_id, name, role, joined_at}]}`. |
| PUT | `/api/households/{hh_id}/members/{user_id}` | `household_member_update` | owner only (`change_role`) | Body: `{role}`. `role ∈ {admin, member}`. Cannot demote owner directly. |
| DELETE | `/api/households/{hh_id}/members/{user_id}` | `household_member_remove` | owner or admin (`kick`) | Kick a member. Cannot target yourself or the owner. Admins cannot kick other admins. |
| POST | `/api/households/{hh_id}/leave` | `household_leave` | any member (`leave`) | Owner must transfer or delete first (returns 400). |
| POST | `/api/households/{hh_id}/transfer` | `household_transfer` | owner (`transfer_ownership`) | Body: `{user_id}`. Promotes target to owner, demotes caller to admin. |
| DELETE | `/api/households/{hh_id}` | `household_delete` | owner (`delete_household`) | |

### Invites

| Method | Path | Handler | Capability | Notes |
|---|---|---|---|---|
| POST | `/api/invites` | `invite_create` | owner/admin (`invite`) | Returns `{token, expires, hh_name}`. 7-day TTL. |
| POST | `/api/invites/{token}/redeem` | `invite_redeem` | — | Body is empty. Idempotency via conditional `used_at`. Returns `{ok, hh_id, hh_name}`. |

### State + feedings

| Method | Path | Handler | Notes |
|---|---|---|---|
| GET | `/api/state` | `get_state` | Returns current bottle, last N feedings, diapers, naps, weight log, settings, combos. Scoped to `session.active_hh`. |
| POST | `/api/start` | `post_start_feeding` | Body: `{ml}`. Starts a countdown for a new bottle. |
| POST | `/api/feedings` | `post_feeding` | Body: `{ml, date?}`. Logs a completed feed (optionally backfilled). |
| PUT | `/api/feedings/{sk}` | `put_feeding` | Body: `{text?, leftover?, ml?, date?}`. Edit an existing entry. |
| DELETE | `/api/feedings/{sk}` | `delete_feeding` | |

### Diapers

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/diapers` | `post_diaper` | Body: `{type, date?}`. `type ∈ {pee, poo}`. |
| PUT | `/api/diapers/{sk}` | `put_diaper` | Body: `{type?, date?}`. |
| DELETE | `/api/diapers/{sk}` | `delete_diaper` | |

### Naps

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/naps` | `post_nap` | Body: `{date, duration_mins}`. |
| PUT | `/api/naps/{sk}` | `put_nap` | |
| DELETE | `/api/naps/{sk}` | `delete_nap` | |

### Settings + timer

| Method | Path | Handler | Notes |
|---|---|---|---|
| POST | `/api/settings` | `post_settings` | Body: subset of `{countdown_secs, preset1_ml, preset2_ml, ss_timeout_min}`. |
| POST | `/api/reset-timer` | `post_reset_timer` | Clears current bottle state. |

## Error conventions

- `401 {"error": "Unauthorized"}` — no session or expired.
- `403 {"error": "Forbidden"}` — session valid but not a member, or role lacks capability.
- `400 {"error": "..."}` — invalid body / business rule violation (e.g. owner trying to leave).
- `404 {"error": "Unknown route: ..."}` — router fallthrough.
- `500 {"error": "<str(e)>"}` — unhandled exception (stack trace in CloudWatch).

## iOS client surface

`ios/FormulaHelper/Networking/APIClient.swift` has a typed method per route. When adding a backend route, add a matching method there and a Codable response struct in `ios/FormulaHelper/Models/AppState.swift`.
