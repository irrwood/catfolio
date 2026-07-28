# Catfolio Design System Rules

These rules apply to every UI change in `v3_backend/app/routes/` and `v3_backend/app/static/`.

## Source of truth

- The current `/lab?ui=v5` page is the visual source of truth.
- Shared tokens and component primitives live in `v3_backend/app/static/design-system.css`.
- Page-specific CSS may control layout and visualization details, but must consume shared variables and must not redefine the visual language.
- Reuse the shared v5 shell from `app/components.py`; do not create page-specific sidebars or top navigation.

## Visual rules

- Use Nunito via `"Nunito Local", "Nunito", sans-serif`.
- Workspace background is `#f7f8fa`; primary surfaces are white.
- Main cards use a 1px `#f1f1f1` border, 20px radius, and no shadow.
- Nested controls use 8–12px radii. Avoid decorative gradients and shadows.
- Primary text is black. Secondary text is `#888`; tertiary text is `#a7a7a7`.
- Green `#2f8a3e` and red `#e40014` are reserved for positive/negative financial states.
- Blue `#708cff` is reserved for chart series and keyboard focus rings.
- Page spacing follows a 10px layout rhythm; card interiors generally use 20px padding.

## Components

- Page titles use the shared 30px/41px heading treatment.
- Use `.v4-card`, `.panel`, or a page-specific top-level card class only when the region is a meaningful surface.
- Use shared button, segmented-control, form-control, table, metric-card, and status treatments from `design-system.css`.
- Tables keep numeric columns right-aligned, use tabular numerals, and avoid vertical rules.
- Charts use transparent plot backgrounds, `#EAEBED` grid/pointer lines, and the Lab chart palette.
- New controls must have visible `:focus-visible` states and must respect `prefers-reduced-motion`.

## Figma-to-code workflow

1. Fetch design context for the exact Figma node.
2. Fetch a screenshot for the same node and state.
3. Translate the output into FastAPI-rendered HTML, plain JavaScript, and shared CSS conventions used by this project.
4. Reuse existing sidebar icons and assets from `v3_backend/app/static/icons/`.
5. Validate the final page in the browser at `?ui=v5` before completion.

## Architecture and testing

- Pages are server-rendered from `v3_backend/app/routes/`; interactions use dependency-light vanilla JavaScript.
- Keep data APIs and UI presentation separate.
- Add or update focused tests in `v3_backend/tests/` for shared design-system wiring and important UI contracts.
- Do not change financial calculations while performing a visual migration.
