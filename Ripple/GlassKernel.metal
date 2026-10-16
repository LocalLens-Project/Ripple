#include <CoreImage/CoreImage.h>
using namespace metal;

float glassDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

extern "C" float4 rippleGlass(coreimage::sampler source, coreimage::sampler soft, float4 rect, float scale, float corner, float strength, float visibility, float clearBackground, coreimage::destination destination) {
    float2 p = destination.coord();
    float2 center = rect.xy + rect.zw * 0.5;
    float2 sourceHalf = rect.zw * 0.5;
    float2 halfSize = sourceHalf * scale;
    float radius = min(halfSize.x, halfSize.y) * 2.0 * corner;
    float2 local = p - center;
    float distance = glassDistance(local, halfSize, radius);
    float originalDistance = glassDistance(local, sourceHalf, min(sourceHalf.x, sourceHalf.y));
    float4 a = source.sample(source.transform(center + rect.zw * float2(-0.2, 0.37)));
    float4 b = source.sample(source.transform(center + rect.zw * float2(0.2, 0.37)));
    float4 c = source.sample(source.transform(center + rect.zw * float2(-0.2, -0.37)));
    float4 d = source.sample(source.transform(center + rect.zw * float2(0.2, -0.37)));
    float3 paper = (a.rgb + b.rgb + c.rgb + d.rgb) * 0.25;
    float spread = max(max(length(a.rgb - paper), length(b.rgb - paper)), max(length(c.rgb - paper), length(d.rgb - paper)));
    float key = step(0.86, min(min(paper.r, paper.g), paper.b)) * (1.0 - step(0.1, spread)) * clearBackground;
    float3 above = source.sample(source.transform(center + rect.zw * float2(-0.18, 0.7))).rgb;
    float3 below = source.sample(source.transform(center + rect.zw * float2(0.18, -0.7))).rgb;
    float3 cleanPaper = length(above - below) < 0.12 && min(min(above.r, above.g), above.b) > 0.8 ? (above + below) * 0.5 : paper;
    float4 original = source.sample(source.transform(p));
    float cleanup = clamp(0.5 - originalDistance, 0.0, 1.0) * key;
    float4 base = mix(original, float4(cleanPaper, 1.0), cleanup);
    float rim = max(3.0, min(halfSize.x, halfSize.y) * 0.23);
    float shadowDistance = glassDistance(local + float2(0.0, rim * 0.48), halfSize, radius);
    float shadow = exp(-pow(max(shadowDistance, 0.0) / (rim * 0.7), 2.0)) * 0.19 * visibility;
    base.rgb *= 1.0 - shadow;
    float coverage = clamp(0.5 - distance, 0.0, 1.0);
    if (coverage <= 0.0) { return base; }
    float2 q = abs(local) - halfSize + radius;
    float2 normal = q.x > 0.0 && q.y > 0.0 ? normalize(max(q, 0.001)) : (q.x > q.y ? float2(1.0, 0.0) : float2(0.0, 1.0));
    normal *= sign(local + 0.0001);
    float bevel = exp(-pow((distance + rim * 0.55) / (rim * 0.68), 2.0));
    float2 refracted = p - normal * bevel * rim * 0.85 * strength;
    float4 backdrop = mix(source.sample(source.transform(refracted)), soft.sample(soft.transform(refracted)), 0.4 * strength);
    float refractedOriginal = glassDistance(refracted - center, sourceHalf, min(sourceHalf.x, sourceHalf.y));
    backdrop.rgb = mix(backdrop.rgb, cleanPaper, clamp(0.5 - refractedOriginal, 0.0, 1.0) * key);
    float3 material = mix(backdrop.rgb, float3(1.0), 0.085 + strength * 0.065);
    float2 contentPosition = center + local / scale;
    float4 content = source.sample(source.transform(contentPosition));
    float ink = smoothstep(0.12, 0.3, length(content.rgb - paper));
    ink *= 1.0 - smoothstep(0.72, 0.9, min(min(content.r, content.g), content.b));
    float inner = smoothstep(0.0, rim * 0.8, -distance);
    material = mix(material, content.rgb, mix(inner, ink * inner, key));
    float light = 0.55 + 0.45 * abs(dot(normal, normalize(float2(-0.5, 0.86))));
    float outerLine = exp(-pow((distance + 1.4) / max(1.0, rim * 0.055), 2.0));
    float innerLine = exp(-pow((distance + rim * 0.52) / max(1.0, rim * 0.09), 2.0));
    material = mix(material, float3(1.0), outerLine * 0.85 + innerLine * 0.38 * light * strength);
    material *= 1.0 - bevel * 0.065 * strength;
    material = mix(content.rgb, material, visibility);
    return float4(mix(base.rgb, clamp(material, 0.0, 1.0), coverage), 1.0);
}
