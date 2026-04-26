# Story 1.1: Role management UI (owner promotes / demotes members)

Status: review

**Epic:** 1 — Household feature wrap-up
**Story ID:** 1.1
**Story Key:** 1-1-role-management-ui

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a **household owner**,
I want to **promote a member to admin or demote an admin back to member from the household detail screen**,
so that **I can delegate invite/kick powers without giving up ownership, and revoke them when no longer needed**.

## Acceptance Criteria

1. **Backend already present (no change).** `PUT /api/households/{hh_id}/members/{user_id}` with body `{role: "admin"|"member"}` is implemented at `lambda/handler.py:784-807`. Role `"owner"` must be rejected (existing behavior). Owner role can only be changed via `/transfer`.
2. **Gated on capability.** The change-role affordance appears only when the current user's role for the viewed household is `owner`. Non-owners (admins, members) see **no** role-change UI. Enforced client-side for UX; backend enforces via `_require_capability(session, hh_id, "change_role")`.
3. **Gated per row.** The affordance is hidden on rows where the target is the owner (backend rejects) or the caller themselves (no self-mutation makes sense here). Uses the same predicate shape as the existing `canKick` — mirror it into `canChangeRole`.
4. **Tap-to-open affordance is visually distinct.** Eligible rows render a trailing chevron (iOS disclosure convention, e.g. `"chevron.right"`). Ineligible rows render no chevron. The existing `"chevron.left"` swipe hint is removed; the footer text is updated to cover both interactions (see AC 9).
5. **Confirmation via `.confirmationDialog`.** Tapping an eligible row presents a dialog titled "Change role for {name}" with actions:
   - If target role is `admin`: "Make member" (destructive-style not required; use default).
   - If target role is `member`: "Make admin".
   - "Cancel" (role `.cancel`).
   There is **no** "Make owner" option in this flow.
6. **Pessimistic update.** On dialog confirmation, call `APIClient.updateMemberRole(hhId:, userId:, role:)`. On HTTP 2xx, mutate the local `members` array in place (update the matching `HouseholdMember.role`) and re-run `HouseholdDetailView.sortMembers(_:)` so the list reflows (admins sort before members).
7. **Error path.** On failure, set the existing `membersError` state so the Members section footer displays the error. Do not optimistically mutate the array.
8. **Swipe-to-remove unchanged.** The `.swipeActions` trash-can path (story-complete as of build 36) must continue to work for the same gated rows. No regression.
9. **Footer hint updated.** When the owner has at least one eligible row, the Members footer reads:
   > Tap a member to change their role. Swipe left to remove them.
   Replaces the current "Swipe left on a member to remove them." Keep the `"hand.draw.fill"` glyph prefix.
10. **No new backend route, no new Lambda deploy.** Pure iOS change. Ship via `/testflight-release dev` when done.

## Tasks / Subtasks

- [x] **Task 1 — APIClient method** (AC: 1, 6, 7)
  - [x] Subtask 1.1: Add `func updateMemberRole(hhId: String, userId: String, role: String) async throws` to `ios/FormulaHelper/Networking/APIClient.swift`, alongside `kickMember`.
  - [x] Subtask 1.2: Use the existing `put(...)` helper with body `["role": role]`. Path: `/api/households/\(encodePathComponent(hhId))/members/\(encodePathComponent(userId))`. Follow the same pattern as `kickMember` — no return payload, throws on non-2xx.
- [x] **Task 2 — Gating predicate** (AC: 2, 3)
  - [x] Subtask 2.1: In `HouseholdDetailView` (in `ios/FormulaHelper/Views/SettingsView.swift`), add `private func canChangeRole(_ m: HouseholdMember) -> Bool` right next to `canKick`. Copy the same three checks: `isOwner`, `m.role.lowercased() != "owner"`, `m.user_id != auth.authState.userId`.
- [x] **Task 3 — Row chevron swap** (AC: 4)
  - [x] Subtask 3.1: In `memberRow(_:)`, remove the existing `canKick(m)` → `"chevron.left"` image block.
  - [x] Subtask 3.2: Add a `canChangeRole(m)` → `"chevron.right"` image block with the same styling (`font(.system(size: 11, weight: .semibold))`, `foregroundColor(Color.tertiaryLabel)`).
- [x] **Task 4 — Tap + confirmation dialog** (AC: 5)
  - [x] Subtask 4.1: Add `@State private var memberForRoleChange: HouseholdMember?` to `HouseholdDetailView` (near `memberToKick`).
  - [x] Subtask 4.2: Wrap `memberRow(m)` in a `Button { if canChangeRole(m) { memberForRoleChange = m } } label: { memberRow(m) }.buttonStyle(.plain).disabled(!canChangeRole(m))` inside the `ForEach`. Preserve `.listRowBackground(Color.elevatedBackground)` and the `.swipeActions { ... }` modifier.
  - [x] Subtask 4.3: Attach a second `.confirmationDialog` to `membersSection` (next to the existing `memberToKick` dialog) using `presenting: memberForRoleChange`. Title: `"Change role for \(m.name.isEmpty ? "member" : m.name)"`. Button label computed from `m.role.lowercased()`. Cancel resets `memberForRoleChange` to nil.
- [x] **Task 5 — Action + state update** (AC: 6, 7)
  - [x] Subtask 5.1: Add `private func changeRole(_ member: HouseholdMember, to newRole: String) async` modeled on `kick(_:)`:
    ```swift
    memberForRoleChange = nil
    do {
        try await APIClient.shared.updateMemberRole(hhId: household.hh_id, userId: member.user_id, role: newRole)
        if let idx = members.firstIndex(where: { $0.user_id == member.user_id }) {
            members[idx] = HouseholdMember(user_id: member.user_id, name: member.name, role: newRole, joined_at: member.joined_at)
        }
        members = HouseholdDetailView.sortMembers(members)
        membersError = nil
    } catch {
        membersError = error.localizedDescription
    }
    ```
- [x] **Task 6 — Footer hint rewrite** (AC: 9)
  - [x] Subtask 6.1: In `membersSection`'s `footer:` branch, replace the single-line copy with the new two-sentence version. Keep the `"hand.draw.fill"` icon + `HStack` layout.
  - [x] Subtask 6.2: Visibility rule: show the hint when at least one row in `members` returns `true` from `canChangeRole` **or** `canKick`.
- [x] **Task 7 — Manual verification** (AC: all) — deferred to human reviewer
  - [x] Subtask 7.1: Build Debug on simulator — **compiled cleanly with `xcodebuild … Debug build` (no errors, no new warnings).** Interactive verification requires a human in the loop; see Completion Notes.
  - [ ] Subtask 7.2: On device (dev TestFlight), sign in as an admin in a household you don't own — verify no chevron, no tap response, no dialog; swipe-to-kick still works where the admin role permits. **(Requires human + second test account; cannot be automated.)**
  - [ ] Subtask 7.3: Sign in as a plain member — only Danger Zone's Leave is available; Members list has no affordances. **(Requires human + second test account.)**
  - [ ] Subtask 7.4: Trigger a network failure (e.g. airplane mode mid-call) and confirm the error surfaces in the Members footer without a state mismatch. **(Requires human device interaction.)**

## Dev Notes

### Relevant architecture patterns and constraints

- **Capability model** (`lambda/handler.py:164-180`): `change_role` is owner-only. Admin has `{"invite", "kick", "log", "leave"}` — no role management. The UI gate must match this exactly.
- **Backend rejection surface**: `PUT /members/{user_id}` returns 400 if `role == "owner"` (explicit guard), 400 if role not in `ROLE_CAPS`, and 400 if target is currently owner (cannot demote without transfer). Do not provide UI affordances that would trigger any of these.
- **Both-side DynamoDB invariant**: `_update_membership_role` writes both the forward (`USER#<uid>/HH#<hid>`) and mirror (`HH#<hid>/MEMBER#<uid>`) records in the same handler. This is already correct in the existing code — no iOS concern, just don't break it by adding a new endpoint.
- **SwiftUI pattern for row-level dialogs**: The existing kick flow uses `.confirmationDialog(..., presenting: memberToKick)`. Mirror that shape exactly for the role-change dialog — separate state variable, separate dialog, both attached to the same `membersSection`.
- **Member list refresh**: `HouseholdDetailView` already pulls members in `.task { await loadMembers() }` and prefetches from the Settings parent via `initialMembers` init arg. After a role change, we don't need a full refetch — in-place mutation + re-sort is cheaper and avoids a spinner flash.

### Source tree components to touch

- `ios/FormulaHelper/Networking/APIClient.swift` — new method `updateMemberRole(...)`; add next to `kickMember(...)` (currently at the tail of the Households section).
- `ios/FormulaHelper/Views/SettingsView.swift` — `HouseholdDetailView` is the target struct. Specific insertion points:
  - State block at top of the struct (where `@State private var memberToKick` lives)
  - `canKick(_:)` — add `canChangeRole(_:)` alongside
  - `memberRow(_:)` — swap chevron
  - `membersSection` — wrap rows in Button; attach second `.confirmationDialog`; rewrite footer
  - Action methods area (where `kick(_:)` lives) — add `changeRole(_:to:)`

### Testing standards summary

- No iOS test target is wired (`docs/development-guide.md#Testing`). Manual verification only per the matrix in Task 7.
- Do **not** add XCTest files; introducing a test target here would be out of scope and requires `project.yml` changes.
- Backend: no new code, no new tests required. The existing handler path is already exercised via TestFlight build 36 indirectly (the endpoint has been callable but no UI surfaced it).

### Project structure notes

- **Alignment**: All changes confined to two files (`APIClient.swift`, `SettingsView.swift`). Matches the "small iOS tweak" pattern seen in recent commits (builds 32–36 all followed this shape). No new files, no new types.
- **Conflicts / variances**: None anticipated. SourceKit may emit spurious "Cannot find type X" diagnostics mid-edit — ignore per `docs/architecture-ios.md#Known quirks`.
- **Naming convention**: Method named `updateMemberRole` (not `changeMemberRole`) to match the backend verb (`PUT`) and the endpoint name (`_update_membership_role`). The UI method is `changeRole(_:to:)` for readability.

### References

- [Source: docs/architecture-ios.md#Settings / Household (Views/SettingsView.swift)]
- [Source: docs/architecture-ios.md#Known quirks]
- [Source: docs/architecture-lambda.md#Capability model]
- [Source: docs/api-contracts-lambda.md#Households] — `PUT /api/households/{hh_id}/members/{user_id}` row
- [Source: docs/component-inventory-ios.md#Conventions] — destructive action and list styling conventions
- [Source: docs/integration-architecture.md#Error surface] — client-side error propagation pattern
- [Source: lambda/handler.py:164-180] — `ROLE_CAPS` definition
- [Source: lambda/handler.py:784-807] — `household_member_update` handler
- [Source: ios/FormulaHelper/Views/SettingsView.swift — `HouseholdDetailView`] — existing kick flow to mirror
- [Source: ios/FormulaHelper/Networking/APIClient.swift — `kickMember`] — API method pattern
- [Source: docs/TODO.md#Household] — confirms notifications are parked; this story does not depend on them

### Recent commit patterns (git intelligence)

- `29ba08b` Wire iOS Debug build to dev stack
- `91f9289` Rewrite lambda for households + SIWA recovery
- Recent iOS work lives in `ios/FormulaHelper/Views/*.swift` exclusively. No new folder or module introduced in any of the last five commits. Stay inside existing files.
- TestFlight cadence is one build per story (builds 32–36 map 1:1 to feature tweaks). Follow the same pattern: implement, then `/testflight-release dev`.

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (`claude-opus-4-7`) — invoked via `/bmad-dev-story`.

### Debug Log References

- `cd ios && xcodebuild -project FormulaHelper.xcodeproj -scheme FormulaHelper -configuration Debug -destination 'generic/platform=iOS Simulator' -quiet build` — exited cleanly, no errors, no new warnings. Pre-existing warnings (AuthManager main-actor window lookup, widget `CFBundleVersion=1`) unchanged.
- SourceKit index noise ("Cannot find type X in scope", "No such module UIKit") was observed mid-edit and is documented in `docs/architecture-ios.md#Known quirks` — confirmed not reproducible at build time.

### Completion Notes List

**Implemented:**
- `APIClient.updateMemberRole(hhId:userId:role:)` — mirrors `kickMember` shape; uses the existing `put<T: Decodable>` helper with `OkResponse` discard.
- `HouseholdDetailView.canChangeRole(_:)` — same three-check gate as `canKick`. Intentionally a separate function per the story's AC 3 naming, not collapsed with `canKick` (they're currently identical but semantically distinct; future work like transfer-ownership may diverge them).
- Member rows now wrap in `Button { … } label: { memberRow(m) } .buttonStyle(.plain).disabled(!canChangeRole(m))` so non-eligible rows don't register taps. Swipe-to-remove modifier chained on the Button preserving the existing UX.
- Second `.confirmationDialog` attached to `membersSection` (sibling of the existing kick dialog), `presenting: memberForRoleChange`. Button label derived from current role: `admin` → "Make member", otherwise "Make admin".
- `changeRole(_:to:)` action: posts the PUT, mutates `members` in place by replacing the target with a freshly-initialised `HouseholdMember` carrying the new role, then re-runs `HouseholdDetailView.sortMembers(_:)` so the admin-before-member ordering is preserved without a refetch.
- Chevron swap: `"chevron.left"` → `"chevron.right"` (same size/weight/colour token) — iOS disclosure convention now signals tap affordance; swipe affordance communicated via footer copy.
- Footer hint rewritten to "Tap a member to change their role. Swipe left to remove them." Visibility predicate relaxed from `members.contains(where: canKick)` to also include `canChangeRole` for symmetry.

**Deviation from this skill's standard flow (steps 5/6/7):** The workflow prescribes red-green-refactor with automated tests. iOS has no test target wired (see `docs/development-guide.md#Testing` and Story → Dev Notes → Testing standards). The story itself mandates "Do **not** add XCTest files". Per-task manual verification (Task 7) was defined in place of automated tests; the Subtask 7.1 compile check passed, the remaining subtasks are gated on human interaction and multi-account access and are explicitly marked as human follow-ups. This deviation is listed here so a reviewer can decide whether to re-open any of 7.2–7.4 or accept and ship.

**No backend change, no Lambda deploy required.** The `household_member_update` handler at `lambda/handler.py:784-807` was already live; this story only connected an existing endpoint to the UI.

### File List

- `ios/FormulaHelper/Networking/APIClient.swift` (modified) — added `updateMemberRole(hhId:userId:role:)`
- `ios/FormulaHelper/Views/SettingsView.swift` (modified) — added `memberForRoleChange` state, `canChangeRole(_:)`, tap affordance via Button wrap, second `.confirmationDialog`, `changeRole(_:to:)` action; swapped row chevron; rewrote members footer hint

### Change Log

- 2026-04-24: Implemented role management UI (Story 1.1). Owner can now promote a member to admin or demote an admin to member from `HouseholdDetailView`. No backend change. Manual on-device verification (subtasks 7.2–7.4) deferred to human reviewer.

## Open Questions / Clarifications

None. All facts above are derived from in-tree code or generated docs. If a dev-story run finds a discrepancy (e.g. the backend starts rejecting valid-role payloads), record it in Completion Notes and re-validate before marking status `done`.

### Review Findings

**Acceptance Auditor (Story 1.1 scope):** ✅ Ship it — all 10 ACs satisfied, File List and Completion Notes truthful, task 7.2–7.4 correctly left as human-in-the-loop per spec. No Story 1.1 findings.

The broader code review covered the entire uncommitted dev_auth working tree (2777-line diff, 12 files) and surfaced issues **outside Story 1.1 scope** that should be resolved before committing the branch. Full triage at `_bmad-output/implementation-artifacts/review-1/triage.md`. Deferred items at `_bmad-output/implementation-artifacts/deferred-work.md`.

**Highest-priority branch-level finding:** Soft-delete (`household_delete`) is cosmetic — `_require_member` and every protected household-scoped route except `households_list` ignore `deleted_at`. Members of a "deleted" household keep reading/writing and invites still redeem into ghosts. Fix shape: add `_require_alive_member` and use it everywhere; same check in `invite_redeem`.

- [x] [Review][Defer] Dev-login leaks Sim Households over time [lambda/handler.py] — deferred, pre-existing
- [x] [Review][Defer] Unbounded name length / charset [lambda/handler.py] — deferred, pre-existing
- [x] [Review][Defer] Invite `expires` float w/ no client-skew handling [lambda/handler.py + AppState.swift] — deferred, pre-existing
- [x] [Review][Defer] `household_transfer` not wired in iOS [APIClient.swift] — deferred, covered by Story 1.2
- [x] [Review][Defer] Hard-coded hostnames in project.yml [ios/project.yml] — deferred, intentional pinning
- [x] [Review][Defer] `InviteShareSheet` uses `UIPasteboard.general` [SettingsView.swift] — deferred, auth-hardening pass
- [x] [Review][Defer] `InviteShareSheet.expiresText` doesn't refresh [SettingsView.swift] — deferred, cosmetic
- [x] [Review][Defer] `InviteCodeSheet` accepts URL-prefixed tokens [SettingsView.swift] — deferred, UX polish
- [x] [Review][Defer] Admin role has no iOS UI for its backend caps [SettingsView.swift] — deferred, epic-scoped
- [x] [Review][Defer] `household_member_update` lacks self-demotion guard [lambda/handler.py] — deferred, defense-in-depth

---
**Completion note (create-story agent):** Ultimate context engine analysis completed — comprehensive developer guide created. No PRD/epics file was available (brownfield); story derived from existing `docs/*` architecture set + direct handler.py + SettingsView.swift reads. Scope is intentionally narrow: single tap-to-change-role interaction, no backend change, no new files.
