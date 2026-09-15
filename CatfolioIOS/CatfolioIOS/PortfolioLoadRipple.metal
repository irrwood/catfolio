#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// A shallow wavefront crosses the viewport from top to bottom. The packet
// starts and ends outside the image so neither endpoint snaps into place.
[[ stitchable ]] half4 portfolioLoadRipple(
    float2 position,
    SwiftUI::Layer layer,
    float2 size,
    float elapsed,
    float duration
) {
    if (elapsed <= 0.0 || elapsed >= duration) {
        return layer.sample(position);
    }

    float progress = elapsed / duration;
    float across = (position.x - size.x * 0.5) / max(size.x * 0.5, 1.0);
    float front = mix(-128.0, size.y + 146.0, progress);
    float distance = position.y + 18.0 * across * across - front;
    if (abs(distance) > 128.0) {
        return layer.sample(position);
    }

    float envelope = exp(-0.5 * pow(distance / 32.0, 2.0));
    float endFade = smoothstep(0.0, 0.08, progress)
        * smoothstep(0.0, 0.08, 1.0 - progress);
    float edgeFade = smoothstep(0.0, 12.0, position.y)
        * smoothstep(0.0, 12.0, size.y - position.y);
    float wave = sin(distance * 0.10);
    float displacement = 5.0 * wave * envelope * endFade * edgeFade;
    float2 samplePosition = position + float2(displacement * across * 0.12, displacement);
    samplePosition = clamp(samplePosition, float2(0.5), max(float2(0.5), size - 0.5));

    half4 color = layer.sample(samplePosition);
    half refraction = half(0.035 * cos(distance * 0.10) * envelope * endFade * edgeFade);
    color.rgb = clamp(color.rgb + refraction * color.a, half3(0.0), half3(color.a));
    return color;
}
