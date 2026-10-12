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

// Dense separable sampling for the heatmap's text and logos: bilinear pairs
// of adjacent physical pixels. Sampling once per point instead left 2–3
// pixel gaps on a 3× screen, and the two passes stacked the aliasing of
// tile edges and text into a diamond pattern.
[[ stitchable ]] half4 performanceHeroBlur(
    float2 position, SwiftUI::Layer layer, float2 size,
    float topEnd, float lowerStart, float lowerEnd,
    float strength, float displayScale, float rasterScale, float2 direction
) {
    // The artwork fades out completely below this boundary. Blurring
    // those pixels spends GPU time on a result that cannot be seen.
    // The horizontal pass must retain the vertical pass's sampling margin.
    float hiddenStart = lowerEnd + (direction.x > 0.5f ? 45.1f * rasterScale : 0.0f);
    if ((strength >= 0.999f && position.y >= hiddenStart) || strength < 0.001f)
        return layer.sample(position);
    float topProgress = clamp(1.0f - position.y / max(topEnd, 0.001f), 0.0f, 1.0f);
    float lowerProgress = clamp((position.y - lowerStart) / max(lowerEnd - lowerStart, 0.001f), 0.0f, 1.0f);
    float radius = max(20.0f * topProgress, 44.1f * lowerProgress) * strength * rasterScale;
    if (radius < 0.25f) return layer.sample(position);

    float scale = max(displayScale, 1.0f);
    float extent = radius * scale;
    int support = int(ceil(extent));
    float4 sum = float4(layer.sample(position));
    float total = 1.0f;
    // The Gaussian weights follow a recurrence. Compute exponentials once
    // per fragment instead of twice per sample pair; keep the same dense
    // physical-pixel taps so text and tile edges do not alias.
    float k = 2.0f / (radius * radius * scale * scale);
    float wa = exp(-k);
    float wb = exp(-4.0f * k);
    float ratioA = exp(-8.0f * k);
    float ratioB = exp(-12.0f * k);
    float ratioStep = ratioA;
    for (int i = 1; i <= support; i += 2) {
        float a = float(i) / scale;
        float b = float(i + 1) / scale;
        // Fade in the outermost physical pixel continuously. Adding its
        // full Gaussian weight when ceil(radius) changes paints horizontal
        // bands as the blur grows, especially around translucent tile edges.
        float firstWeight = wa * smoothstep(0.0f, 1.0f, extent - float(i - 1));
        float pairedWeight = wb * smoothstep(0.0f, 1.0f, extent - float(i));
        float weight = firstWeight + pairedWeight;
        float2 offset = direction * ((a * firstWeight + b * pairedWeight) / weight);
        sum += (float4(layer.sample(position + offset)) + float4(layer.sample(position - offset))) * weight;
        total += 2.0f * weight;
        wa *= ratioA;
        wb *= ratioB;
        ratioA *= ratioStep;
        ratioB *= ratioStep;
    }
    return half4(sum / total);
}
