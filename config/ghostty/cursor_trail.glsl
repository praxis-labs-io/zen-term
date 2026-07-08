// Cursor trail — a smear that follows the cursor from its previous cell to the
// current one, fading to nothing so the settled cursor is 100% Ghostty's own.
//
// The full-featured sahaj-b/ghostty-cursor-shaders "warp" shader is valid GLSL
// but trips libghostty 1.3.1's embedded SPIR-V→Metal translation (OOM at surface
// init) on its per-corner convex-quad math. This is a lean single-box version that
// borrows that project's coordinate-normalization convention (MIT, © 2026 Sahaj
// Bhatt — https://github.com/sahaj-b/ghostty-cursor-shaders): cursor rects and the
// fragment coordinate map into one shared space via iResolution before comparison.

// sRGB -> linear (Ghostty passes sRGB; the shader pipeline is linear).
vec3 sRGBToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

float sdBox(in vec2 p, in vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// value*2 - res*isPos, over res.y: positions (isPos=1) and sizes (isPos=0) share a space.
vec2 norm(vec2 v, float isPos) {
    return (v * 2.0 - iResolution.xy * isPos) / iResolution.y;
}

const float DURATION = 0.22;             // seconds for the trail to catch up
const float THRESHOLD = 0.30;            // min travel (normalized) before a trail shows

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);

    vec2 vu = norm(fragCoord, 1.0);
    vec4 cc = vec4(norm(iCurrentCursor.xy, 1.0), norm(iCurrentCursor.zw, 0.0));
    vec4 cp = vec4(norm(iPreviousCursor.xy, 1.0), norm(iPreviousCursor.zw, 0.0));

    // Center = corner + (halfW, -halfH): the documented offset convention (y is down).
    vec2 centerCC = cc.xy + vec2(cc.z, -cc.w) * 0.5;
    vec2 centerCP = cp.xy + vec2(cp.z, -cp.w) * 0.5;
    vec2 halfCC = abs(vec2(cc.z, cc.w)) * 0.5;

    float travelLen = distance(centerCC, centerCP);
    float t = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float e = 1.0 - pow(1.0 - t, 3.0);   // easeOutCubic

    if (travelLen > THRESHOLD * halfCC.y * 2.0 && t < 1.0) {
        vec2 center = mix(centerCP, centerCC, e);
        vec2 stretch = abs(centerCC - centerCP) * 0.5 * (1.0 - e);
        float d = sdBox(vu - center, halfCC + stretch);
        float aa = norm(vec2(1.5), 0.0).x;
        float mask = 1.0 - smoothstep(0.0, aa, d);

        // Fade out as it settles; punch a hole so the live cursor cell isn't covered.
        float alpha = mask * (1.0 - e) * 0.9 * step(0.0, sdBox(vu - centerCC, halfCC));
        fragColor.rgb = mix(fragColor.rgb, sRGBToLinear(iCurrentCursorColor.rgb), alpha);
    }
}
