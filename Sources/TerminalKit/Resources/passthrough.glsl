// A cursor shader that draws the terminal and nothing else — zen-term's, not third-party.
//
// It stands in for the real shader while a surface is unfocused. Removing
// `custom-shader` outright would be the obvious way to silence an unfocused pane, but
// ghostty skips its whole cursor-uniform update when no shader is loaded
// (`renderer/generic.zig`: `if (!self.has_custom_shaders) return;`), so `iCurrentCursor`
// freezes at whatever position it held. Restoring the real shader on focus then reads as
// one enormous cursor jump, and it animates a smear in from the stale position.
//
// Keeping a shader loaded keeps those uniforms tracking, so the real shader comes back to
// `iPreviousCursor == iCurrentCursor` and has nothing to animate. This costs one
// texture sample on frames that were being drawn anyway: ghostty's draw timer stays
// focus-gated, so an unfocused pane still isn't animating.
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
}
