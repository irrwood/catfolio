#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Figma's handle defines a spatial axis, not a blend between two images.
// Project each pixel onto that axis and increase the sampling radius from
// zero at the inner handle to 18.1 points at the lower-left handle.
[[ stitchable ]] half4 returnsProgressiveBlur(
    float2 position, SwiftUI::Layer layer, float2 size,
    float2 clearPoint, float2 blurredPoint, float maximumRadius
) {
    float2 origin = clearPoint * size;
    float2 axis = (blurredPoint - clearPoint) * size;
    float progress = clamp(dot(position - origin, axis) / max(dot(axis, axis), 0.001f), 0.0f, 1.0f);
    float radius = maximumRadius * progress;
    if (radius < 0.25f) return layer.sample(position);

    // A single spatially varying Gaussian avoids the residual sharp edge
    // that remains when a fixed blur is cross-faded over a crisp image.
    half4 sum = half4(0);
    float total = 0;
    for (int y = -4; y <= 4; ++y) {
        for (int x = -4; x <= 4; ++x) {
            float2 offset = float2(x, y) / 4.0f;
            float weight = exp(-2.0f * dot(offset, offset));
            float2 samplePoint = clamp(position + offset * radius, float2(0.5f), max(size - 0.5f, float2(0.5f)));
            sum += layer.sample(samplePoint) * half(weight);
            total += weight;
        }
    }
    return sum / half(total);
}

// Dense separable sampling for the heatmap's text and logos. The old 9×9
// kernel left gaps of up to 11pt at a 44pt radius, repeating fine details.
// Pair adjacent physical pixels using bilinear filtering, rather than
// spreading a fixed number of taps farther apart as the radius grows.
[[ stitchable ]] half4 performanceHeroBlur(
    float2 position, SwiftUI::Layer layer, float2 size,
    float topEnd, float lowerStart, float lowerEnd,
    float strength, float displayScale, float2 direction
) {
    float topProgress = clamp(1.0f - position.y / max(topEnd, 0.001f), 0.0f, 1.0f);
    float lowerProgress = clamp((position.y - lowerStart) / max(lowerEnd - lowerStart, 0.001f), 0.0f, 1.0f);
    float radius = max(20.0f * topProgress, 44.1f * lowerProgress) * strength;
    if (radius < 0.25f) return layer.sample(position);

    float scale = max(displayScale, 1.0f);
    int support = int(ceil(radius * scale));
    float4 sum = float4(layer.sample(position));
    float total = 1.0f;
    for (int i = 1; i <= support; i += 2) {
        float a = float(i) / scale;
        float b = float(i + 1) / scale;
        float wa = exp(-2.0f * a * a / (radius * radius));
        float wb = i + 1 <= support ? exp(-2.0f * b * b / (radius * radius)) : 0.0f;
        float weight = wa + wb;
        float2 offset = direction * ((a * wa + b * wb) / weight);
        sum += (float4(layer.sample(position + offset)) + float4(layer.sample(position - offset))) * weight;
        total += 2.0f * weight;
    }
    return half4(sum / total);
}
