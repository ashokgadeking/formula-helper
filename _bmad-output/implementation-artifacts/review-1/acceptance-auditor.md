# Acceptance Auditor Findings — Story 1.1

## AC Coverage

| AC | Status | Evidence |
|---|---|---|
| AC 1 — Backend unchanged (`PUT /members/{user_id}` already implemented) | ✅ satisfied | No changes to `household_member_update` in `lambda/handler.py` section of the diff; client simply calls the existing endpoint (diff L567–572). |
| AC 2 — Affordance gated on caller `isOwner` | ✅ satisfied | `canChangeRole` begins `guard isOwner else { return false }` (L1916–1921). Non-owners short-circuit to `false`, so chevron, tap, dialog all suppressed. |
| AC 3 — Gated per row (target ≠ owner, target ≠ self) | ✅ satisfied | `canChangeRole` checks `m.role.lowercased() == "owner"` and `m.user_id == auth.authState.userId` (L1918–1919), mirroring `canKick`. |
| AC 4 — Trailing `chevron.right` on eligible rows; old `chevron.left` swipe hint removed | ✅ satisfied | `memberRow` renders `Image(systemName: "chevron.right")` guarded by `canChangeRole(m)` at L1953–1957 with the prescribed `.system(size: 11, weight: .semibold)` / `Color.tertiaryLabel` styling. No `chevron.left` appears in the member row (only unrelated onboarding arrow at L1073). |
| AC 5 — `.confirmationDialog` titled "Change role for {name}" with Make admin/Make member + Cancel; no Make owner | ✅ satisfied | Second `.confirmationDialog` at L1872–1903 with title `"Change role for \($0.name.isEmpty ? "member" : $0.name)"`; admin→"Make member", else→"Make admin"; `Button("Cancel", role: .cancel)`. No "Make owner" action present. |
| AC 6 — Pessimistic update: call API first, mutate on 2xx, re-sort | ✅ satisfied | `changeRole(_:to:)` at L2098–2119 awaits `updateMemberRole` then mutates `members[idx]` and calls `HouseholdDetailView.sortMembers(members)` only in the success branch. |
| AC 7 — Error path: set `membersError`, no optimistic mutation | ✅ satisfied | `catch { membersError = error.localizedDescription }` (L2116–2118) — no array mutation prior to the `try await`. Footer surfaces `membersError` at L1831–1832. |
| AC 8 — Swipe-to-remove unchanged | ✅ satisfied | `.swipeActions(edge: .trailing, allowsFullSwipe: false)` still attached to each row (L1812–1817), still gated by `canKick`, still sets `memberToKick`. Kick dialog preserved at L1845–1871. |
| AC 9 — Footer hint updated; visibility when any eligible row | ✅ satisfied | Text updated to "Tap a member to change their role. Swipe left to remove them." with `hand.draw.fill` prefix (L1834–1838). Visibility predicate `members.contains(where: canChangeRole) || members.contains(where: canKick)` at L1833. |
| AC 10 — iOS-only, no new backend route, no Lambda deploy | ✅ satisfied | The diff touches `lambda/handler.py` (unrelated auth/household rewrite — out of this story's scope per the audit brief) but introduces no new route bound to role management. The iOS role-change path targets the pre-existing `PUT /members/{user_id}`. |

## Constraint Violations
- None within Story 1.1 scope. Dev Notes bans on XCTest files and two-file scope are respected (the role-mgmt additions are confined to `APIClient.swift` and `SettingsView.swift`; other diff hunks belong to unrelated stories and are out of audit scope).

## Story-file accuracy
- **File List truthful? Yes** — `APIClient.swift` gains `updateMemberRole` (L567–572); `SettingsView.swift` gains `memberForRoleChange` state, `canChangeRole`, Button-wrapped row with chevron swap, second `.confirmationDialog`, and `changeRole(_:to:)`. Exactly what the story lists.
- **Task checkboxes match delivered code? Yes** — Tasks 1–6 all delivered as described. Task 7.1 (Debug build) credibly reported; 7.2–7.4 explicitly left unchecked with human-in-the-loop rationale, which matches the spec's deferral.
- **Completion Notes match reality? Yes** — All bulleted claims (API shape, separate predicate from `canKick`, Button wrap preserving swipe, second dialog, in-place mutation + re-sort, chevron swap, footer rewrite + relaxed visibility predicate) verified in diff.

## Overall verdict
- [x] Ship it — all 10 ACs satisfied, no deviations, file list and completion notes accurate. Manual on-device verification (7.2–7.4) remains open per spec and is explicitly flagged for human follow-up.
- [ ] Ship with caveats
- [ ] Block
