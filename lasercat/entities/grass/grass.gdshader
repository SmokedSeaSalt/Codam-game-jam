// Reactive stylised grass. One shared material across all the grass chunks.
//  * wind    : constant two-octave sway, stronger toward the blade tip
//  * cat     : a hard radial "hole" that parts + flattens blades near cat_pos
//  * mice    : tiny high-frequency shakes near each moving mouse (mouse_data[i])
//  * pixel   : animation offsets snap to anim_step, colour posterised to
//              pixel_color_steps, so it reads chunky/pixel-art without a
//              separate render pass.
// world_vertex_coords => VERTEX is already world space in vertex(), so the
// per-instance yaw/tilt/scale is baked in and the reactions are simple world math.
// shadows_disabled: thin animated blades crossing the big directional-shadow
// texels flicker between lit/shadowed every frame across the whole field, which
// is painful — so grass never receives shadows. It still gets a soft NdotL from
// the sun for form, and the tip-vs-base colour gradient carries most of the read.
shader_type spatial;
render_mode cull_disabled, world_vertex_coords, diffuse_lambert, specular_disabled, shadows_disabled;

uniform vec3 cat_pos = vec3(0.0);
uniform float cat_bend_radius = 1.4;     // roughly the cat's footprint — keep it tight or it looks like a force field
uniform float cat_bend_strength = 0.16;  // small outward shove (blades stay covering the ground under the cat)
uniform float cat_press_strength = 0.95; // fraction of blade height crushed at the cat's centre — grass LIES DOWN flat under the cat rather than parting away

uniform vec4 mouse_data[8];          // xyz = world pos, w = shake factor (idle_frac..1: sitting -> moving through)
uniform int mouse_count = 0;
uniform float mouse_shake_radius = 0.7;
uniform float mouse_shake_strength = 0.22;

uniform float wind_strength = 0.08;
uniform float wind_speed = 0.7;
uniform vec2 wind_dir = vec2(0.85, 0.5);

uniform vec3 color_base : source_color = vec3(0.13, 0.24, 0.09);
uniform vec3 color_tip : source_color = vec3(0.42, 0.58, 0.22);
uniform float pixel_color_steps = 5.0;
uniform float anim_step = 0.0;       // >0 snaps the sway to this grid (chunky, pixel-art motion). 0 = smooth

varying float v_height;              // 0 at blade base, 1 at tip
varying vec3 v_tint;                 // per-instance colour variation

float h11(float p) { return fract(sin(p * 127.1) * 43758.5453); }

void vertex() {
	v_height = UV.y;
	v_tint = COLOR.rgb;

	vec3 p = VERTEX;                  // world space
	float t = TIME * wind_speed;

	// --- wind ---
	float sway = sin(p.x * 0.35 + p.z * 0.25 + t)
			   + 0.5 * sin(p.x * 0.9 - p.z * 0.6 + t * 1.7);
	sway *= 0.7 + 0.6 * h11(p.x * 3.1 + p.z * 1.7);
	vec2 off = normalize(wind_dir) * sway * wind_strength;

	// --- cat: sharp radial parting + flatten ---
	vec2 from_cat = p.xz - cat_pos.xz;
	float d_cat = length(from_cat);
	float cat_inf = clamp(1.0 - d_cat / cat_bend_radius, 0.0, 1.0);
	cat_inf *= cat_inf;
	// The outward shove needs a stable radial direction; right under the cat
	// from_cat -> 0 and that direction spins wildly, so blades at the cat's feet
	// snapped around every frame. Fade the shove out across a small centre disc
	// (cat_inf still hits full strength there, so the downward press keeps the
	// grass lying flat and covering the ground).
	vec2 cat_dir = from_cat / max(d_cat, 0.0001);
	float cat_centre_fade = smoothstep(0.0, cat_bend_radius * 0.35, d_cat);
	off += cat_dir * cat_inf * cat_bend_strength * cat_centre_fade;

	// --- mice: tiny shakes ---
	for (int i = 0; i < 8; i++) {
		if (i >= mouse_count) { break; }
		vec3 md = mouse_data[i].xyz;
		float shake = clamp(mouse_data[i].w, 0.0, 1.0);   // idle_frac when sitting, up to 1 moving through
		vec2 from_m = p.xz - md.xz;
		float d_m = length(from_m) + 0.0001;
		float m_inf = clamp(1.0 - d_m / mouse_shake_radius, 0.0, 1.0);
		m_inf *= m_inf;
		float j = sin(TIME * 32.0 + p.x * 11.0 + p.z * 9.0 + float(i) * 5.0);
		float amp = m_inf * mouse_shake_strength * shake;
		off += (from_m / d_m) * j * amp * 0.6 + vec2(j, -j) * amp * 0.4;
	}

	// only the part of the blade above the ground bends
	off *= v_height;
	// Press the blade flat under the cat. Target is a fraction of THIS vertex's own
	// height (not a fixed distance), so tall blades flatten as hard as short ones and
	// nothing pokes up around the paws — the cat stops looking like it floats on the
	// grass. Never punch the tip through the floor: keep ~1.5 cm of clearance.
	float floor_gap = max(VERTEX.y - 0.015, 0.0);
	float droop = min(cat_inf * cat_press_strength * floor_gap, floor_gap);
	if (anim_step > 0.0001) {         // optional stepped motion for a pixel-art feel
		off = floor(off / anim_step + 0.5) * anim_step;
		droop = floor(droop / anim_step + 0.5) * anim_step;
	}

	VERTEX.x += off.x;
	VERTEX.z += off.y;
	VERTEX.y -= droop;
}

void fragment() {
	vec3 g = mix(color_base, color_tip, v_height) * v_tint;
	g = floor(g * pixel_color_steps + 0.5) / pixel_color_steps;
	ALBEDO = g;
	ROUGHNESS = 1.0;
}
