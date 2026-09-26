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
/// - baseColor / haloColor / coreColor: background, outer glow, hot centre
/// - grain:     film-grain amplitude, ~0.03 is subtle; 0 disables
[[ stitchable ]] half4 flowingGradient(float2 position,
                                       half4 color,
                                       float2 size,
                                       float time,
                                       half4 baseColor,
                                       half4 haloColor,
                                       half4 coreColor,
                                       float grain) {
    float aspect = size.x / max(size.y, 1.0);

    // Centred coordinates in height units: y ∈ [-0.5, 0.5].
    float2 p = (position - 0.5 * size) / max(size.y, 1.0);

    // Gentle domain warp so the blob edges feel organic rather than elliptical.
    p += 0.035 * float2(sin(p.y * 6.0 + time * 0.50),
                        sin(p.x * 7.0 - time * 0.37 + 1.3));

    // Shape: breathes between tall-narrow and wide-short, and slowly tilts.
    float stretch = 1.0 + 0.45 * sin(time * 0.29 + 0.8);
    float angle   = 0.9 * sin(time * 0.13);

    // Main halo + core. The core trails the halo slightly so the hot spot
    // shifts inside the glow instead of sitting dead centre.
    float2 c0 = path(time, aspect);
    float2 c1 = path(time - 0.9, aspect);
    float halo = blob(p, c0, float2(0.34 * stretch, 0.34 / stretch), angle);
    float core = blob(p, c1, float2(0.15 * stretch, 0.15 / stretch), angle);

    // Dimmer secondary glow on a different path, for depth.
    float2 c2 = path(time * 0.8 + 37.0, aspect) * float2(-0.9, -1.0);
    float glow = 0.28 * blob(p, c2, float2(0.26, 0.34), -angle);

    float3 col = float3(baseColor.rgb);
    col = mix(col, float3(haloColor.rgb), saturate(halo + glow));
    col = mix(col, float3(coreColor.rgb), smoothstep(0.0, 1.0, core));

    // Animated grain (also acts as dither against 8-bit banding).
    float n = hash12(position + fract(time * 7.0) * float2(97.0, 131.0)) - 0.5;
    col += n * grain;

    return half4(half3(saturate(col)), 1.0h);
}
