# Data Models — DynamoDB

Single-table design. Table name is `FormulaHelper` (prod) or `FormulaHelper-dev` (dev). Composite primary key: `PK` (hash) + `SK` (range). `AttributeDefinitions` only declares `PK` and `SK`; all other fields are schemaless.

No GSIs today. One scan-with-filter exists (`_list_credentials_for_user`) — tolerable at dev volume, add a GSI on `user_id` before public launch.

## Item catalog

| PK pattern | SK pattern | What it is |
|---|---|---|
| `USER#<uid>` | `PROFILE` | Canonical user profile: `user_id`, `apple_sub`, `name`, `email`, `created_at` |
| `USER#<uid>` | `HH#<hid>` | Forward membership: `hh_id`, `hh_name`, `role`, `joined_at` |
| `APPLESUB#<sub>` | `LOOKUP` | Reverse SIWA lookup: `user_id` |
| ~~`CRED#<cred_id_b64>`~~ | ~~`CRED`~~ | **Dead schema (Story 2.1).** Formerly the passkey credential record. Orphan rows may exist; nothing reads them. Cleanup deferred. |
| `SESS#<token>` | `META` | Session: `user_id`, `active_hh`, `ttl`, `created_at` (TTL = 30 days, enforced via DynamoDB TTL on `ttl`) |
| ~~`CHAL#<cid>`~~ | ~~`<purpose>`~~ | **Dead schema (Story 2.1).** Formerly one-shot WebAuthn challenges; not written by any handler now. |
| `HH#<hid>` | `META` | Household: `hh_id`, `name`, `owner_uid`, `child_name`, `child_dob`, `created_at` |
| `HH#<hid>` | `SETTINGS` | Per-household settings: `countdown_secs`, `preset1_ml`, `preset2_ml`, `ss_timeout_min` |
| `HH#<hid>` | `MEMBER#<uid>` | Mirror membership: `user_id`, `role`, `joined_at` |
| `HH#<hid>` | `TIMER` | Current running bottle: `mixed_at`, `mixed_ml`, `countdown_end`, `ntfy_sent` |
| `HH#<hid>` | `FEED#<ts>_<rand>` | Feeding entry: `ml`, `leftover`, `text`, `date`, `created_by` |
| `HH#<hid>` | `DIAPER#<ts>_<rand>` | Diaper: `type` (`pee`/`poo`), `date`, `created_by` |
| `HH#<hid>` | `NAP#<ts>_<rand>` | Nap: `date`, `duration_mins`, `created_by` |
| `HH#<hid>` | `WEIGHT#<date>` | Weight log point: `date`, `lbs` |
| `INVITE#<token>` | `META` | Invite token: `hh_id`, `hh_name`, `inviter_uid`, `created_at`, `expires`, `ttl`, `used_at` |

## Key access patterns

| Pattern | How |
|---|---|
| "What households am I in?" | `Query PK=USER#<uid> AND SK begins_with HH#` |
| "Who are the members of household H?" | `Query PK=HH#<hid> AND SK begins_with MEMBER#` |
| "All events for household H since date D" | `Query PK=HH#<hid>` (no SK filter, client paginates and filters by prefix) or `SK begins_with FEED#` etc. as needed |
| "Who does this passkey belong to?" | `Get PK=CRED#<cred_id>, SK=CRED` |
| "Who does this Apple sub map to?" | `Get PK=APPLESUB#<sub>, SK=LOOKUP` |
| "Is this session valid?" | `Get PK=SESS#<token>, SK=META` |

## Invariants (do not violate)

1. **Every membership mutation writes both forward + mirror records.** See `_add_membership`, `_remove_membership`, `_update_membership_role` in `handler.py`. If these diverge, lists of households and lists of members will disagree.
2. **Invites are single-use.** `_consume_invite` uses a conditional `used_at = ''` update to atomically mark an invite used. Never bypass this.
3. **Sessions respect DynamoDB TTL.** The `ttl` attribute drives expiry; don't write sessions without it.
4. **Challenges are one-shot.** `_pop_challenge` deletes on use and also rejects expired challenges. Don't read without popping.
5. **Owner cardinality = 1 per household.** Transfer flips caller to admin in the same transaction-ish flow. If you add new code paths, preserve this.

## Migration notes

There are no migration scripts checked in for the current schema (it was greenfield for this repo). If you change the shape of any item, either:

- Add new fields and keep old ones until a backfill runs, or
- Write a one-off migration script invoked manually. There is a `migrate.py` in the repo root but it was for the Pi era — do not reuse without reading it end-to-end.
