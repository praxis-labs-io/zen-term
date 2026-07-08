// Cursor smear — a trailing streak that follows the cursor between positions,
// then fades to nothing so the settled cursor is 100% Ghostty's own. Uses
// Ghostty's shadertoy cursor uniforms (iCurrentCursor / iPreviousCursor are
// [x, y, w, h] in the shader's pixel space; iTimeCursorChange marks the last move).

float sdBox(in vec2 p, in vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Center of a Ghostty cursor rect (corner + half-size; y is down on Metal).
vec2 cursorCenter(vec4 c) {
    return vec2(c.x + c.z * 0.5, c.y - c.w * 0.5);
}

const float DURATION = 0.25;                       // seconds for the smear to catch up
const vec3 FALLBACK = vec3(0.77, 0.65, 0.90);      // Rosé Pine iris, if cursor color is unset

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);

    vec2 curCenter = cursorCenter(iCurrentCursor);
    vec2 prevCenter = cursorCenter(iPreviousCursor);

    float t = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float ease = 1.0 - pow(1.0 - t, 3.0);          // easeOutCubic
    vec2 center = mix(prevCenter, curCenter, ease);

    // Elongate the box along the travel direction while moving; collapse as it settles.
    vec2 halfSize = vec2(iCurrentCursor.z, iCurrentCursor.w) * 0.5;
    vec2 travel = curCenter - prevCenter;
    vec2 stretch = abs(travel) * 0.5 * (1.0 - ease);
    vec2 box = halfSize + stretch;

    float dist = sdBox(fragCoord.xy - center, box);
    float mask = 1.0 - smoothstep(-2.0, 2.0, dist);

    // Alpha fades to 0 as the cursor settles — no static-view corruption.
    float alpha = mask * (1.0 - ease) * 0.85;

    vec3 color = iCurrentCursorColor.a > 0.0 ? iCurrentCursorColor.rgb : FALLBACK;
    fragColor.rgb = mix(fragColor.rgb, color, alpha);
}
