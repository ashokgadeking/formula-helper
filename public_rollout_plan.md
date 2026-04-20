# Public Distribution Plan — AvantiLog

Backend is already serverless (API GW + Lambda + DynamoDB single-table + S3/CloudFront), auth is WebAuthn passkeys with an allowlist. That's the right foundation — the work is mostly hardening for multi-tenant use and App Store compliance.

## Phase 0 — New AWS account for production

Move off the `viper` account so personal projects (Pi, experiments) stay isolated from the product's billing, IAM, and blast radius.

**Account setup**
- Create a new AWS account with a dedicated root email (e.g. `aws-avantilog@...`) + hardware MFA on root, then lock the root away.
- Put both accounts under an AWS Organization so billing rolls up and you can apply SCPs later. Not strictly required for launch, but trivial to do now and painful to retrofit.
- Enable IAM Identity Center (SSO) for day-to-day access instead of IAM users. One permission set for admin, one for read-only.
- Billing: set a budget + alarm at $20/mo and $100/mo. Enable Cost Explorer.
- Enable CloudTrail (all regions) and GuardDuty from day one — both near-free at this scale.

**Infra bootstrap (in the new account)**
- Deploy `template.yaml` via SAM to a single region (us-east-1 — required for ACM certs used by CloudFront).
- Register/transfer a real domain (e.g. `avantilog.app`) in Route 53. Don't ship with the raw CloudFront hostname — it's baked into `RP_ID` for WebAuthn and changing it later invalidates every existing passkey.
- ACM cert for `avantilog.app` + `api.avantilog.app`.
- CloudFront in front of the S3 web bucket; custom domain + cert attached.
- API Gateway custom domain `api.avantilog.app` mapped to the HTTP API.
- Update `RP_ID` / `RP_ORIGIN` in the Lambda env to the new domain **before** any public user registers a passkey.
- Rotate all secrets (`VAPID_PRIVATE_KEY`, any API keys) — don't copy them from `viper`. Store in Secrets Manager, not env vars (see Phase 2).
- Update iOS `associated-domains` entitlement and `apple-app-site-association` to the new domain. Bump build, re-upload to TestFlight from the new App Store Connect API key if you issue one scoped to the prod account's ASC team (ASC team can stay the same — it's Apple-side, not AWS-side).

**Deploy pipeline**
- For now: `sam deploy` from your laptop using an Identity Center profile. GitHub Actions + OIDC role can wait until there's a second committer.
- Tag every resource with `app=avantilog`, `env=prod`.

**Cutover**
- No data migration needed — the `viper` deployment is your personal/dev environment. It keeps running for the Pi.
- The public iOS build points at `api.avantilog.app`; any internal/dev build can stay on the CloudFront hostname in `viper`.

## Phase 1 — Multi-tenancy audit (blocker)

The single-table is keyed `PK/SK`. Before opening signups, verify every read/write in `lambda/handler.py` scopes `PK` by the authenticated user ID. Risks:
- Hardcoded `NTFY_TOPIC: bottle-expiry-1737` is a shared channel — drop ntfy in favor of APNs-only for the iOS app.
- `allowed-users` gate must flip to open-registration (or invite-code) mode.
- Any legacy Pi-mode endpoints / shared API keys must be stripped from the public build's Lambda surface.

## Phase 1.5 — Households & multiple children (feature)

Model shift: data is no longer owned by a single user. It's owned by a **household** (a child, plus up to 5 caretakers). A user can belong to multiple households — e.g. grandparent caring for two grandkids.

**Limits**
- Up to **5 children per account** (primary user).
- Up to **5 caretakers per child** (the primary + 4 invitees).
- A caretaker has full read/write on that child's data. No role tiers in v1 — keep it simple.

**Data model (DynamoDB single-table)**
- `PK=CHILD#<childId>`, `SK=PROFILE` — child metadata (name, DOB, created_by).
- `PK=CHILD#<childId>`, `SK=LOG#<ts>` / `DIAPER#<ts>` / `WEIGHT#<ts>` / `SETTINGS` — child-scoped data (current per-user data re-keyed under the child).
- `PK=CHILD#<childId>`, `SK=MEMBER#<userId>` — caretaker membership + role (`owner` | `caretaker`) + joined_at.
- `PK=USER#<userId>`, `SK=CHILD#<childId>` — reverse index so "list my children" is one query.
- `PK=INVITE#<code>`, `SK=META` — pending invite with childId, inviter, expires_at, TTL.

**Auth/authz**
- Every handler resolves `childId` from the request (path param or active-child header) and checks `MEMBER#<userId>` exists on that child before reading/writing. This replaces today's implicit "PK = the user."
- Primary/owner is the only one who can invite, remove caretakers, or delete the child.

**Invite flow**
- Owner taps "Add caretaker" → server creates `INVITE#<code>` (6-char, 48h TTL) → share link `avantilog://invite/<code>` or universal link.
- Invitee opens app, signs in (passkey), accepts → server writes `MEMBER#` + reverse index, deletes invite.
- Enforce the ≤5 caretakers and ≤5 children caps at accept-time.

**iOS changes**
- Child switcher in the top bar (or in Settings if only one child). Persist `activeChildId` in UserDefaults.
- New "Family" screen under Settings: list caretakers, invite, remove. List children, add, archive.
- Onboarding: first passkey registration creates the user + their first child in one step.
- Live Activity + widget read from `activeChildId`.

**Migration**
- One-shot script: for each existing user, create a `CHILD#<new>` with `name="Baby"`, re-key their logs/diapers/weights/settings under that child, write `MEMBER#<userId>` as owner, write reverse index. Keep old `PK=USER#...` rows for 30 days as rollback insurance, then drop.

**Open questions to decide before building**
- Notifications: when caretaker A logs a feeding, does caretaker B get a push? (Probably yes, opt-out per-caretaker.)
- Conflict handling: two caretakers logging simultaneously — last-write-wins is fine, but show a "logged by <name>" byline on entries.

## Phase 2 — Backend hardening

- Move remaining secrets (e.g. `VAPID_PRIVATE_KEY`) from `template.yaml` env into AWS Secrets Manager.
- Add per-user rate limits (API GW usage plan or Lambda-side).
- Add a DELETE-account endpoint + full data purge (App Store requirement as of 2022).
- CloudWatch alarms on Lambda errors / DDB throttles.
- Backup plan: enable DDB PITR.

## Phase 2.5 — Account recovery

Passkey-only auth is elegant until a user drops their iPhone in a lake. For a parenting app with a year of irreplaceable data, "you're locked out forever" is not acceptable. Recovery is a design decision, not a feature.

**Layered recovery strategy**
1. **iCloud Keychain sync (free, automatic).** Passkeys created on iOS 16+ sync across a user's Apple devices. For most users this is the entire story — lose phone, restore from iCloud, passkey comes back. No action needed on our side beyond making sure we're using platform authenticators (we are).
2. **Sign in with Apple as second auth method.** In addition to passkey at registration, let users link SIWA. Stored as an alternate credential on the user record. If passkey is lost, SIWA gets them back in. Also doubles as the "I don't have a passkey-capable device" fallback from Phase 3.
3. **Caretaker-assisted recovery.** If a household has ≥2 caretakers, any other caretaker can "vouch" for the locked-out owner from their own device. Server marks the user as pending re-registration; a new passkey registered within 24h inherits the old user record. Useful for the common case of "I got a new phone and didn't have iCloud backup on."
4. **Email magic link as last resort.** Optional email on the user record (collected at first sign-in, never required). Magic link to a recovery URL that lets them register a fresh passkey bound to the same user ID. Rate-limited hard.

**What we explicitly don't do**
- No security questions (phishable, forgettable).
- No SMS (SIM-swap attacks, and we don't want to pay Twilio).
- No "export your recovery code and save it somewhere" — parents won't, and we know it.

**Schema additions**
- `PK=USER#<id>`, `SK=AUTH#SIWA#<sub>` — Apple identity link.
- `PK=USER#<id>`, `SK=EMAIL` — optional email, verified.
- `PK=RECOVERY#<token>`, `SK=META` — pending recovery with TTL.

## Phase 3 — iOS app readiness

- Remove dev associated domain (`?mode=developer`) from `FormulaHelper.entitlements` for Release.
- Onboarding flow: passkey create → name baby → done. AuthView currently assumes a known user.
- Sign in with Apple as second credential (per Phase 2.5) — offered during onboarding, not optional past v1.1.
- Add in-app "Delete account" in SettingsView.
- **Offline-first write queue.** Log entries (feeding, diaper, weight) must persist locally and flush when network returns. Covers basements, flaky LTE, and regional AWS hiccups all at once. Use a tiny SQLite or Core Data queue keyed by client-generated UUID; server dedups on that UUID.
- **Data export.** Settings → Export → emails the user a JSON/CSV of their child's data. Required for GDPR, nice for trust.
- Crash reporting (TestFlight gives you this free; consider Sentry for prod).

## Phase 3.5 — Monetization (In-App Purchase)

Gate multi-child behind a paid unlock. Free tier: 1 child + up to 5 caretakers. Paid tier: up to 5 children, caretaker cap unchanged.

**Product decisions**
- **Model:** one-time "Family Pack" unlock at $9.99 (non-consumable IAP). Babies age out of formula tracking in ~12 months, so a subscription feels predatory and churn would be high. Revisit a $4.99/yr "support the app" tier later if AWS costs demand it.
- **Who pays:** only the household owner (child-creator). Caretakers join invited households for free regardless of tier — the invite flow must never become a paywall, or nobody will use it.
- **Grandfathering:** anyone active on v1.0 before the paywall ships keeps multi-child free forever. Track via a server-side `grandfathered: true` flag on the user record. Cheap insurance against "pulled the rug" reviews.
- **Family Sharing:** enable on the IAP in ASC. If one parent buys, the other parent's Apple ID inherits — one checkbox, big goodwill.

**Implementation**
- StoreKit 2 (`Product.products(for:)`, `Transaction.currentEntitlements`). iOS 15+ only, which we already are (deploymentTarget 18.0).
- Client-side: paywall sheet when owner taps "Add child" on a 1-child free account. Restore-purchases button in Settings (App Store requirement).
- Server-side verification: on successful purchase, iOS sends the signed `Transaction` JWS to `/api/iap/verify`. Lambda verifies against Apple's API (`verifyReceipt` is deprecated; use the App Store Server API with a JWT signed by an ASC key) and writes `entitlements: {familyPack: true}` on the user record.
- Enforcement lives on the server: the "create child" handler checks `entitlements.familyPack || childCount < 1` before allowing. Never trust the client — StoreKit can be spoofed on jailbroken devices.
- Webhook: subscribe to App Store Server Notifications v2 for refunds/chargebacks → flip the entitlement off. Endpoint: `/api/iap/webhook`.

**App Store review gotchas**
- The paywall copy must clearly state what's included and the one-time price. No "free trial" wording on a non-consumable.
- Privacy label: add "Purchases" linked to user.
- Cannot gate previously-free features from existing users without grandfathering — hence the flag above.
- Can't offer the unlock outside IAP (no "pay on our website to save 30%") — Apple will reject. Price accordingly knowing Apple takes 30% (15% if you enroll in Small Business Program, which you qualify for).

**Open questions**
- Price point: $9.99 feels right for US; consider regional pricing via ASC price tiers.
- Do caretakers invited to a paid household also see "unlock" prompts if they try to create their own child elsewhere? (Yes — entitlement is per-user, not per-household. Clarify in UX copy.)

## Phase 4 — App Store submission

- Privacy policy + support URL (host on the S3 site).
- Privacy nutrition label: health data (feedings, diapers, weight) → declare "Health & Fitness" data, linked to user, not used for tracking.
- Age rating: 4+.
- Screenshots (6.9", 6.5", iPad if supporting) — home, trends, logs, settings.
- Description + keywords. "AvantiLog" + "baby feeding tracker" etc.
- Export compliance: already `ITSAppUsesNonExemptEncryption: false`.
- Consider HealthKit integration for weight — nice differentiator, adds review scrutiny.

## Phase 4.5 — Legal, compliance, and support

Not the fun part, but every one of these can block the App Store submission or generate regulator mail later.

**Legal documents (host on the public S3 site at `/privacy` and `/terms`)**
- **Privacy Policy.** Must enumerate every data type collected, why, third parties it's shared with (AWS only, as a processor), retention, user rights (access, deletion, export), and a contact address. Don't copy someone else's — it'll be wrong for your stack. Termly or iubenda generate decent boilerplate for $10–30/mo if you don't want to write it from scratch.
- **Terms of Service.** Acceptance on first sign-in. Include: medical disclaimer ("not medical advice, consult a pediatrician"), account termination rights, arbitration clause, governing law.
- **EULA.** Apple's standard EULA is fine unless you want custom terms — don't.

**Compliance**
- **COPPA (US).** The app is used *by* parents *about* children, so it's adjacent to COPPA but not directly subject to it as long as we do not knowingly collect data from users under 13. Still: add a ToS clause requiring users to be 18+, and don't build features that would invite child users (e.g. no "share with your toddler" nonsense).
- **HIPAA.** Does *not* apply — we're not a covered entity. Don't accidentally claim it in marketing copy.
- **GDPR / UK GDPR.** If you accept EU users (which the App Store will let you by default), you need: lawful basis (consent, captured at signup), DPA with AWS (standard, already in your account agreement), right to access/delete/export, cookie banner on the web marketing site if you add analytics. Appoint yourself as DPO; with <250 employees you don't need a formal one.
- **CCPA (California).** Similar to GDPR. The same delete/export endpoints cover both.
- **Apple Health data handling.** If Phase 4's HealthKit integration ships, Apple's review will scrutinize the privacy policy for explicit mention of health data handling.

**Support infrastructure**
- `support@avantilog.app` — real inbox you check. Gmail with a label is fine at launch.
- In-app "Contact support" in Settings → opens `mailto:` with user ID + app version pre-filled in the body. Saves you five emails of back-and-forth per ticket.
- Simple FAQ page on the marketing site covering: how to add caretakers, how to restore purchase, how to recover account, how to delete account, refund policy.
- Refund policy: Apple handles IAP refunds; your policy is "contact Apple Support or reply and we'll help you file." Don't try to refund yourself — you can't, the money already went through Apple.
- SLA: none promised publicly. Target 48h response.

## Phase 5 — Rollout

1. TestFlight external beta (up to 10k testers, no review for internal, light review for external) — get 10–20 parents.
2. Fix feedback, submit for App Store review.
3. Soft launch (no marketing) — watch costs, error rates.
4. Public.

## Cost sanity check

At current scale, DDB on-demand + Lambda + API GW is ~$0 for <1k users. CloudFront egress is the risk if you host web assets publicly. Set a billing alarm at $20/mo before launch.

## Recommended first step

Audit `lambda/handler.py` for `PK` scoping — this is the only thing that's existentially dangerous. Everything else is polish.
