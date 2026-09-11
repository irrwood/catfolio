# Daily price move paper

Visual references: Figma `EtNSXmasS8lz9JzrWUoMd9`, node `241:45228`, followed by the user-supplied Paper Flip Lab demo at https://qian-paper-flip-lab.base00007.chatgpt.site/ and its HTML/CSS/JS supplied on 2026-09-11.

## Presentation and motion

The stock header opens a transparent full-screen host without the system's bottom-up modal transition. A full-screen UIKit ultra-thin blur is scrubbed with the paper's position. The button's global frame supplies the origin for a 0.55s expanding paper entrance; no separate question text flies out. The original stock screen stays underneath. Downward dragging folds the paper over 145pt; at 190pt it gives one soft haptic and exits downward. Upward dragging retains the open pose and exits at -170pt. Below either threshold, release returns the paper. Closing through the bottom-center X folds and exits downward. Both exits continuously clear the blur as the paper travels away, then dismiss without a modal slide.

The short note has a cover, an inside heading, and the AI paragraph on the lower paper. Both halves share one progress value and one horizontal hinge. The demo pose is adapted: lower = 90 - 42p; upper = 90 + 78p; camera = -54 + 36p. At rest both halves have symmetric 30° inclinations after the camera rotation, keeping their outer edges visually balanced. The paper stays level with no in-plane tilt. Both hinge corners are square; only the outside corners use a 20pt radius.

`SecurityPaperPlane` projects each plane after offsetting along its local normal, rotating around its hinge, applying the camera, and applying perspective. This reproduces the reference's `rotateX(angle) translateZ(depth)` order. Adjacent depths remain separated even when closed. The front/back visibility is evaluated from the combined plane/camera orientation each frame; text belongs to the relevant face and rotates with it.

Spring integration uses stiffness 100 and damping 9.5 for a more visible opening rebound, a monotonic clock, full-speed spring integration after the paper has traveled halfway from the button, frame deltas capped at 0.032s, progress clamped to 0...1.2, and the same position/velocity completion thresholds. Only opening can overshoot; closing stops at zero. Dragging interrupts settling using the current visible progress; release below the distance threshold springs the fold open again. Gesture coordinates are fixed to the full-screen stage. Reduced Motion switches directly to the final pose. Tasks stop when the view disappears.

Paper is inset enough for its perspective and uses two decorative thickness edges, not additional AI-content pages. The paper has no scroll containers. Short body text fits the lower half, with font scaling for longer cached notes. Source links sit in subdued caption text at the bottom of the blurred backdrop, using the same 44pt horizontal inset as the paper. The paper rests 20pt above center. The bottom-center close button uses interactive Liquid Glass on iOS 26 and material on older systems. The cover uses the existing logo dominant-color extractor and contrasting ink, with a small logo and a large company name only; no question, divider, ticker, or date. Larger type increases both halves together. One composited soft shadow sits behind the book.

## Data

The AI request freezes the latest dated market session and previous close from `chartDailyPoints`, independently of chart range/scrubbing. Its session is shown using relative time, such as today, yesterday, or last week. The bundled catfolio-daily-brief Skill selects price-move, mixed, or company-update focus from shared routing.json thresholds and an optional prior-20-session median absolute daily move. Stale sessions use their actual dates. No account, quantity, cost, or P&L is sent.

`SecurityDailyMoveStore` prefers an eligible connected Codex native search; acceptance requires a completed search event and parsed sources. Otherwise the existing public-news body fetcher supplies dated articles to the configured provider. Missing evidence returns a short honest finding. Responses request one or two sentences, up to 100 Chinese characters or 50 English words, with relative event dates in prose. Fallback citations must belong to supplied documents. Native-search factual support remains model-grounded, not an independent causality audit.

Repeated taps share a request; dismissal allows research to finish. Notes are reused for 15 minutes per exact quote context and language. Errors expose retry.

## Validation

Focused simulator tests cover a stationary full-screen host at 100ms, 320pt/402pt layouts, common hinge positions through the whole turn, finite projection during spring overshoot, and distinct local-normal layers while closed. Synthetic text is used for visual fixtures; no live AI request is required. Earlier data tests cover daily context, search completion, response bounds, and request deduplication.

Latest visual/motion suite: `/tmp/CatfolioPaperGesture.xcresult`. Gesture tests cover fold-before-dismiss ordering, both distance thresholds, position-linked blur, and a visibly inclined lower page.

## Animation resource lifecycle

Interactive blur exists only between 0 and 1 progress. At either endpoint its animator is stopped and released, leaving a static effect or no effect. Detaching the blur view from its window and dismantling it both clear the effect and animator, including interrupted exits. Paper motion tasks are cleared when finished or dismissed; spring integration also has a 3-second simulated-time upper bound. Regression coverage includes ten blur open/close cycles, detachment during scrubbing, and resource checks after dismissal of the actual full-screen paper host.

The button origin is now sampled synchronously from a weak UIKit view reference at tap time. There is no `onGeometryChange` publisher on the price section: scrolling must not assign SwiftUI state and recompute the price chart or repeatedly sort historical prices just to track the paper origin. The captured rectangle remains frozen throughout presentation. `SecurityPaperSourceAnchorTests` checks scrolling, capture, and release of the source view.

Available body text is displayed in full immediately, including cached responses. Only the loading label has a typewriter/shimmer animation; the answer itself never types in.

Entrance uses the original cubic ease-out over 0.55s. The paper stays folded for the first half of its spatial travel, then begins its opening spring once; the trigger is based on position rather than half of elapsed time. The modal item contains both the quote and the tap's rectangle in one immutable request. Invalid origins are rejected before presenting; the paper no longer falls back to screen center.

While research is loading, “正在思考” / “Thinking” types in at 100ms per character, then a subtle highlight sweeps over the glyphs every 1.6s. The 30fps timeline is scoped to that label and exists only while loading, fully entered, and not closing. The spinner is removed. Reduced Motion uses a static label.

## Daily interpretation Skill

Canonical instructions are bundled at `CatfolioIOS/Resources/catfolio-daily-brief/SKILL.md`; Codex discovers the same folder via `~/.codex/skills/catfolio-daily-brief`. `references/routing.json` is the shared configuration read by native routing and included in the prompt. Thresholds are product choices, not market standards. The history baseline excludes the explained session and requires at least 15 valid prior returns. Recent-update fallback evidence starts with 7 days and expands to 30 days when no readable documents are available. Price explanation retains the quote-day anchor; publication times are supplied separately for causal time checks. Bundle wiring and routing boundaries are covered by native tests. `references/cases.json` additionally records synthetic semantic counterexamples for future model evaluations; deterministic routing tests do not prove model compliance with causal rules.
