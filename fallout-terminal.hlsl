// Fallout / Pip-Boy inspired CRT shader for Windows Terminal.
// Original implementation; no game assets are used.

struct PSInput
{
    float4 pos : SV_POSITION;
    float2 uv  : TEXCOORD0;
};

Texture2D shaderTexture : register(t0);
SamplerState samplerState : register(s0);

cbuffer PixelShaderSettings : register(b0)
{
    float Time;
    float Scale;
    float2 Resolution;
    float4 Background;
};

// -----------------------------------------------------------------------------
// User settings
// -----------------------------------------------------------------------------

// 0 = preserve palette colors, 1 = apply Fallout phosphor color grading.
#define FALLOUT_COLOR_MODE       0

#define ENABLE_CURVATURE         1
#define ENABLE_GLOW              1
#define ENABLE_SCANLINES         1
#define ENABLE_NOISE             1
#define ENABLE_GLITCHES          0
#define ENABLE_VIGNETTE          0

#define PHOSPHOR_COLOR            float3(0.07, 1.00, 0.15)
#define CURVATURE_AMOUNT          0.035

// Pull the terminal texture away from the dark CRT rim so edge text stays readable.
#define CONTENT_INSET             float2(0.012, 0.050)

#define GLOW_STRENGTH             0.38
#define SCANLINE_STRENGTH         0.26
#define NOISE_STRENGTH            0.014

// Strong, wide oval vignette like an old recessed terminal screen.
#define VIGNETTE_STRENGTH         0.82
#define VIGNETTE_INNER_RADIUS     0.35
#define VIGNETTE_OUTER_RADIUS     1.30
#define VIGNETTE_HORIZONTAL_SCALE 0.75
#define VIGNETTE_EDGE_SOFTNESS    0.025
#define BLACK_LEVEL               0.016
#define BRIGHTNESS                1.22
#define COLOR_SATURATION          1.35

// Increase for more frequent horizontal signal tears. Recommended: 0.0-0.08.
#define GLITCH_STRENGTH           0.012
#define GLITCH_DISPLACEMENT       0.004

static const float PI = 3.14159265359;

float hash12(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float luminance(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

float2 curveScreen(float2 uv)
{
    float2 p = uv * 2.0 - 1.0;
    float2 bend = float2(p.y * p.y, p.x * p.x);
    p *= 1.0 + CURVATURE_AMOUNT * bend;
    return p * 0.5 + 0.5;
}

float2 fitContentInsideScreen(float2 uv)
{
    float2 visibleArea = 1.0 - CONTENT_INSET * 2.0;
    return (uv - CONTENT_INSET) / visibleArea;
}

float screenVignette(float2 uv)
{
    float2 centered = uv * 2.0 - 1.0;
    centered.x *= VIGNETTE_HORIZONTAL_SCALE;

    float radius = dot(centered, centered);
    float oval = 1.0 - VIGNETTE_STRENGTH * smoothstep(
        VIGNETTE_INNER_RADIUS, VIGNETTE_OUTER_RADIUS, radius);

    // Fade the extreme rim to black without making the whole image blurry.
    float2 distanceToEdge = min(uv, 1.0 - uv);
    float rim = smoothstep(0.0, VIGNETTE_EDGE_SOFTNESS,
        min(distanceToEdge.x, distanceToEdge.y));

    return saturate(oval * rim);
}

float rollingRefresh(float2 uv)
{
    float beam = frac(Time * 0.085);
    float distanceToBeam = abs(uv.y - beam);
    distanceToBeam = min(distanceToBeam, 1.0 - distanceToBeam);
    return 1.0 + 0.055 * (1.0 - smoothstep(0.0, 0.075, distanceToBeam));
}

float2 addSignalInstability(float2 uv)
{
#if ENABLE_GLITCHES
    float band = floor(uv.y * 120.0);
    float timeBlock = floor(Time * 5.0);
    float randomBand = hash12(float2(band, timeBlock));
    float active = step(1.0 - GLITCH_STRENGTH, randomBand);
    float displacement = (hash12(float2(timeBlock, band + 17.0)) - 0.5) *
        GLITCH_DISPLACEMENT;
    uv.x += displacement * active;

    // Very small continuous analog drift keeps the image from looking digital.
    uv.x += sin(uv.y * 22.0 + Time * 1.7) * 0.00035;
#endif
    return uv;
}

float3 sampleGlow(float2 uv, float3 center)
{
#if ENABLE_GLOW
    float2 texel = 1.0 / max(Resolution, float2(1.0, 1.0));
    float3 glow = 0.0;

    glow += shaderTexture.Sample(samplerState, uv + float2( 2.0,  0.0) * texel).rgb;
    glow += shaderTexture.Sample(samplerState, uv + float2(-2.0,  0.0) * texel).rgb;
    glow += shaderTexture.Sample(samplerState, uv + float2( 0.0,  2.0) * texel).rgb;
    glow += shaderTexture.Sample(samplerState, uv + float2( 0.0, -2.0) * texel).rgb;
    glow += shaderTexture.Sample(samplerState, uv + float2( 1.5,  1.5) * texel).rgb;
    glow += shaderTexture.Sample(samplerState, uv + float2(-1.5, -1.5) * texel).rgb;
    glow *= 1.0 / 6.0;

    return max(glow - center * 0.32, 0.0) * GLOW_STRENGTH;
#else
    return 0.0;
#endif
}

float scanlineMask(float2 pixelPosition)
{
#if ENABLE_SCANLINES
    float uiScale = max(Scale, 1.0);
    float raster = 0.5 + 0.5 * cos(PI * pixelPosition.y / uiScale);
    float fineLines = 1.0 - SCANLINE_STRENGTH * raster;

    // Subtle vertical phosphor lattice. It is intentionally mild for text clarity.
    float lattice = 0.965 + 0.035 * sin(PI * pixelPosition.x / uiScale);
    return fineLines * lattice;
#else
    return 1.0;
#endif
}

float4 main(PSInput input) : SV_TARGET
{
    float2 glassUv = input.uv;
    float2 uv = glassUv;

#if ENABLE_CURVATURE
    uv = curveScreen(uv);
#endif

    // Shrink the source image into the safe area while the vignette remains
    // attached to the outer glass coordinates.
    uv = fitContentInsideScreen(uv);

    // Keep the safe text inset. Empty terminal pixels are transparent and the
    // profile background is composited later, so the outer area must be
    // transparent as well or it becomes a visible opaque frame.
    bool outsideContent = uv.x <= 0.0 || uv.x >= 1.0 ||
        uv.y <= 0.0 || uv.y >= 1.0;

    if (outsideContent)
    {
        return float4(0.0, 0.0, 0.0, 0.0);
    }

    uv = addSignalInstability(uv);
    uv = clamp(uv, float2(0.0, 0.0), float2(1.0, 1.0));

    float4 source = shaderTexture.Sample(samplerState, uv);
    float3 glowSource = sampleGlow(uv, source.rgb);
    float sourceEnergy = max(luminance(source.rgb), max(source.r, source.b) * 0.62);
    float glowEnergy = luminance(glowSource);
    sourceEnergy = pow(saturate(sourceEnergy), 0.82) + glowEnergy;
    float3 phosphorColor = PHOSPHOR_COLOR * sourceEnergy;
    float3 color;

#if FALLOUT_COLOR_MODE
    float3 preservedColor = (source.rgb + glowSource) * float3(0.94, 1.04, 0.96);
    // Neutral foreground colors become green phosphor, while saturated ANSI
    // colors retain their Fallout palette hue.
    float maximumChannel = max(source.r, max(source.g, source.b));
    float minimumChannel = min(source.r, min(source.g, source.b));
    float saturation = (maximumChannel - minimumChannel) / max(maximumChannel, 0.001);
    float preserveAnsiColor = smoothstep(0.12, 0.32, saturation);
    float visibleForeground = smoothstep(0.075, 0.18, maximumChannel);
    float phosphorizeAmount = (1.0 - preserveAnsiColor) * visibleForeground;
    color = lerp(preservedColor, phosphorColor, phosphorizeAmount);
#else
    color = source.rgb + glowSource;
#endif

#if FALLOUT_COLOR_MODE
    float colorLuminance = luminance(color);
    color = lerp(float3(colorLuminance, colorLuminance, colorLuminance),
        color, COLOR_SATURATION);
#endif

    color *= BRIGHTNESS;

    // A dim powered-on phosphor floor makes scanlines visible in black areas.
#if FALLOUT_COLOR_MODE
    color += BLACK_LEVEL * PHOSPHOR_COLOR;
#else
    color += BLACK_LEVEL * float3(0.65, 0.65, 0.65);
#endif

    color *= scanlineMask(input.pos.xy);
    color *= rollingRefresh(glassUv);

    // Irregular power flicker, restrained so text remains comfortable to read.
    float flicker = 0.988 + 0.012 * sin(Time * 41.0);
    flicker += (hash12(float2(floor(Time * 24.0), 7.0)) - 0.5) * 0.012;
    color *= flicker;

#if ENABLE_NOISE
    float noise = hash12(floor(glassUv * Resolution) + floor(Time * 30.0));
#if FALLOUT_COLOR_MODE
    color += PHOSPHOR_COLOR * (noise - 0.5) * NOISE_STRENGTH;
#else
    color += (noise - 0.5) * NOISE_STRENGTH;
#endif
#endif

#if ENABLE_VIGNETTE
    color *= screenVignette(glassUv);
#endif

    return float4(saturate(color), source.a);
}
