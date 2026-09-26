//  FlowingGradient.metal
//
//  A slow, drifting "aurora blob" background: one large soft halo with a
//  bright core wandering across (and partly off) the screen, a dimmer
//  secondary glow, and animated film grain to hide banding on dark
//  gradients. Everything is analytic (Gaussian falloff), so there is no
//  real blur pass and the cost is a handful of ALU ops per pixel.
//
//  Used from SwiftUI via `.colorEffect(ShaderLibrary.flowingGradient(...))`
//  (iOS 17+ / macOS 14+). See FlowingGradientBackground.swift.

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

} // namespace

/// - position:  pixel position (supplied by SwiftUI)
/// - color:     original layer colour (ignored)
/// - size:      view size in points
/// - time:      seconds since the animation started
/// - baseTop / baseBottom: background, blended top to bottom (pass the same
///   colour twice for a flat ground)
/// - haloColor / coreColor: outer glow, hot centre
/// - grain:     film-grain amplitude, ~0.03 is subtle; 0 disables
/// - clearBand: (top, bottom) of a horizontal band, as fractions of the view
///              height, that the glow must stay out of (e.g. a chart). When
///              bottom <= top the glow roams the whole screen instead.
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
                                       float2 clearBand,
                                       float feather,
                                       float intensity) {
    float aspect = size.x / max(size.y, 1.0);

    // Centred coordinates in height units: y ∈ [-0.5, 0.5], top is negative.
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);
    float bandY = p.y; // unwarped, so the clear band keeps straight edges

    // Gentle domain warp so the blob edges feel organic rather than elliptical.
    p += 0.045 * float2(sin(p.y * 5.0 + time * 0.50),
                        sin(p.x * 6.0 - time * 0.37 + 1.3));
    p += 0.018 * float2(sin(p.y * 13.0 - time * 0.71 + 2.0),
                        sin(p.x * 11.0 + time * 0.63));

    float halo, core, glow;
    if (clearBand.y <= clearBand.x) {
        // Free roaming. The core trails the halo slightly so the hot spot
        // shifts inside the glow instead of sitting dead centre.
        halo = cluster(p, path(time, aspect),       float2(0.34, 0.34), time, 0.0);
        core = cluster(p, path(time - 0.9, aspect), float2(0.15, 0.15), time - 0.9, 0.0);

        // Dimmer secondary glow on a different path, for depth.
        float2 c2 = path(time * 0.8 + 37.0, aspect) * float2(-0.9, -1.0);
        glow = 0.28 * cluster(p, c2, float2(0.26, 0.34), time, 4.0);
    } else {
        // Zoned: one glow above the band, one below it. The light never
        // crosses the band; instead emphasis slowly hands over between zones
        // while each glow drifts sideways within its own zone.
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

        float2 topHalo = float2(0.38, 0.19);
        float2 topCore = float2(0.17, 0.09);
        float2 botHalo = float2(0.34, 0.26);
        float2 botCore = float2(0.15, 0.12);

        float topH = cluster(p, ct0, topHalo, time, 1.0);
        float botH = cluster(p, cb0, botHalo, time, 5.0);
        halo = wTop * topH + wBot * botH;
        core = wTop * cluster(p, ct1, topCore, time - 0.9, 1.0)
             + wBot * cluster(p, cb1, botCore, time - 0.9, 5.0);
        // Keep a faint ember in whichever zone is resting.
        glow = 0.30 * (wBot * topH + wTop * botH);

        // Hard guarantee: nothing lights the band itself.
        float f = max(feather, 0.001);
        float inBand = smoothstep(y0 - f, y0 + f, bandY) * (1.0 - smoothstep(y1 - f, y1 + f, bandY));
        float mask = 1.0 - inBand;
        halo *= mask;
        core *= mask;
        glow *= mask;
    }

    halo *= intensity;
    glow *= intensity;
    core *= intensity;

    float3 col = mix(float3(baseTop.rgb), float3(baseBottom.rgb),
                     saturate(position.y / max(size.y, 1.0)));
    col = mix(col, float3(haloColor.rgb), saturate(halo + glow));
    col = mix(col, float3(coreColor.rgb), smoothstep(0.0, 1.0, saturate(core)));

    // Animated grain (also acts as dither against 8-bit banding).
    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;

    return half4(half3(saturate(col)), 1.0h);
}
