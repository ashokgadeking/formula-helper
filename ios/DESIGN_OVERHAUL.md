# AvantiLog iOS — Design Overhaul Plan

Based on Anastasia Prokhorova's iOS UI design guide (UX Collective) + Apple HIG.

---

## Audit: What's Wrong Today

### Navigation
- **No tab bar.** Logs, Trends, and Settings are sheets/modals launched from a custom button grid. This is a webapp pattern, not iOS.
- **Settings is admin-gated** behind a gear icon in the top-right corner that overlaps the status bar. There's no standard placement for it.
- **Back/Trends bottom bars** are custom-built per screen rather than using NavigationStack toolbars.

### Layout & Grid
- **No consistent 8pt grid.** Font sizes (68, 58, 44, 36, 14, 11), paddings (20, 24, 14, 16), and spacings are arbitrary.
- **Margins are inconsistent** — 16pt in some places, 20pt in others.
- **Button grid uses 1px separators** between cells — a web CSS pattern that doesn't translate well to native iOS.
- **70/30 split** (banner/grid) is hard-coded via `GeometryReader` fractions, not responsive.

### Color System
- Colors are named after appearance (`bg`, `bg2`, `card`, `card2`, `wht`, `dim`) rather than purpose. This violates semantic color naming.
- No formal **fill color** tier (Primary/Secondary/Tertiary Fill for translucent elements).
- No **label color** tier (Primary/Secondary/Tertiary/Quaternary Label).
- Background layers (bg → bg2 → card → card2) are used inconsistently.

### Typography
- Font sizes are ad hoc: 68pt for the timer, 58pt for the banner title, 36pt for preset buttons, 11pt for labels — no defined scale.
- No **Dynamic Type** support. Fixed sizes throughout.
- Tracking values (`-2`, `-1`, `2.5`, `1.5`) are not tied to any system — some are extreme for the font size.
- `UPPERCASED` labels with high tracking are overused, reducing readability.

### Iconography
- Formula and diaper buttons have **no icons** — just text labels. Hard to scan at a glance.
- The settings gear is the only SF Symbol in the main UI.
- Emoji (🍼) used in the widget but not in the app — inconsistent.

### Components
- **Button grid** is not a native iOS pattern. It reads as a calculator/kiosk interface.
- **No native List component** in Logs — custom `VStack` rows.
- **AmountSheet** has a custom header bar instead of using SwiftUI's `.navigationTitle` + sheet affordances.
- **Touch targets**: The 1px separators between grid buttons mean tap borders land on dead zones.

### Transitions
- Sheets appear for Logs and Trends, which is correct for secondary content.
- Settings appears as a sheet too — should be a full navigation push or a dedicated tab.
- No animation polish between states (loading → loaded, no bottle → active).

---

## Redesign Principles

1. **iOS-native first.** Tab bar for global navigation, NavigationStack within each tab, native List for tabular content.
2. **8pt grid, always.** Every spacing value is a multiple of 8 (or 4 for fine-grain). Margins: 16pt.
3. **Semantic color tokens.** Rename and restructure the color system to match iOS conventions.
4. **Defined type scale.** 10 text styles from Large Title to Caption 2, all tied to Outfit at standardized sizes.
5. **SF Symbols throughout.** Every action has an icon. Consistent weight (`.medium`) across the app.
6. **Dynamic Type.** Respect user font size preferences.
7. **Minimum 44×44pt touch targets.** No smaller interactive element.

---

## Section 1: Information Architecture

### New Tab Bar (4 tabs)

| Tab | SF Symbol | Label | Content |
|-----|-----------|-------|---------|
| 1 | `drop.fill` | Feed | Hero timer + quick-log actions |
| 2 | `rectangle.stack.fill` | Logs | Formula + diaper log history |
| 3 | `chart.bar.fill` | Trends | Formula + diaper trends |
| 4 | `gearshape.fill` | Settings | Timer, users, preferences |

- Replaces all sheets for Logs, Trends, Settings.
- AmountSheet (custom amount) remains a sheet — it's a transient action, not a section.
- Settings is no longer admin-gated in the UI; all users can view settings (write operations remain protected server-side).

---

## Section 2: Color System

### Rename to semantic tokens

```swift
// Backgrounds (layered: primary → secondary → tertiary)
primaryBackground        // #08080f  — overall app background
secondaryBackground      // #0e0e1a  — grouped section background, cards
elevatedBackground       // #141422  — elements raised above secondaryBackground
overlayBackground        // #1a1a2e  — modals, sheets

// Labels
primaryLabel             // #ebebf5 @ 100%  — titles, primary content
secondaryLabel           // #ebebf5 @ 60%   — subtitles, captions
tertiaryLabel            // #ebebf5 @ 35%   — placeholder, disabled
quaternaryLabel          // #ebebf5 @ 18%   — very subtle hints

// Fills (for tinted interactive element backgrounds)
primaryFill              // white @ 12%   — thin/small shapes (sliders)
secondaryFill            // white @ 8%    — medium shapes (toggles)
tertiaryFill             // white @ 5%    — large shapes (text fields, buttons)

// Separators
separator                // white @ 6%    — standard divider
opaqueSeparator          // #1e1e2e       — opaque divider where transparency won't work

// Accent colors (unchanged, but bg/border variants renamed)
green + greenFill + greenBorder
blue  + blueFill  + blueBorder
yellow + yellowFill + yellowBorder
red   + redFill   + redBorder
purple + purpleFill + purpleBorder
```

---

## Section 3: Typography Scale

All styles use the **Outfit** variable font. Sizes follow Apple's default text style table.

| Style | Size | Weight | Tracking | Leading | Usage |
|-------|------|--------|----------|---------|-------|
| largeTitle | 34pt | Bold | -0.4 | 41pt | Hero timer display |
| title1 | 28pt | Bold | -0.3 | 34pt | Section headers |
| title2 | 22pt | Bold | -0.2 | 28pt | Card titles, sheet headers |
| title3 | 20pt | Semibold | -0.1 | 25pt | Sub-section headers |
| headline | 17pt | Semibold | 0 | 22pt | List row titles, button labels |
| body | 17pt | Regular | 0 | 22pt | Log entry body text |
| callout | 16pt | Regular | 0 | 21pt | Supporting info |
| subheadline | 15pt | Regular | 0 | 20pt | Secondary list content |
| footnote | 13pt | Regular | 0 | 18pt | Timestamps, metadata |
| caption1 | 12pt | Regular | 0 | 16pt | Chart labels, tags |
| caption2 | 11pt | Medium | 0.3 | 13pt | Badge labels, pill text |

**Rules:**
- Max tracking on uppercase labels: 1.5. Current values of 2.5 are too wide.
- Remove all-caps for most labels. Reserve UPPERCASE for short badge-style labels only (e.g. "PEE", "POO").
- Timer display uses `largeTitle` or a custom display size (up to 56pt), not arbitrary 68pt.

---

## Section 4: Layout & Grid

### 8pt Grid

All padding and spacing values must be multiples of 8pt (or 4pt for fine-grain adjustments):

```
4pt   — icon-to-label gap, inline spacing
8pt   — component internal padding (top/bottom of rows)
12pt  — card internal padding (compact)
16pt  — standard horizontal margin, card internal padding (standard)
24pt  — between sections
32pt  — between major layout groups
```

### Horizontal Margins
- **16pt** everywhere. No more 20pt.
- Safe area insets handled by SwiftUI's `.safeAreaInset` / `.safeAreaPadding`.

### Cards
- Corner radius: **12pt** (continuous, `.continuous`)
- Border: `separator` color, 1pt
- Background: `secondaryBackground`
- Internal padding: 16pt horizontal, 12pt vertical

---

## Section 5: Screen-by-Screen Redesign

### 5.1 Feed Tab (main screen)

**Current:** 70% banner / 30% button grid separated by 1px lines.

**Redesigned:**
```
┌─────────────────────────────────┐
│  [status bar — safe area]       │
│                                 │
│  Hero area (scrollable)         │
│  ┌─────────────────────────┐   │
│  │  "ACTIVE BOTTLE"         │   │  ← secondaryLabel, caption2
│  │  1:02:34                 │   │  ← largeTitle (56pt), green
│  │  90ml · mixed at 2:30pm  │   │  ← footnote, tertiaryLabel
│  │  ▓▓▓▓▓▓▓░░░ Est. 4:30pm │   │  ← thin progress bar
│  └─────────────────────────┘   │
│                                 │
│  QUICK LOG                      │  ← caption2, tertiaryLabel
│  ┌──────┐ ┌──────┐ ┌──────┐   │
│  │  90  │ │ 100  │ │ 120  │   │  ← 3 formula cards, 16pt gap
│  │  ml  │ │  ml  │ │  ml  │   │
│  └──────┘ └──────┘ └──────┘   │
│                                 │
│  ┌──────────────┐ ┌──────────┐ │
│  │  💧 PEE  ×3  │ │ 💩 POO ×1│ │  ← 2 diaper cards, SF symbols
│  └──────────────┘ └──────────┘ │
│                                 │
│  ┌──────────────────────────┐  │
│  │  ✏️  Custom Amount        │  │  ← purple tint, secondary action
│  └──────────────────────────┘  │
│                                 │
│  [home indicator — safe area]   │
└─────────────────────────────────┘
```

- Cards replace the 1px-separator grid. Each card is `secondaryBackground` with `separator` border, `12pt` radius, `16pt` padding.
- Formula cards: large number (`title1`) + "ml" label (`footnote`). Full-width tap target.
- Diaper cards: SF Symbol icon + label (`headline`) + count badge (`caption2`).
- Custom Amount: full-width secondary button, `purpleFill` background.
- Hero area sits in a rounded card that fills to the top (background gradient preserved).

### 5.2 Logs Tab

**Current:** Sheet presented from button grid. Custom `VStack` rows with a custom top bar.

**Redesigned:**
- Proper `NavigationStack` with `.navigationTitle("Logs")`.
- Segmented control at top: `Formula | Diapers` (replaces custom tab pills).
- Native `List` with `.insetGrouped` style.
- Formula rows: icon (`drop.fill`, blue) + "Xml" headline + time subheadline + swipe-to-delete.
- Diaper rows: icon (`🚽` → SF Symbol `figure.child`) + type + time + swipe-to-delete.
- Section headers by date ("Today", "Yesterday", "Mar 18").

### 5.3 Trends Tab

**Current:** Custom `TrendsView` with pill tabs, stat cards, bar chart, diaper timeline. Presented as a sheet from Logs.

**Redesigned:**
- Becomes a proper tab — no more drill-down from Logs.
- Keeps the formula bar chart and diaper timeline (already solid).
- Replace custom pill tabs with a native `Picker` in `.segmented` style.
- Stat cards use standardized card component (12pt radius, 16pt padding, 8pt grid spacing).
- Section labels use `caption2` style with `tertiaryLabel` color — no more all-caps with extreme tracking.

### 5.4 Settings Tab

**Current:** Full-screen sheet. Two sub-tabs (Users, Timer) as custom pills.

**Redesigned:**
- Proper `NavigationStack` with `List(.insetGrouped)`.
- Sections: **Timer** | **Users** | **About**
- Timer section: stepper-style row with − / + controls inline.
- Users section: standard list rows with trailing delete button.
- No more custom pill tabs.

---

## Section 6: Iconography

Use SF Symbols consistently at `.medium` weight across all icons:

| Context | Symbol | Color |
|---------|--------|-------|
| Feed tab | `drop.fill` | green |
| Logs tab | `list.bullet` | blue |
| Trends tab | `chart.bar.fill` | purple |
| Settings tab | `gearshape.fill` | dim |
| Formula log row | `drop.fill` | blue |
| Diaper (pee) row | `drop.fill` | yellow |
| Diaper (poo) row | `circle.fill` | brown |
| Custom amount | `slider.horizontal.3` | purple |
| Reset timer | `arrow.counterclockwise` | red |
| Delete | `trash` | red |
| Edit | `pencil` | blue |

---

## Section 7: Touch Targets

Every tappable element must have a minimum frame of **44×44pt**:
- Preset formula buttons: use `.frame(maxWidth: .infinity, minHeight: 72)` — currently OK via grid height
- Diaper buttons: `.frame(maxWidth: .infinity, minHeight: 80)`
- Log row delete/edit: `.swipeActions` handles this natively
- Tab bar: native `TabView` — handled by iOS
- Settings rows: native `List` rows — handled by iOS

---

## Section 8: Transitions & Motion

| Transition | Style |
|------------|-------|
| Tab switching | Native TabView (cross-fade/slide) |
| AmountSheet | `.sheet` — default iOS modal |
| Log row deletion | `.automatic` List animation |
| Timer state changes (active → expired) | `.easeInOut(duration: 0.3)` color/text crossfade |
| Button tap feedback | `.buttonStyle(.plain)` + `.scaleEffect` on press (subtle, 0.97) |
| Loading state | Native `ProgressView()` |

**No custom page transitions. No spring animations on navigation.** Follow iOS standard durations (0.25–0.35s).

Ensure `@Environment(\.accessibilityReduceMotion)` is respected — remove scale animations when reduce motion is on.

---

## Section 9: Dynamic Type

All text uses `.font(.custom("Outfit", size: X))` with a `@ScaledMetric` wrapper or SwiftUI's built-in Dynamic Type via `.font(.body)` etc.

Plan: Define a `AppTextStyle` enum that maps each style to a base size + `relativeTo:` text style:

```swift
enum AppTextStyle {
    case largeTitle   // 34pt, relativeTo: .largeTitle
    case title1       // 28pt, relativeTo: .title
    case headline     // 17pt, relativeTo: .headline
    case body         // 17pt, relativeTo: .body
    case footnote     // 13pt, relativeTo: .footnote
    case caption2     // 11pt, relativeTo: .caption2
    // ...
}
```

This allows Outfit to scale with the user's text size setting while preserving the custom font.

---

## Implementation Order

### Phase 1 — Foundation (no visual changes yet)
1. Refactor `DesignSystem.swift`: rename color tokens to semantic names, add fill/label tiers
2. Add type scale to `DesignSystem.swift`: `AppTextStyle` enum with `@ScaledMetric` support
3. Update all call sites to use new tokens (find/replace pass)

### Phase 2 — Navigation restructure
4. Replace `MainView` sheet-based navigation with `TabView` (4 tabs)
5. Move Logs into its own tab with `NavigationStack` + native `List`
6. Move Trends into its own tab
7. Move Settings into its own tab with `NavigationStack` + `List(.insetGrouped)`

### Phase 3 — Feed tab redesign
8. Replace button grid with card-based layout (16pt margins, 8pt gaps, 12pt radius)
9. Add SF Symbol icons to formula and diaper cards
10. Redesign hero banner with proper type scale and progress bar

### Phase 4 — Component polish
11. Add `.scaleEffect` press feedback to cards
12. Respect `accessibilityReduceMotion`
13. Audit all touch targets ≥ 44×44pt
14. Add proper `accessibilityLabel` to all interactive elements

### Phase 5 — QA & TestFlight
15. Test on iPhone 17 Pro and iPhone SE (smallest current device)
16. Test Dynamic Type at xLarge and accessibility sizes
17. Test VoiceOver navigation order
18. Archive and upload to TestFlight

---

## What We're Keeping

- **Outfit font** — looks great, unique, keep it
- **Color palette** — the green/blue/yellow/red/purple accents are well-chosen; only the naming and structure changes
- **Hero timer display** — the large countdown is the app's identity; keep it as the centerpiece
- **FreshnessBar & Live Activity** — already well-designed, no changes needed
- **AmountSheet calculator** — the water/powder card design is solid
- **Diaper timeline chart** — keep as-is
- **Formula bar chart** — keep as-is

---

## What We're Removing

- 1px separator grid lines between buttons
- Custom bottom bars (Back / Trends / Done) on sheet screens
- Gear icon overlay in top-right corner
- Sheet-based navigation for Logs, Trends, Settings
- Arbitrary font sizes and tracking values not in the type scale
- `bg2`, `card`, `card2`, `wht`, `dim`, `dim2` color names
