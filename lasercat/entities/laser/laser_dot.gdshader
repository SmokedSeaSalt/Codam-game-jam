shader_type spatial;
// The laser dot, drawn twice by laser.gd from this one shader:
//
//   * the POOL — a quad laid flat against the surface normal, wide and soft. It's
//     what sells "the beam is landing on that thing" rather than "a red marble is
//     floating there": it tilts with slopes and skews with the camera exactly the
//     way a real spot of light on a surface does.
//   * the CORE — a small quad with billboard = true, so it always squares up to
//     the camera. The game camera is orthogonal and looks in at a shallow ~19°,
//     which foreshortens the flat pool into a sliver; this keeps a crisp bright
//     speck the eye can lock onto no matter the angle.
//
// Depth-test-free on purpose: the dot must never be lost behind a terrain step or
// the cat's body.
//
// PREMULTIPLIED alpha rather than plain additive. Additive only ever ADDS red to
// what's behind it, so over bright grass the red channel saturates while the
// background's green and blue survive underneath — the dot washes out to pink.
// Premultiplied blends as `src + dst * (1 - alpha)`, so the opaque centre wipes
// the background out and lands as pure red, while the low-alpha bloom edge still
// behaves additively and glows. ALBEDO therefore has to be multiplied by ALPHA
// ourselves — that's what "premultiplied" means.
render_mode unshaded, blend_premul_alpha, cull_disabled, depth_draw_never, depth_test_disabled;

// Pure red, no white blowout at all. The centre still reads as the hot spot
// because ALPHA peaks there — it's brighter than the bloom, not a different hue.
uniform vec3 core_color : source_color = vec3(1.0, 0.0, 0.0);
uniform vec3 glow_color : source_color = vec3(1.0, 0.0, 0.0);
uniform float core_radius = 0.10;   // UV radius of the hot centre
uniform float glow_radius = 0.50;   // …and how far the bloom bleeds out around it
uniform float glow_falloff = 2.5;   // higher = tighter, more "focused beam"
uniform float intensity = 1.0;
// Pushes mid-range alpha toward fully opaque before the final clamp, so more of
// the dot's radius reads as SOLID red instead of a translucent tint the grass
// colour bleeds through — a soft gradient alone still looks pale/washed-out at
// only a few pixels across, however pure the underlying colour is.
uniform float alpha_boost = 1.0;
uniform float flicker_amount = 0.12;
uniform float flicker_speed = 24.0;
uniform bool billboard = false;
uniform float squash = 1.0;         // billboard only: <1 flattens it vertically

void vertex() {
	if (billboard) {
		// Square up to the camera while KEEPING the node's scale — the stock
		// billboard basis is unit-length, which would collapse the quad's size.
		// squash then flattens the vertical axis, so the speck reads as a disc
		// lying in the pool rather than a ball standing up out of it.
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0]),
			INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1]) * squash,
			INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2]),
			MODEL_MATRIX[3]);
	}
}

void fragment() {
	float d = length(UV - vec2(0.5));
	// Tightish edge on the centre: a wide soft ramp here is what made it look
	// like a volumetric ball instead of a flat disc.
	float core = 1.0 - smoothstep(core_radius * 0.55, core_radius, d);
	float glow = pow(clamp(1.0 - d / glow_radius, 0.0, 1.0), glow_falloff);
	float pulse = 1.0 + sin(TIME * flicker_speed) * flicker_amount;
	ALPHA = clamp((glow + core) * alpha_boost, 0.0, 1.0);
	ALBEDO = mix(glow_color, core_color, core) * intensity * pulse * ALPHA;
}
