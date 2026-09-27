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
                                       float intensity,
                                       float4 lightShape,
                                       float blur) {
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
/// `clearBand` and `feather` are not used here, `intensity` scales the light
/// and `blur` (0 sharp, 1 soft) widens the rims into glowing bands.
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
                                    float intensity,
                                    float4 lightShape,
                                    float blur) {
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

    // Arcs: centred below the bottom edge, a touch flattened, 0.17 apart,
    // drifting outwards. `d` is how far inside the nearest rim a point is.
    const float2 centre = float2(0.0, 0.70);
    const float spacing = 0.17;
    const float drift = 0.014;
    float r = length((p - centre) * float2(0.85, 1.0));
    float split = 0.0022 * dispersion;
    float bodyFalloff = 0.035 + 0.02 * blur;

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
        // `blur` widens the rim into a soft band and eases the glow in
        // behind it. The rim is measured to the nearer of this ring and the
        // next, so a wide rim glows into both sides instead of stopping
        // dead where one band wraps into the next.
        float rimWidth = 0.0035 + 0.022 * blur;
        float dd = min(d, spacing - d);
        float rim = exp(-(dd / rimWidth) * (dd / rimWidth)) * (1.0 - 0.45 * blur);
        float body = exp(-d / bodyFalloff) * (1.0 - exp(-d / (0.004 + 0.03 * blur)));
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
    float edge  = saturate(exp(-dRed / bodyFalloff) - exp(-dBlue / bodyFalloff)) * (light + hot);
    float low   = saturate((p.y - top) / max(0.5 - top, 0.01));
    float side  = saturate(abs(p.x) / 0.35);
    float warm  = saturate(0.45 * edge + 0.8 * exp(-dMid / bodyFalloff) * low * side * (0.3 + light));
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

/// One huge, soft light from the top of the screen: a pale mist that falls
/// through steel blue and navy to near black, sampled from the reference
/// frame. The light breathes, sways and carries a slow lobe along its
/// lower edge; its placement and size come from `lightShape`. `intensity` scales the light (1 = the reference; lower keeps the
/// top from going pale, for dark mode). The colour arguments are unused —
/// the ramp is the reference's own — and so are glowTop, dispersion and the
/// clear band; the signature matches `flowingGradient` for the Swift side.
[[ stitchable ]] half4 mistGlow(float2 position,
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
                                float intensity,
                                float4 lightShape,
                                float blur) {
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    // A light warp only: the edge should drift, not ripple.
    p += float2(0.020 * sin(p.y * 3.0 + time * 0.35), 0.014 * sin(p.x * 3.5 - time * 0.27 + 1.3));
    p += float2(0.005 * sin(p.y * 9.0 - time * 0.53 + 2.0), 0.004 * sin(p.x * 8.0 + time * 0.47));

    // The light: a wide Gaussian. lightShape = (centre y, sideways sway,
    // width, height), in height units: day sits high (-0.30) and very wide
    // so it reads as a dome from the top; night sits lower and narrower so
    // the top falls dark and the sway shows.
    float2 centre = float2(lightShape.y * (sin(time * 0.11) + 0.4 * sin(time * 0.047 + 1.0)),
                           lightShape.x + 0.035 * sin(time * 0.17));
    float breathe = 1.0 + 0.05 * sin(time * 0.13 + 0.5);
    float2 d = (p - centre) / (lightShape.zw * breathe);
    float light = exp(-dot(d, d));
    // A slow organic lobe riding the dome's lower edge.
    float2 lobeCentre = float2(centre.x + 0.25 * sin(time * 0.09), centre.y + 0.36);
    float lobe = cluster(p, lobeCentre, float2(0.30, 0.14), time, 2.0);
    light = 1.0 - (1.0 - light) * (1.0 - 0.15 * lobe);
    light *= intensity;

    // Brightness → colour, linearly between stops read off the reference.
    const float stops[7] = { 0.07, 0.28, 0.47, 0.65, 0.80, 0.87, 0.95 };
    const float3 ramp[7] = {
        float3(0.016, 0.020, 0.039),
        float3(0.109, 0.169, 0.251),
        float3(0.208, 0.305, 0.467),
        float3(0.454, 0.560, 0.732),
        float3(0.745, 0.804, 0.894),
        float3(0.854, 0.882, 0.945),
        float3(0.897, 0.925, 0.960),
    };
    float3 col = ramp[0];
    for (int i = 0; i < 6; i++) {
        float t = saturate((light - stops[i]) / (stops[i + 1] - stops[i]));
        col += (ramp[i + 1] - ramp[i]) * t;
    }

    // Grain matters here: a smooth ramp this long bands badly at 8 bits.
    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;
    return half4(half3(saturate(col)), 1.0h);
}

/// One big, soft, wandering halo: a bright organic core with a wide bloom
/// around it, drifting across the upper and middle screen over a faint
/// light from the top. Brightness is mapped through a five-colour ramp,
/// darkest to brightest: baseBottom, fringeColor, haloColor, coreColor,
/// baseTop. `intensity` scales the light (lower for dark mode). glowTop,
/// dispersion and the clear band are unused; the signature matches
/// `flowingGradient` for the Swift side.
[[ stitchable ]] half4 bigHalo(float2 position,
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
                               float intensity,
                               float4 lightShape,
                               float blur) {
    float aspect = size.x / max(size.y, 1.0);
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    float topY = p.y;
    p += float2(0.030 * sin(p.y * 3.0 + time * 0.40), 0.025 * sin(p.x * 3.5 - time * 0.31 + 1.3));
    p += float2(0.008 * sin(p.y * 9.0 - time * 0.60 + 2.0), 0.007 * sin(p.x * 8.0 + time * 0.50));

    float2 centre = float2(aspect * (0.30 * sin(time * 0.13) + 0.10 * sin(time * 0.051 + 1.7)),
                           -0.12 + 0.14 * sin(time * 0.097 + 0.4));
    // The core eases up to the peak rather than sitting on it, so it reads
    // as light, not a flat disc; the bloom is the same shape, twice as wide.
    float core  = 0.92 * pow(cluster(p, centre, float2(0.30, 0.26), time, 3.0), 1.5);
    float bloom = 0.45 * cluster(p, centre, float2(0.60, 0.52), time, 3.0);
    float sky   = 0.28 * exp(-((topY + 0.5) / 0.55) * ((topY + 0.5) / 0.55));
    float light = 1.0 - (1.0 - core) * (1.0 - bloom) * (1.0 - sky);
    light *= intensity;

    const float stops[5] = { 0.05, 0.25, 0.50, 0.78, 0.97 };
    float3 ramp[5] = { float3(baseBottom.rgb), float3(fringeColor.rgb), float3(haloColor.rgb),
                       float3(coreColor.rgb), float3(baseTop.rgb) };
    float3 col = ramp[0];
    for (int i = 0; i < 4; i++) {
        float t = saturate((light - stops[i]) / (stops[i + 1] - stops[i]));
        col += (ramp[i + 1] - ramp[i]) * t;
    }

    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;
    return half4(half3(saturate(col)), 1.0h);
}

/// A wide arch of light across the middle of the screen (Figma 486:6627):
/// sky above, a soft white rim, and inside it a fill that runs from white
/// near the rim to a paler blue deeper in. The arch breathes, sways and
/// rises a little; its rim splits slightly by colour, like the lens
/// aberration on the Figma layer. Colours: baseTop = sky, coreColor = rim,
/// haloColor = the deep inside. glowTop, fringeColor, the clear band and
/// intensity are unused; the signature matches `flowingGradient`.
[[ stitchable ]] half4 archGlow(float2 position,
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
                                float intensity,
                                float4 lightShape,
                                float blur) {
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    p += float2(0.012 * sin(p.y * 4.0 + time * 0.35), 0.010 * sin(p.x * 5.0 - time * 0.28 + 1.3));

    float2 centre = float2(0.04 * sin(time * 0.12), 0.53 + 0.02 * sin(time * 0.17));
    float breathe = 1.0 + 0.03 * sin(time * 0.21 + 0.6);
    float2 radii = float2(0.36, 0.50) * breathe;

    float3 sky = float3(baseTop.rgb);
    float3 rimColor = float3(coreColor.rgb);
    float3 deepColor = float3(haloColor.rgb);
    float3 col;
    for (int ch = 0; ch < 3; ch++) {
        float q = length((p - centre) / radii);
        // Distance past the arch's edge in height units; red sees the rim
        // a little further out than green, blue a little further in.
        float d = (q - 1.0) * radii.y + float(1 - ch) * 0.010 * dispersion;
        float rim = exp(-(d / 0.12) * (d / 0.12));
        float inside = saturate(0.5 - d / 0.16);
        float deep = saturate((1.0 - q) * 2.4);
        float fill = mix(rimColor[ch], deepColor[ch], deep);
        float c = mix(sky[ch], fill, inside);
        col[ch] = mix(c, rimColor[ch], saturate(rim * 0.95));
    }

    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;
    return half4(half3(saturate(col)), 1.0h);
}

/// Bright, pearly rings: the arcs of `flowingRings` with near-white rims,
/// bands in a deeper shade of the sky (haloColor) instead of deep blue, and
/// a sheen along each rim that shifts between cyan, pink and peach — along
/// the arc, from ring to ring, and slowly over time. Blur grows towards the
/// top: the lowest rings stay fairly crisp, the higher ones melt into soft
/// light. Colours: baseTop/baseBottom = ground, haloColor = bands,
/// coreColor = rims; `blur` scales the softness (1 = default).
[[ stitchable ]] half4 brightRings(float2 position,
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
                                   float intensity,
                                   float4 lightShape,
                                   float blur) {
    float aspect = size.x / max(size.y, 1.0);
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    p += 0.012 * float2(sin(p.y * 5.0 + time * 0.40),
                        sin(p.x * 6.0 - time * 0.30 + 1.3));

    float top = saturate(glowTop / max(size.y, 1.0)) - 0.5;
    bool confined = glowTop > 0.0;
    float bandTop = confined ? top + 0.12 : -0.46;

    // The light that brightens the rings as it passes (as in flowingRings).
    float stretch = 1.0 + 0.45 * sin(time * 0.29 + 0.8);
    float angle   = 0.9 * sin(time * 0.13);
    float2 lp = p;
    if (confined && lp.y < top) { lp.y = top - (top - lp.y) * 2.5; }
    float light = blob(lp, confine(path(time, aspect), bandTop), float2(0.44 * stretch, 0.44 / stretch), angle);
    float hot   = blob(lp, confine(path(time - 0.9, aspect), bandTop), float2(0.18 * stretch, 0.18 / stretch), angle);
    light *= intensity;
    hot *= intensity;

    const float2 centre = float2(0.0, 0.70);
    const float spacing = 0.17;
    const float drift = 0.014;
    float r0 = length((p - centre) * float2(0.85, 1.0));
    float split = 0.006 * dispersion;

    // Softness rises from 0.35× at the bottom to 1.8× near the top.
    float up = saturate((0.55 - p.y) / 0.9);
    float b = blur * (0.35 + 1.45 * up);
    float rimWidth = 0.004 + 0.022 * b;
    float bodyFalloff = 0.035 + 0.02 * b;
    float onset = 0.004 + 0.03 * b;

    float3 ground = mix(float3(baseTop.rgb), float3(baseBottom.rgb),
                        saturate(position.y / max(size.y, 1.0)));
    float lit = 0.25 + 1.3 * light + 1.5 * hot;
    float3 col;
    float3 rims;
    for (int ch = 0; ch < 3; ch++) {
        float r = r0 + float(1 - ch) * split;
        float d = spacing * fract((drift * time - r) / spacing);
        float dd = min(d, spacing - d);
        float rim = exp(-(dd / rimWidth) * (dd / rimWidth)) * (1.0 - 0.3 * saturate(b - 0.5));
        float body = exp(-d / bodyFalloff) * (1.0 - exp(-d / onset));
        float c = mix(ground[ch], float(haloColor[ch]), saturate(body * lit * 1.1));
        c = mix(c, float(coreColor[ch]), saturate(rim * (0.6 + light) + body * (hot * 1.2 + light * 0.2)));
        col[ch] = c;
        rims[ch] = rim;
    }

    // Pearly sheen, kept to cyan, pink and peach (no violet): its hue runs
    // along the arc, steps from ring to ring and drifts over time; it is
    // strongest where the colour channels part at the rim.
    float arcAngle = atan2(p.x, centre.y - p.y);
    float ring = floor((drift * time - r0) / spacing);
    float h = arcAngle * 0.9 + time * 0.05 + ring * 0.37;
    const float3 cyan  = float3(0.72, 0.95, 1.00);
    const float3 pink  = float3(1.00, 0.82, 0.90);
    const float3 peach = float3(1.00, 0.90, 0.76);
    float3 sheen = mix(cyan, pink, 0.5 + 0.5 * cos(6.2832 * h));
    sheen = mix(sheen, peach, 0.6 * (0.5 + 0.5 * cos(6.2832 * (h * 0.7 + 0.3))));
    float edge = saturate(abs(rims.r - rims.b) * 2.2 + rims.g * 0.35) * (0.4 + light + hot);
    col = mix(col, sheen, 0.6 * saturate(edge));

    if (confined) {
        float mask = smoothstep(glowTop - 0.22 * size.y, glowTop - 0.04 * size.y, position.y);
        col = mix(ground, col, mask);
    }

    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;
    return half4(half3(saturate(col)), 1.0h);
}

/// Big waves: a few wide rings rising from below the screen that grow as
/// they travel — the phase runs as r^0.55, so the spacing between waves
/// widens outwards. Below `glowTop` (the card's top) they keep their
/// colour; past it their blur rises up to 4× and their colour fades back
/// into the ground over about 30% of the screen height, so each wave
/// dissolves into the sky above the card. Lit by the same drifting light
/// as `flowingRings`, with the same colours; `blur` is unused.
[[ stitchable ]] half4 waveRings(float2 position,
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
                                 float intensity,
                                 float4 lightShape,
                                 float blur) {
    float aspect = size.x / max(size.y, 1.0);
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    p += 0.012 * float2(sin(p.y * 5.0 + time * 0.40),
                        sin(p.x * 6.0 - time * 0.30 + 1.3));

    // The card top, or a little above the middle when there is none.
    float top = glowTop > 0.0 ? saturate(glowTop / max(size.y, 1.0)) - 0.5 : -0.1;
    float bandTop = top + 0.12;

    float stretch = 1.0 + 0.45 * sin(time * 0.29 + 0.8);
    float angle   = 0.9 * sin(time * 0.13);
    float light = blob(p, confine(path(time, aspect), bandTop), float2(0.53 * stretch, 0.53 / stretch), angle);
    float hot   = blob(p, confine(path(time - 0.9, aspect), bandTop), float2(0.20 * stretch, 0.20 / stretch), angle);
    light *= intensity;
    hot *= intensity;

    const float2 centre = float2(0.0, 0.72);
    const float k = 0.55;       // phase ∝ r^k: k < 1 widens the waves outwards
    const float scale = 0.26;   // overall wave size
    const float speed = 0.045;  // waves per second
    float r0 = length((p - centre) * float2(0.85, 1.0));
    // The spacing between waves at this radius (dr per unit of phase).
    float spacing = scale * pow(max(r0, 0.001), 1.0 - k) / k;
    float sizeScale = spacing / 0.2;

    // Past the card top: 0 at the edge, 1 about 30% of the height above.
    float above = saturate((top - p.y) / 0.30);
    float soft = 1.0 + 3.0 * above;
    float fade = 1.0 - 0.9 * pow(above, 0.8);
    float split = 0.004 * dispersion * (1.0 + above);

    float rimWidth = (0.006 + 0.02 * soft) * sizeScale;
    float bodyFalloff = (0.05 + 0.03 * soft) * sizeScale;
    float onset = (0.006 + 0.03 * soft) * sizeScale;

    float3 ground = mix(float3(baseTop.rgb), float3(baseBottom.rgb),
                        saturate(position.y / max(size.y, 1.0)));
    float lit = 0.25 + 1.3 * light + 1.4 * hot;
    float3 col;
    float3 bodies;
    for (int ch = 0; ch < 3; ch++) {
        float r = max(r0 + float(1 - ch) * split, 0.001);
        float psi = pow(r, k) / scale - speed * time;
        float d = fract(-psi) * spacing;              // inside the nearest rim
        float dd = min(d, spacing - d);
        float rim = exp(-(dd / rimWidth) * (dd / rimWidth)) * (1.0 - 0.25 * saturate(soft - 1.0));
        float body = exp(-d / bodyFalloff) * (1.0 - exp(-d / onset));
        float c = mix(ground[ch], float(haloColor[ch]), saturate(body * lit * 1.2));
        c = mix(c, float(coreColor[ch]), saturate(body * (hot * 1.1 + light * 0.2) + rim * (0.3 + 0.7 * light)));
        col[ch] = c;
        bodies[ch] = body;
    }
    float warm = saturate(0.5 * saturate(bodies.r - bodies.b) * (light + hot));
    col = mix(col, float3(fringeColor.rgb), warm);

    // Colour fades back into the ground past the card top.
    col = mix(ground, col, fade);

    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;
    return half4(half3(saturate(col)), 1.0h);
}
