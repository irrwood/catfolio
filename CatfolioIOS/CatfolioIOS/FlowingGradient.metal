//  FlowingGradient.metal
//
//  Two slow animated backgrounds for the home page, both analytic (Gaussian
//  falloff, no blur pass) and both with animated film grain against banding:
//
//  - flowingGradient: drifting "aurora" glows — a large soft halo with a
//    bright core and a dimmer secondary glow, each an organic cluster of
//    ellipses, with a prism-like colour split at their edges.
//  - flowingRings: concentric glowing arcs lit by the same drifting light.
//
//  Used from SwiftUI via `.colorEffect(...)` (iOS 17+ / macOS 14+). Both take
//  the same arguments; see FlowingGradientBackground.swift.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

namespace {

// Dave Hoskins' hash — cheap, stable white noise in [0, 1).
float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 rotate(float2 v, float a) {
    float s = sin(a), c = cos(a);
    return float2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// Soft rotated ellipse with Gaussian falloff: 1 at the centre, ~0.37 at `radii`.
float blob(float2 p, float2 center, float2 radii, float angle) {
    float2 d = rotate(p - center, -angle) / radii;
    return exp(-dot(d, d));
}

// Organic glow: three soft ellipses orbiting a shared centre, each with its
// own stretch and continuously turning axis, merged with a screen blend.
// The outline keeps morphing instead of reading as one tilting ellipse.
float cluster(float2 p, float2 center, float2 radii, float t, float seed) {
    float acc = 0.0;
    for (int i = 0; i < 3; ++i) {
        float fi = float(i);
        float ph = seed + fi * 2.094;
        float2 off = radii * 0.55 * float2(sin(t * (0.23 + 0.07 * fi) + ph),
                                           cos(t * (0.19 + 0.05 * fi) + ph * 1.3));
        float s = 1.0 + 0.35 * sin(t * (0.31 + 0.06 * fi) + ph);
        float dir = (i == 1) ? -1.0 : 1.0;
        float a = ph + dir * t * (0.11 + 0.05 * fi) + 0.6 * sin(t * 0.17 + ph);
        float2 r = radii * (0.72 + 0.12 * fi) * float2(s, 1.0 / s);
        float b = blob(p, center + off, r, a);
        acc = 1.0 - (1.0 - acc) * (1.0 - b);
    }
    return acc;
}

// Wandering path built from incommensurate sines so it never visibly loops.
// x is scaled by `aspect` so the blob reaches the left/right edges (and a bit
// beyond) on any screen shape; y stays in height units.
float2 path(float t, float aspect) {
    return float2(
        aspect * (0.52 * sin(t * 0.21) + 0.20 * sin(t * 0.083 + 1.7)),
        0.34 * cos(t * 0.17 + 0.4) + 0.12 * sin(t * 0.113 + 2.1)
    );
}

// Maps a path point's y (which spans about ±0.46) into [bandTop, 0.46].
float2 confine(float2 c, float bandTop) {
    float mid = 0.5 * (bandTop + 0.46);
    float scale = max(0.46 - bandTop, 0.0) / 0.92;
    return float2(c.x, mid + c.y * scale);
}

struct Glow {
    float halo;
    float core;
    float glow;
};

// The three glow layers at `p`. Free: one halo + core wandering the band
// below `bandTop`, and a dim secondary glow. Zoned (clearBand.y > .x): one
// glow above the clear band and one below, handing emphasis over slowly.
Glow glowAt(float2 p, float time, float aspect, float bandTop, float2 clearBand) {
    Glow g;
    if (clearBand.y <= clearBand.x) {
        // The core trails the halo slightly so the hot spot shifts inside
        // the glow instead of sitting dead centre.
        g.halo = cluster(p, confine(path(time, aspect), bandTop), float2(0.34, 0.34), time, 0.0);
        g.core = cluster(p, confine(path(time - 0.9, aspect), bandTop), float2(0.15, 0.15), time - 0.9, 0.0);
        float2 c2 = confine(path(time * 0.8 + 37.0, aspect) * float2(-0.9, -1.0), bandTop);
        g.glow = 0.28 * cluster(p, c2, float2(0.26, 0.34), time, 4.0);
    } else {
        float y0 = clearBand.x - 0.5;
        float y1 = clearBand.y - 0.5;
        float topY = min(0.5 * (-0.5 + y0), y0 - 0.16);
        float botY = max(0.5 * (y1 + 0.5), y1 + 0.16);
        float botAmp = max(0.0, 0.5 * (0.5 - y1) - 0.12);

        float wTop = smoothstep(-0.6, 0.6, sin(time * 0.09 + 1.0));
        float wBot = 1.0 - wTop;

        float2 ct0 = float2(path(time,        aspect).x, topY + 0.04 * sin(time * 0.23));
        float2 ct1 = float2(path(time - 0.9,  aspect).x, topY + 0.04 * sin((time - 0.9) * 0.23));
        float2 cb0 = float2(path(time + 19.0, aspect).x, botY + botAmp * sin(time * 0.19 + 0.7));
        float2 cb1 = float2(path(time + 18.1, aspect).x, botY + botAmp * sin((time - 0.9) * 0.19 + 0.7));

        float topH = cluster(p, ct0, float2(0.38, 0.19), time, 1.0);
        float botH = cluster(p, cb0, float2(0.34, 0.26), time, 5.0);
        g.halo = wTop * topH + wBot * botH;
        g.core = wTop * cluster(p, ct1, float2(0.17, 0.09), time - 0.9, 1.0)
               + wBot * cluster(p, cb1, float2(0.15, 0.12), time - 0.9, 5.0);
        // Keep a faint ember in whichever zone is resting.
        g.glow = 0.30 * (wBot * topH + wTop * botH);
    }
    return g;
}

} // namespace

/// - position:  pixel position (supplied by SwiftUI)
/// - color:     original layer colour (ignored)
/// - size:      view size in points
/// - time:      seconds since the animation started
/// - baseTop / baseBottom: background, blended top to bottom (pass the same
///   colour twice for a flat ground)
/// - haloColor / coreColor: outer glow, hot centre
/// - grain:     film-grain amplitude, ~0.03 is subtle; 0 disables
/// - glowTop:   y in points above which the glow only spills briefly; the
///   glows wander between it and the bottom edge. 0 lets them use the whole
///   view.
/// - fringeColor: the tint of the warm edge the dispersion opens up
///   (pink-violet, like light split by a prism)
/// - dispersion: how far apart the red and blue copies of the glow sit;
///   ~1 is a clear fringe, 0 turns it off
/// - clearBand: (top, bottom) of a horizontal band, as fractions of the view
///   height, that the glow must stay out of (e.g. a chart); glows then live
///   above and below it. When bottom <= top there is no band.
/// - feather:   softness of the band edges, as a fraction of the height
/// - intensity: overall strength of the glow, 0–1 (0.5 is calm, 1 is vivid)
[[ stitchable ]] half4 flowingGradient(float2 position,
                                       half4 color,
                                       float2 size,
                                       float time,
                                       half4 baseTop,
                                       half4 baseBottom,
                                       half4 haloColor,
                                       half4 coreColor,
                                       float grain,
                                       float glowTop,
                                       half4 fringeColor,
                                       float dispersion,
                                       float2 clearBand,
                                       float feather,
                                       float intensity) {
    float aspect = size.x / max(size.y, 1.0);

    // Centred coordinates in height units: y ∈ [-0.5, 0.5], top is negative.
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    float bandY = p.y; // unwarped, so the clear band keeps straight edges

    // Two octaves of domain warp so the glow edges feel organic.
    p += 0.045 * float2(sin(p.y * 5.0 + time * 0.50),
                        sin(p.x * 6.0 - time * 0.37 + 1.3));
    p += 0.018 * float2(sin(p.y * 13.0 - time * 0.71 + 2.0),
                        sin(p.x * 11.0 + time * 0.63));

    // The band the glow centres may occupy, in the same height units as `p`.
    // Centres stay a little below glowTop so the bright middle sits well
    // inside the band rather than on its edge.
    float top = saturate(glowTop / max(size.y, 1.0)) - 0.5;
    bool confined = glowTop > 0.0;
    float bandTop = confined ? top + 0.12 : -0.46;

    // Above glowTop, space is stretched 2.5× before the glows are drawn, so
    // every glow's upward tail shrinks to a short spill that ends along the
    // glow's own curve — not along a straight line at the card edge.
    if (confined && p.y < top) {
        p.y = top - (top - p.y) * 2.5;
    }

    // Dispersion: each colour channel sees the glow shifted a little along
    // a slowly turning axis — red one way, blue the other — the way a lens
    // splits a bright edge. Where they part, one side goes warm (the
    // fringe) and the other cool.
    float2 split = rotate(float2(1.0, 0.0), 0.9 * sin(time * 0.13)) * (0.045 * dispersion);
    Glow gr = glowAt(p - split, time, aspect, bandTop, clearBand);
    Glow gg = glowAt(p,         time, aspect, bandTop, clearBand);
    Glow gb = glowAt(p + split, time, aspect, bandTop, clearBand);
    float3 halo = float3(gr.halo, gg.halo, gb.halo);
    float3 core = float3(gr.core, gg.core, gb.core);
    float glow = gg.glow;

    float mask = 1.0;
    // Hard guarantee: nothing lights the clear band itself.
    if (clearBand.y > clearBand.x) {
        float y0 = clearBand.x - 0.5;
        float y1 = clearBand.y - 0.5;
        float f = max(feather, 0.001);
        mask *= 1.0 - smoothstep(y0 - f, y0 + f, bandY) * (1.0 - smoothstep(y1 - f, y1 + f, bandY));
    }
    // A backstop well above glowTop, so no tail ever reaches the hero; the
    // visible fade is the stretch above, which follows each glow's shape.
    if (confined) {
        mask *= smoothstep(glowTop - 0.22 * size.y, glowTop - 0.04 * size.y, position.y);
    }
    float strength = mask * intensity;
    halo *= strength;
    core *= strength;
    glow *= strength;

    // Strength of the warm edge: where red has arrived and blue not. The
    // core's edge goes pink; the halo's, further out, violet — pink leaning
    // into the halo's blue — so the band runs white, pink, violet, blue.
    float haloFringe = saturate(halo.r - halo.b);
    float coreFringe = saturate(core.r - core.b);

    float3 col = mix(float3(baseTop.rgb), float3(baseBottom.rgb),
                     saturate(position.y / max(size.y, 1.0)));
    col = mix(col, float3(haloColor.rgb), saturate(halo + glow));
    float3 violet = mix(float3(fringeColor.rgb), float3(haloColor.rgb), 0.45);
    col = mix(col, violet, saturate(0.7 * haloFringe));
    col = mix(col, float3(fringeColor.rgb), coreFringe);
    col = mix(col, float3(coreColor.rgb), smoothstep(0.0, 1.0, saturate(core)));

    // Animated grain (also acts as dither against 8-bit banding).
    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;

    return half4(half3(saturate(col)), 1.0h);
}

/// Concentric arcs rising from below the screen, each a thin bright rim
/// with a soft glow falling away beneath it, lit by the same wandering
/// halo as `flowingGradient` so they brighten only where the light passes.
/// The arcs expand slowly; colours split a little at each rim, and the
/// lower sides warm towards `fringeColor`. Same arguments as
/// `flowingGradient`, so the Swift side can switch between the two;
/// `clearBand` and `feather` are not used here, `intensity` scales the light.
[[ stitchable ]] half4 flowingRings(float2 position,
                                    half4 color,
                                    float2 size,
                                    float time,
                                    half4 baseTop,
                                    half4 baseBottom,
                                    half4 haloColor,
                                    half4 coreColor,
                                    float grain,
                                    float glowTop,
                                    half4 fringeColor,
                                    float dispersion,
                                    float2 clearBand,
                                    float feather,
                                    float intensity) {
    float aspect = size.x / max(size.y, 1.0);
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    // A faint warp, so the arcs are not drawn with a compass.
    p += 0.012 * float2(sin(p.y * 5.0 + time * 0.40),
                        sin(p.x * 6.0 - time * 0.30 + 1.3));

    float top = saturate(glowTop / max(size.y, 1.0)) - 0.5;
    bool confined = glowTop > 0.0;
    float bandTop = confined ? top + 0.12 : -0.46;

    // The light: the wandering halo and core, evaluated with the space above
    // glowTop stretched so it ends on its own curve (see flowingGradient).
    float stretch = 1.0 + 0.45 * sin(time * 0.29 + 0.8);
    float angle   = 0.9 * sin(time * 0.13);
    float2 lp = p;
    if (confined && lp.y < top) { lp.y = top - (top - lp.y) * 2.5; }
    float2 c0 = confine(path(time, aspect), bandTop);
    float2 c1 = confine(path(time - 0.9, aspect), bandTop);
    float light = blob(lp, c0, float2(0.44 * stretch, 0.44 / stretch), angle);
    float hot   = blob(lp, c1, float2(0.18 * stretch, 0.18 / stretch), angle);

    // Arcs: centred below the bottom edge, a touch flattened, 0.11 apart,
    // drifting outwards. `d` is how far inside the nearest rim a point is.
    const float2 centre = float2(0.0, 0.70);
    const float spacing = 0.11;
    const float drift = 0.012;
    float r = length((p - centre) * float2(0.85, 1.0));
    float split = 0.0022 * dispersion;

    float3 ground = mix(float3(baseTop.rgb), float3(baseBottom.rgb),
                        saturate(position.y / max(size.y, 1.0)));
    light *= intensity;
    hot *= intensity;
    float lit = 0.18 + 1.4 * light + 1.6 * hot;
    float3 col;
    for (int ch = 0; ch < 3; ch++) {
        // Red sees the arcs slightly further out than green, blue further in.
        float rc = r + float(1 - ch) * split;
        float d = spacing * fract((drift * time - rc) / spacing);
        float rim = exp(-(d / 0.0035) * (d / 0.0035));
        float body = exp(-d / 0.035) * (1.0 - exp(-d / 0.004));
        float c = ground[ch];
        c = mix(c, float(haloColor[ch]), saturate(body * lit * 1.3));
        c = mix(c, float(coreColor[ch]), saturate(body * (hot * 1.5 + light * 0.25) + rim * (0.45 + light)));
        col[ch] = c;
    }

    // Warm light: where red's glow leads blue's at each rim, and across the
    // lower sides of the arcs, as in a lens flare catching the edge.
    float dRed  = spacing * fract((drift * time - (r + split)) / spacing);
    float dBlue = spacing * fract((drift * time - (r - split)) / spacing);
    float dMid  = spacing * fract((drift * time - r) / spacing);
    float edge  = saturate(exp(-dRed / 0.035) - exp(-dBlue / 0.035)) * (light + hot);
    float low   = saturate((p.y - top) / max(0.5 - top, 0.01));
    float side  = saturate(abs(p.x) / 0.35);
    float warm  = saturate(0.45 * edge + 0.8 * exp(-dMid / 0.035) * low * side * (0.3 + light));
    col = mix(col, float3(fringeColor.rgb), warm);

    // Backstop above the card edge, as in flowingGradient.
    if (confined) {
        float mask = smoothstep(glowTop - 0.22 * size.y, glowTop - 0.04 * size.y, position.y);
        col = mix(ground, col, mask);
    }

    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;
    return half4(half3(saturate(col)), 1.0h);
}
