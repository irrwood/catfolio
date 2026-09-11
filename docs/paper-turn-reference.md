# Paper turn reference study

Reference: https://github.com/matthewyuart/personalportfolio
Inspected commit: `2374b01b675a9a237bd8990ff5c59d2aa80b5208`.
Live demo: https://matthewyu-dev.vercel.app/

The homepage Sketchbook was opened and a forward turn was inspected in the browser, including its intermediate rotating state. Source inspection covered `components/Sketchbook.tsx` and the sketchbook section of `app/globals.css`. This is a reference study, not a change to the app animation.

## Mechanism verified in source

- Each page asset is a complete photographed/scanned spread. Two clipped halves recreate the spread during a turn.
- One half is static; a half-width flap rotates 180 degrees about the center spine. Forward uses the right half's left edge; reverse mirrors it.
- The flap has separate front/back faces. The back is rotated 180 degrees and back-face visibility is suppressed. Content travels with the paper.
- The book uses 2600px perspective, with ordinary turns lasting 0.85s and a cubic Bezier timing curve (0.42, 0.05, 0.25, 1).
- Page curvature, edge irregularity and much of the paper texture are already present in the source images. This is not a continuously deforming mesh or a physical curl simulation.
- One diffuse shadow sits behind the book. Individual pages do not add separate shadows.
- Incoming stationary content fades in over 0.4s; outgoing stationary content starts fading at 0.6s for 0.22s.
- Mobile keeps full spreads mounted below the temporary flip layers. After landing it swaps the base and holds the flip layer for 90ms, avoiding blank frames. Images are predecoded.
- Repeated clicks complete the current turn and begin the next, protected with a distinct run ID. This is tap-driven, not finger-scrubbed page deformation.
- A desktop-only introduction rapidly riffles through pages; its duration varies from 0.20s to 0.05s, then slows again. Mobile/reduced-motion skip it. It is not appropriate for a single short AI note.

## Application to Catfolio's daily note

Preserve the requested live blurred stock-screen background and one short paragraph. Adapt the mechanism to a horizontal crease: the lower half stays put while the top flap opens upward, with a real blank exterior and the corresponding clipped text on its interior. Text and paper must share the same transform; the current implementation rotates only the background and fades the paragraph, which cannot reproduce this reference's attachment of ink to paper.

Use one normalized progress value for flap angle, back-face visibility, crease shading, and content visibility. Start around 0.8s with smooth deceleration; this is a page settling, distinct from the jelly/rubber-band effect on the 52-week rods. Keep a stable flat base beneath the flap until the final frame is committed. Reflow the live AI text after unfolding; never snapshot an incomplete response and leave stale contents on the final sheet. Reduced Motion should use a brief fade. Closing should reverse the fold before dismissing the blurred modal.

No third-party code, images, fonts or dependencies were copied into the application. The temporary reference checkout is outside the working repository.
