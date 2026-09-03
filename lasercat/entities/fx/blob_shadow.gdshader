// Soft round contact shadow. Multiply-blended onto whatever's under it (dirt or
// grass), so the cat / mice read as planted on the ground. Not a real shadow —
// the cat lives in the pixel SubViewport and the grass shader ignores shadows,
// so a blob is the only thing that grounds them consistently.
shader_type spatial;
render_mode unshaded, blend_mul, cull_disabled, depth_draw_never, shadows_disabled;

uniform float darkness : hint_range(0.0, 1.0) = 0.5;   // 0 = black at the centre, 1 = invisible
uniform float softness : hint_range(0.02, 1.0) = 0.55; // how far in the fade to the edge starts

void fragment() {
	float d = length(UV - vec2(0.5)) * 2.0;            // 0 centre .. 1 edge
	float m = smoothstep(1.0, 1.0 - softness, d);      // 1 centre .. 0 edge
	ALBEDO = mix(vec3(1.0), vec3(darkness), m);
}
