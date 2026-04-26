# Deferred Work

## Deferred from: code review of story 1-1-role-management-ui (2026-04-24)

Scope of that review was the entire uncommitted dev_auth working tree, not just Story 1.1. These items are real concerns but were triaged as out-of-scope for the current pass.

- **Dev-login accumulates orphan Sim Households over time** — each soft-delete leaks a row. Dev-only; bounded once soft-delete gating (#1 in triage) lands. Revisit only if DynamoDB row count becomes operationally annoying.
- **Household / user / child names unbounded in length + charset** — defensive bound check missing; not exploitable today. Public-release hardening item.
- **Invite `expires` sent as a float Unix timestamp with no client-clock-skew handling** — server enforces; worst case is a cosmetic "Expired" flash on a still-valid token. Cosmetic only.
- **`household_transfer` has no iOS client method yet** — already planned as Story 1.2 in the wrap-up epic. Not a regression.
- **Hard-coded API Gateway + CloudFront hostnames in `ios/project.yml`** — intentional pinning, coupled to RP_ID invariant. Leaving as-is.
- **`InviteShareSheet` copies tokens to `UIPasteboard.general`** — shared with iCloud Universal Clipboard. Sensitive enough to harden (`setItems` with `.localOnly` + expiry). Defer until the auth-hardening pass.
- **`InviteShareSheet.expiresText` does not refresh across expiry / midnight** — cosmetic; server rejects expired tokens on redeem.
- **`InviteCodeSheet` accepts URL-prefixed invite tokens without cleaning** — UX polish.
- **Admin role is essentially non-functional in iOS** — admins have backend caps (`invite`, `kick`) but no UI to exercise. Explicit epic-scoping decision — Story 1.1 is owner-only. Revisit after wrap-up epic closes if admin UX is ever needed.
- **`household_member_update` has no explicit self-demotion guard** — defense in depth; current invariants (single-owner, owner-role-rejection) prevent reaching a state where self-demotion would break things.
