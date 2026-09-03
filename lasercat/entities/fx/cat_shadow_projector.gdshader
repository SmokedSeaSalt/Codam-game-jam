// A REAL cat shadow that works on the GL Compatibility renderer (where a
// DirectionalLight3D shadow-catcher / `shadow_to_opacity` does not).
//
// Used as the `next_pass` of the cat's own material, so it redraws the exact same
// skinned geometry a second time. `world_vertex_coords` means VERTEX here is the
// world-space, post-skinning position — we squash it onto the ground plane along
// the sun direction, giving a silhouette that is the cat's real pose at the real
// sun angle. Flat dark, unshaded. Depth test stays ON (no `depth_test_disabled`)
// so the cat's body correctly occludes the part of the shadow behind it.
shader_type spatial;
render_mode world_vertex_coords, unshaded, cull_disabled, blend_mix, depth_draw_never, shadows_disabled;

uniform vec3 light_dir = vec3(0.321, -0.766, -0.557);  // direction the sun's light travels (points DOWN); fed from pixel_cat.gd
uniform float ground_y = 0.02;
uniform float strength : hint_range(0.0, 1.0) = 0.45;
uniform vec3 shadow_color : source_color = vec3(0.04, 0.035, 0.03);

void vertex() {
	vec3 w = VERTEX;
	float denom = min(light_dir.y, -0.05);          // guard against a near-horizontal sun
	float k = max((w.y - ground_y) / denom, 0.0);    // march down the light ray to the ground
	w -= light_dir * k;
	w.y = ground_y;
	VERTEX = w;
}

void fragment() {
	ALBEDO = shadow_color;
	ALPHA = strength;
}
