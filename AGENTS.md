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

# iOS app (`CatfolioIOS/`)

## Project file

- Targets use Xcode 16 synchronized folders: every file under `CatfolioIOS/CatfolioIOS/`, `CatfolioIOS/CatfolioIOSTests/` and `CatfolioIOS/CatfolioIOSViewTests/` is in its target automatically. **Do not add `PBXBuildFile` / `PBXFileReference` entries to `project.pbxproj` for new files** — create the file in the folder and it is built. To keep a file out of a target, add it to that folder's `membershipExceptions`.
- `Resources/AssetLogos` and `Resources/catfolio-daily-brief` are copied as folders (`explicitFolders`); every other resource is copied flat into the bundle, so resource file names must be unique.
- `Info.plist`, `CatfolioIOS.entitlements` and `Resources/analyst_history_aapl.json` are excluded from the app target on purpose.

## Tests

- `CatfolioIOSTests/`: pure logic — no `import SwiftUI`. `CatfolioIOSViewTests/`: anything that imports SwiftUI (rendering, layout, interaction). Put a new test in the folder that matches.
- Run one side with a test plan; only that plan's target is built, so a broken file in the other target does not block you:
  - `xcodebuild test -project CatfolioIOS/CatfolioIOS.xcodeproj -scheme CatfolioIOS -testPlan Logic -destination 'platform=iOS Simulator,name=iPhone 17 Pro'`
  - `-testPlan Views` for the view tests; `-testPlan All` (the scheme's default) for both.
- `-only-testing:` alone does not help: it still builds every test target in the plan first.
- Test behaviour in Swift, never by reading source. Do not add Python (or any) tests that open a `.swift` file and assert a string is or is not in it: they pass on a comment, fail on a rename, and check that code was written rather than that it works. Static style rules belong in `scripts/check_ios_design.py`; everything else is an XCTest that calls the real code.
- Run what the change touches:
  1. Every change: build, and `python3 scripts/check_ios_design.py` for UI code.
  2. Logic changed: the related classes in the `Logic` plan (`-only-testing:CatfolioIOSTests/<Class>`).
  3. Views, layout or interaction changed: the related classes in the `Views` plan.
  4. Before a commit or a TestFlight build: both plans in full.
- Keep logs out of the conversation: write the run to a file and read only the summary, opening the full log only when something failed.
  ```sh
  xcodebuild test … > /tmp/test.log 2>&1; status=$?
  grep -E "error:|failed \(|Executed [0-9]+ tests" /tmp/test.log | sort -u | tail -30
  ```
