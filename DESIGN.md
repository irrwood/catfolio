# Catfolio Design System

This design system translates the supplied reference images into reusable product UI rules for Catfolio. The direction is a calm, local-first investment workspace: quiet surfaces, dense information, soft controls, precise tables, and restrained accent color.

## Product Register

Catfolio is a task-focused dashboard for portfolio tracking, quant research, strategy testing, and AI-assisted analysis. The interface should feel like a trusted professional tool rather than a marketing site.

Use these priorities in order:

1. Data clarity
2. Fast scanning
3. Consistent navigation
4. Low visual noise
5. Small moments of brand warmth

## Reference Direction

The supplied references share a clear product pattern:

- Light app shell with white content panels and a very pale gray canvas.
- Centered report-style pages for focused analytical summaries, with a max-width content column and no persistent sidebar when navigation is not needed.
- Left navigation as a persistent workspace spine.
- Compact sidebars, tables, segmented controls, list rows, badges, and popovers.
- Rounded controls with low-contrast borders and soft shadows.
- Gray iconography with one active accent.
- Dense data layout that keeps labels and values aligned.
- Pastel status tags used sparingly.
- Small charts embedded in cards without decorative chrome.

Avoid visual directions that fight this:

- Dark-first dashboards.
- Heavy gradients or decorative backgrounds.
- Oversized hero sections.
- Large decorative cards used as page layout.
- Finance cliches such as navy and gold, trading-terminal black, or neon market green.
- Overly playful illustrations inside analytical screens.

## Design Principles

### Quiet Tooling

The UI should recede behind the work. Most surfaces are white or near-white, with separation coming from spacing, 1px borders, subtle shadows, and hierarchy.

### Dense But Breathable

Show enough information for comparison, especially in tables and portfolio views, but use consistent row heights, label columns, and section spacing so dense screens do not feel crowded.

### One Active Color Per Region

Each screen can have one primary action or selected-state color. Semantic colors are allowed for profit, loss, warning, and tags, but they should not compete with navigation.

### Layered Navigation

Navigation has two levels:

1. A narrow icon rail for primary areas.
2. A wider sidebar or local panel for workspace context, filters, or selected entity details.

### Native Familiarity

Controls should feel familiar on macOS and the web: buttons, tabs, select controls, menus, filters, and tables use standard affordances.

## Color System

Use a restrained light palette inspired by Spade: pure white surfaces, neutral gray fills with a very slight green tint, ink-like forest text, barely green hover states, and a bright green primary accent.

### Core Tokens

```css
:root {
  color-scheme: light;

  --color-canvas: #ffffff;
  --color-sidebar: #f8f9f7;
  --color-surface: #ffffff;
  --color-surface-soft: #f8f9f7;
  --color-surface-raised: #ffffff;

  --color-border: #090f051a;
  --color-border-strong: #090f0533;
  --color-divider: #090f050d;

  --color-text: #090f05;
  --color-forest: #18280e;
  --color-text-muted: #090f0599;
  --color-text-soft: #090f054d;
  --color-text-disabled: #090f0533;
  --color-on-primary: #090f05;

  --color-primary: #c0e880;
  --color-primary-hover: #8fca5b;
  --color-primary-soft: #d4f29e;
  --color-primary-muted: #9fcf78;

  --color-lemongrass: #ebe46a;
  --color-lemongrass-strong: #aa9a33;
  --color-sage: #d8e5ca;
  --color-sage-wash: #f4faed;
  --color-lime-cta: #c0e880;
  --color-moss: #3f7308;
  --color-deep-olive: #202810;
  --color-clay: #c07848;
  --color-olive-gold: #a89840;

  --color-success: #4fa68f;
  --color-success-soft: oklch(96.5% 0.035 155);
  --color-danger: #e40014;
  --color-danger-soft: oklch(96.5% 0.035 25);
  --color-warning: oklch(74% 0.15 75);
  --color-warning-soft: oklch(96.5% 0.035 75);
  --color-info: oklch(68% 0.13 215);
  --color-info-soft: oklch(96.5% 0.035 215);

  --color-brand-cat: oklch(87% 0.22 120);
  --color-brand-cat-ink: oklch(24% 0.025 130);

  --icon-red: #e05048;
  --icon-rose: #d85898;
  --icon-violet: #c858e8;
  --icon-teal: #50b8a8;
  --icon-blue: #4880e8;
  --icon-indigo: #6068e8;
  --icon-orange: #f07830;
  --icon-green: #60c068;
}
```

### Usage Rules

- Canvas: app background and gutters only.
- Sidebar: navigation panels and secondary workspace rails.
- Surface: cards, popovers, tables, top bars, settings panels.
- Primary green: selected tabs, active nav, primary buttons, CTA fills, and key chart bars. Use the bright green from the Spade reference, `#c0e880`.
- Blue: information accents and optional icon color only. Do not use blue as the primary product accent.
- Secondary progress segments should stay in the green family, using `#9fcf78` to `#8fca5b`. Avoid gold/yellow in charts and usage bars.
- Lemongrass: reserved for palette documentation or rare brand accents, not default product metrics.
- Green-gray: default table headers, segmented controls, inputs, and quiet panels should use `#f8f9f7`.
- Hover green: hover states should be only slightly greener than the default fill, such as `#f4f7f1`. Avoid obvious mint blocks for normal hover.
- Forest / ink: text, logo marks, linework, and strong anchors.
- Clay and olive gold: use-case icon backgrounds and small category accents.
- Icon accent colors: only for compact app icons, category marks, and product modules. Do not use all of them in one dense table.
- Success green: gains, positive deltas, completed states.
- Danger red: losses, destructive actions, failed states.
- Warning amber: stale data, caution states.
- Info teal: secondary analytical indicators.
- Cat green: brand icon background and rare brand moments, not generic success.

## Typography

Use Raleway for English and Latin UI text, with system fonts as the fallback for Chinese and unavailable font loading.

```css
--font-latin: "Raleway";
--font-cjk: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
--font-sans: var(--font-latin), var(--font-cjk);
--font-mono: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
```

### Type Scale

```css
--text-2xs: 11px;
--text-xs: 12px;
--text-sm: 13px;
--text-md: 14px;
--text-lg: 16px;
--text-xl: 20px;
--text-2xl: 24px;
```

### Roles

- Page title: 20 to 24px, 650 weight.
- Section title: 16px, 600 weight.
- Card title: 13 to 14px, 600 weight.
- Body: 14px, 400 to 500 weight.
- Table cell: 13 to 14px, 400 to 500 weight.
- Metadata: 12 to 13px, muted.
- Numbers: tabular numerals, 500 to 650 weight.

### Text Rules

- Do not use display fonts.
- Do not scale text with viewport width.
- Keep letter spacing at 0 for normal text.
- Use sentence case for labels.
- Use short labels in nav and controls.
- Use muted labels and stronger values in label-value layouts.

## Spacing

Use a 4px base grid with product UI spacing.

```css
--space-1: 4px;
--space-2: 8px;
--space-3: 12px;
--space-4: 16px;
--space-5: 20px;
--space-6: 24px;
--space-8: 32px;
--space-10: 40px;
```

### Layout Spacing

- App shell gutters: 16 to 24px.
- Sidebar inner padding: 12 to 16px.
- Panel padding: 20 to 24px.
- Compact card padding: 14 to 16px.
- Table cell padding: 12px horizontal, 14 to 18px vertical.
- Toolbar gap: 8px.
- Icon and label gap: 8 to 12px.

## Radius

```css
--radius-dot: 4px;
--radius-inset: 10px;
--radius-control: 12px;
--radius-mark: 14px;
--radius-panel: 16px;
--radius-card: 22px;
--radius-popover: 20px;
--radius-pill: 999px;
```

Core principle: **the larger the surface, the larger the corner.** Radius scales up with the box it rounds, so a page-level card reads softer than a button inside it. The ladder, largest to smallest:

`card 22 › panel 16 › mark 14 › control 12 › inset 10 › dot 4`.

Use radius by component:

- Data dots and legend chips: 4px.
- Small chips and pills inside controls, such as pagination page buttons and inset segments: 10px.
- Buttons, inputs, selects, tabs, and segmented controls: 12px.
- Small brand marks and app icons in compact rows: 14px.
- Medium surfaces: swatches, menus, inline alerts, empty states, toasts: 16px.
- Large top-level cards, tables, and report panels: 22px.
- Popovers and menus: 20px.
- Pills (999px) only when the shape is semantically pill-like, such as status tags and toggles.

Shrinking radius rule (applies on top of the scale):

- Nested surfaces must use a smaller radius than their parent.
- Use `child radius = parent radius - inset distance`, with a minimum visible radius of 2px.
- Example: a 22px card with a 16px swatch or menu inside keeps the parent visibly rounder.
- Example: a 22px card with an inner progress bar inset by 8px uses a smaller bar radius.
- Do not place a control with the same radius as its card when it sits close to the card edge. It breaks the concentric relationship.
- Prefer smooth continuous corners where supported, such as progressive `corner-shape: squircle`. Unsupported browsers should fall back to normal `border-radius`.

Do not over-round dense table cells or inline data rows; the large radius is for the outer container, not every element.

## Elevation

Use shadows lightly. Borders do most of the work.

```css
--shadow-1: 0 1px 1px rgba(15, 23, 42, 0.02);
--shadow-2: 0 6px 18px rgba(15, 23, 42, 0.045);
--shadow-3: 0 12px 28px rgba(15, 23, 42, 0.07);
```

Elevation roles:

- Level 0: page canvas, no border or shadow.
- Level 1: cards and tables, 1px border, no shadow by default.
- Level 2: popovers, dropdowns, command surfaces, shadow-2 only when floating above content.
- Level 3: floating dialogs, shadow-3.

Do not use glassmorphism, backdrop blur, or heavy layered shadows.

## App Shell

### Desktop Structure

Preferred shell:

1. Narrow icon rail, 64 to 72px wide.
2. Optional expanded sidebar, 240 to 288px wide.
3. Main content area with top toolbar and scrollable workspace.

The reference images show both full sidebars and compact icon rails. Catfolio should support both patterns where screen width allows.

### Icon Rail

- Width: 64px.
- Background: sidebar token.
- Top logo: 36 to 40px square.
- Icon buttons: 36 to 40px square.
- Active icon: white surface or primary-soft background, stronger icon color.
- Inactive icon: muted gray.
- Section dividers: dotted or solid 1px divider with low opacity.
- Bottom utilities: theme, settings, account, compact app icon.

### Expanded Sidebar

- Width: 248 to 280px.
- Use section labels in uppercase 11 to 12px muted text.
- Nav row height: 40 to 44px.
- Active nav row: soft tinted background with active text.
- Do not use colored side stripes.
- Counts and badges align to the trailing edge.

## Page Layout

### Standard Workspace

Use this structure for most screens:

1. Header row with title, breadcrumbs, tabs, or primary actions.
2. Toolbar row with search, filters, sort, export, date range, or mode controls.
3. Primary content: table, chart grid, detail panel, or split view.

### Focused Report Page

Use this structure for single-purpose analytical pages such as usage, summary, export review, or focused performance reports:

- Center the content in a 920 to 1040px column.
- Use a pure white page background.
- Header: title and short muted description on the left, compact segmented control or action on the right.
- Main card: 1px border, 22px radius, no shadow.
- Card body can use a horizontal progress or summary band, followed by a divided metric row.
- Secondary section: tabs on the left, search/export/filter controls on the right.
- Table card below, with compact 56px rows and light dividers.
- Table containers can use a very subtle white to green-gray vertical gradient. Table headers can use the same gradient at a slightly stronger density.
- Do not show side navigation unless it is essential to the task.

Interaction treatment for this style:

- Use gradients only where they clarify hierarchy or progress, such as usage bars, selected tabs, and primary status fills.
- Prefer subtle linear gradients from top to bottom or left to right. Default surface gradients must move from white to neutral gray, not yellow or cream.
- Keep yellow/lemongrass out of ordinary cards, tables, selected controls, charts, and usage bars. Use it only for explicit brand accent marks when the surrounding UI is otherwise neutral.
- Hover states should change background or border color by one step, not add shadow.
- Click states should use a 1px downward press or slightly darker pressed background.
- Focus and active input states use the primary green family, with a `#c0e880`-tinted focus ring and moss/green border. Do not allow browser-default blue focus rings.
- Text selection highlight uses the primary green family, with ink text on `#d4f29e`. Do not use browser-default blue selection.
- Table row hover can use a very light horizontal gradient to help scanning.
- Cards may use a near-invisible vertical surface gradient, but should still read as flat bordered panels.

### Split View

Use split view for entity or portfolio detail pages:

- Left detail panel: 320 to 420px.
- Right analysis panel: flexible width.
- Vertical divider: 1px border.
- Both columns scroll independently only when needed.

### Dashboard Grid

- Use 2 to 4 columns on desktop.
- Keep metric cards compact.
- Avoid full-page card grids where each card has identical structure.
- Large charts can span 2 columns.

## Components

### SaaS Control Coverage

Every Catfolio SaaS-style screen should reuse this base control set before inventing a new component:

- Buttons: primary, secondary, dark, ghost, danger, disabled, loading.
- Inputs: text, search, select, disabled, helper text, validation/error text.
- Selectors: segmented controls, tabs, toggle switches, checkboxes, radio buttons.
- Status: badges, inline alerts, empty states, toasts, skeleton loading, and confirmation surfaces.
- Navigation helpers: dropdown menus, list items, breadcrumbs, table toolbars, pagination.
- Data controls: search, sort, filter, export, date range, refresh.

Every interactive control needs default, hover, focus, active, disabled, and loading or pending states where applicable. Loading states should prefer skeletons inside the affected region over centered spinners.

### Iconography

Use Hugeicons as the product icon language.

- Use Stroke Rounded / linear icons for navigation, table headers, search, filters, export, settings, and secondary actions.
- Use Solid icons for brand marks, selected-state anchors, metric labels, plan/status blocks, and other strong semantic anchors.
- Keep icons on a 24px grid, rendered at 16 to 20px in dense product UI.
- Linear icon stroke: 1.5 to 1.75px, rounded caps and joins.
- Icon-only controls need tooltips or accessible labels.
- Do not mix unrelated icon families inside the same surface.
- In React, prefer the official Hugeicons renderer and icon packs. In static prototypes, inline SVG is acceptable if it follows the same grid, stroke, and corner language.

### Buttons

Use one button vocabulary across the app.

Primary:

- Filled primary background.
- Use --color-on-primary text.
- Used for one main action per region.

Secondary:

- White surface.
- 1px border.
- Dark text.
- Used for common actions such as export, refresh, save draft.

Ghost:

- Transparent background.
- Muted text and icon.
- Used in toolbars and nav.

Danger:

- Danger text or danger fill only for destructive confirmation.

Dark:

- Forest/ink filled button for strong account, broker, or connection actions when it should feel more substantial than a white secondary button.
- Use sparingly. Do not use dark buttons for every primary action.

Button sizing:

```css
.button-sm { height: 32px; padding: 0 12px; font-size: 13px; }
.button-md { height: 38px; padding: 0 14px; font-size: 14px; }
.button-lg { height: 44px; padding: 0 18px; font-size: 15px; }
```

States:

- Hover: slight background shift.
- Focus: 2px visible focus ring.
- Active: pressed transform or darker background.
- Disabled: muted text, low-contrast border, no shadow.
- Loading: keep width stable and replace leading icon with spinner.

### Segmented Controls

Use segmented controls for mode switches such as Daily/Weekly, Company/Investor, and light/dark appearance.

- Height: 32 to 36px.
- Use the same visual language as tabs: one bordered group, green-gray default fill, vertical dividers between items, white active item, no inset shadow.
- Background: surface-soft.
- Selected item: white surface, no shadow unless it needs to separate from a busy toolbar.
- Text: muted when inactive, strong when active.

### Inputs And Selects

- Height: 36 to 40px.
- Radius: 10px for standard controls, 14px for larger field groups.
- Border: color-border.
- Placeholder: text-soft.
- Prefix icons use muted color.
- Keep input labels outside fields for settings and forms.
- Use compact inline labels only in dense filter toolbars.
- Helper text sits below the field in muted 12px text.
- Disabled fields use a near-white gray fill and muted text.
- Search fields may use an icon, focus expansion, and green focus styling.
- Select controls use a Hugeicons chevron (not a CSS-drawn triangle) anchored at `right center`, so the indicator never shifts vertically between rows or on hover. Apply hover and focus background with `background-color`, never the `background` shorthand, so it does not wipe out the chevron image.

### Toggles, Checks, And Radios

- Toggle height: 24px, width: 42px.
- Checked state uses the primary green gradient with an ink or white thumb depending on contrast.
- Checkbox and radio controls use the same green checked state and 17px marks.
- Labels are 13px, medium to bold, with muted color when inactive.
- Never rely on color alone. Checked state needs a visible mark or thumb position.

### Tags And Badges

Tags should communicate a state or category, not decorate.

Use pastel backgrounds with saturated text:

```css
--tag-pink-bg: oklch(96.5% 0.035 350);
--tag-pink-text: oklch(55% 0.2 350);
--tag-blue-bg: oklch(96.5% 0.03 245);
--tag-blue-text: oklch(56% 0.16 245);
--tag-amber-bg: oklch(96.5% 0.04 75);
--tag-amber-text: oklch(57% 0.14 65);
--tag-teal-bg: oklch(96% 0.035 175);
--tag-teal-text: oklch(52% 0.12 175);
--tag-gray-bg: oklch(94.5% 0.006 255);
--tag-gray-text: oklch(48% 0.014 260);
```

Rules:

- Height: 22 to 24px.
- Shape: full pill (999px radius). Tags should not look like rectangular buttons.
- No hard 1px border. Use a soft tinted background only.
- Weight: 600. Do not use heavy bold.
- Font size: 12 to 13px.
- Do not mix more than 4 tag colors in one table.

Tag indicators:

- A plain status tag carries a small 5px leading dot in its own color, which signals "status" rather than "clickable button".
- A tag that already carries a meaning icon (such as a check for Ready) uses the icon instead of the dot. Never show both a dot and an icon.
- Icons inside tags render at 14px.

### Cards

Cards are for bounded repeated objects, metrics, and chart containers.

- Border: 1px solid color-border.
- Radius: large top-level cards 22px; medium nested panels 16px (see the radius scale).
- Padding: 16 to 24px.
- Shadow: none by default.
- Header has title on the left, action or metadata on the right.
- A card may use a near-invisible vertical surface gradient, but it must read as a flat bordered panel. Keep the gradient very faint: blend the bottom stop roughly 45 to 55 percent toward pure white, not a visible cream or gray band.

Avoid nesting cards inside cards. Use dividers or flat sections inside a single panel instead. When a panel groups several areas (for example a component kit or a settings group), use uppercase section labels and spacing, not bordered sub-cards.

### Tables

Tables are a primary Catfolio surface.

Structure:

- Header row background: surface-soft.
- Header text: muted, 12 to 13px, 500 weight.
- Body row height: 56 to 72px depending on density.
- Row border: 1px divider.
- Hover row: subtle surface-soft.
- Numeric columns right-aligned.
- Text columns left-aligned.
- Symbol or company cells can include a 32 to 40px icon tile.

Table controls:

- Search on the left or right depending on available space.
- Sort and filter as secondary buttons.
- Export as secondary button with icon.
- Keep filters in toolbar, not scattered above columns.

### Detail Panels

Use label-value grids for holdings, settings, company facts, or audit details.

Rules:

- Labels: muted, 13 to 14px.
- Values: strong text, 14 to 15px.
- Row spacing: 18 to 24px.
- Align values on a shared left column.
- Truncate long descriptions with an affordance to expand.

### Popovers And Menus

Use popovers for workspace switchers, account menus, actions, and compact settings.

- Width: 320 to 520px depending on content.
- Radius: 18px.
- Border plus shadow-2.
- Menu item height: 40 to 48px.
- Icons are 18 to 20px.
- Section dividers are 1px and low contrast.
- Active item uses check icon or selected background, not both unless the menu needs strong confirmation.

### Pagination

Pagination is a soft control group, not a row of segmented buttons.

- Container: green-gray (`surface-soft`) fill, 1px border, rounded (about 13px), small inner padding, and a small gap between items.
- Page buttons: borderless pills (about 10px radius), muted text, no dividers between them.
- Active page: white chip with a subtle shadow and strong text.
- Hover: one-step background shift, no shadow.
- Do not draw vertical divider lines between page numbers.

### Charts

Chart styling should match the quiet workspace:

- Use simple bars, lines, heatmaps, and distribution charts.
- Avoid chart gradients unless they encode intensity.
- Axis labels are muted and small.
- Gridlines are light.
- Positive line: success green.
- Primary analytical series: primary green.
- Benchmark or comparison series: gray or muted blue.
- Loss or drawdown: danger red.

Charts belong inside cards or full-width analysis panels with clear titles and compact legends.

## Data Visualization

### Portfolio Metrics

Use compact metric cards with:

- Label at top.
- Main number large but not hero-sized, 20 to 28px.
- Delta below or inline.
- Optional trailing icon for info or source.

Do not use oversized marketing-style metric cards.

### Heatmaps

Heatmaps should use semantic financial color, but keep saturation controlled:

- Gains: green scale.
- Losses: red scale.
- Neutral: gray.
- Missing data: muted hatch or low-contrast gray.

Always include a legend and date context.

### Return Calendars

Use month and year labels in the active language. Do not compose translated units manually. For English use "June 2026", "2026", "Jan", "Feb". For Chinese use "2026年6月", "2026", "1月", "2月".

## Motion

Motion is functional only.

- Hover and focus transitions: 120 to 180ms.
- Popover open and close: 160 to 220ms.
- Sidebar collapse: 180 to 240ms.
- Use ease-out curves.
- Do not animate table layout or chart data unless it improves comprehension.
- For focused report pages, use hover transitions on buttons, tabs, table rows, progress bars, and metric cells.
- Search controls may expand by 32 to 56px on focus, with icon translation and green focus styling. Keep the motion under 240ms and avoid shifting surrounding primary content.
- Use `transform: translateY(1px)` for pressed states only. Do not scale controls.

### Slot-Text Reveal

One sanctioned moment of brand warmth, inspired by slot-text (textmotion.dev): a small, tactile roll on first paint. Use it sparingly and only on entrance, never on every data update.

- Page title: characters roll up into place with a soft blur, staggered by index (about 34ms per character).
- Headline numbers and metric values: each digit rolls up from 0 to its target like an odometer, staggered left to right, using a `0–9` reel with `overflow: hidden` and a `translateY` transition.
- Curve: `cubic-bezier(0.22, 1, 0.36, 1)` ease-out; title roll about 560ms, number roll about 1100ms.
- Pure CSS transforms, dependency-free. Do not pull in an animation library for this.
- Must respect `prefers-reduced-motion: reduce` by jumping straight to the final value with no transition.
- Reserve this for hero metrics and page headers. Do not roll dense table cells, inline values, or content that re-renders frequently.

## Accessibility

- Text contrast should meet WCAG AA.
- Focus rings must be visible on buttons, inputs, tabs, segmented controls, and menus.
- Icon-only controls need labels or tooltips.
- Do not communicate gain/loss with color alone.
- Tables need accessible column labels.
- Interactive targets should be at least 32px tall, preferably 36px or more.

## Responsive Behavior

### Desktop

Desktop is the primary target.

- Use icon rail plus optional expanded sidebar.
- Preserve table density.
- Prefer split view for analysis screens.

### Tablet

- Collapse expanded sidebar first.
- Keep icon rail if width allows.
- Convert multi-column grids to 2 columns.
- Keep filters in a horizontal scrollable toolbar if needed.

### Mobile

Catfolio can be functional, but mobile is secondary.

- Collapse navigation into a top bar or drawer.
- Convert tables into stacked rows or horizontal scroll tables.
- Keep chart cards full width.
- Avoid tiny multi-control toolbars.

## Catfolio-Specific Patterns

### Demo Mode

Demo mode should be visible but quiet.

- Use a small badge near the sidebar app identity.
- Use warning-soft or info-soft, not danger.
- Never show fake data as if it were live user data.

### API Keys And Settings

Settings screens should feel secure and calm.

- Never display saved key values.
- Use status badges such as "Configured" or "Missing".
- Use secondary buttons for test, clear, and refresh actions.
- Destructive credential actions require confirmation.

### AI Analysis

AI analysis should look like a work surface, not a chat toy.

- Prompt presets use compact cards or buttons.
- Responses use readable text blocks with source and scope metadata.
- In demo mode, clearly label responses as demo-safe.
- Do not use decorative AI gradients.

### Portfolio Lab

Portfolio Lab should balance tables, controls, and charts.

- Top controls are compact and grouped.
- Metrics are compact cards.
- Charts use clear legends and source labels.
- Methodology notes should live behind an info affordance, not as large inline blocks.

### Strategy Lab

Strategy Lab should feel like a research bench.

- Code editor area may use monospace and a stronger boundary.
- Run history uses a table or compact list.
- Results use metric cards plus charts.
- AI critique is a secondary panel, not the main visual anchor.

## Implementation Checklist

Before shipping a new Catfolio screen:

1. Does it use the shared color, type, spacing, radius, and elevation tokens?
2. Is there only one primary action per region?
3. Are table and number columns aligned for scanning?
4. Are active, hover, focus, disabled, loading, and empty states covered?
5. Does the sidebar or toolbar match the existing navigation vocabulary?
6. Are tags semantic rather than decorative?
7. Are chart colors tied to meaning?
8. Does the screen work in English and Chinese without text clipping?
9. Does demo mode avoid exposing or implying real user data?
10. Does the UI still feel calm when filled with dense real data?
