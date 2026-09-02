shader_type canvas_item;

// The cat SubViewport is drawn straight through, nearest-filtered for the blocky
// upscale. `visibility` (0..1) comes from CPU line-of-sight rays; as the cat goes
// behind terrain it dissolves with a screen-stable ordered dither. No per-frame
// colour comparison happens anywhere, so there is nothing to flicker.
uniform float visibility : hint_range(0.0, 1.0) = 1.0;
uniform float pixel_scale = 5.0;
uniform int color_levels = 6;   // 0 = off. Snaps residual shade wobble to fixed steps.

const float BAYER[16] = float[16](
	 0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
	12.0 / 16.0,  4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
	 3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
	15.0 / 16.0,  7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0
);

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	if (c.a < 0.5) {
		discard;
	}
	if (visibility < 0.999) {
		vec2 cell = floor(FRAGCOORD.xy / max(pixel_scale, 1.0));
		int idx = int(mod(cell.x, 4.0)) + int(mod(cell.y, 4.0)) * 4;
		if (visibility < BAYER[idx]) {
			discard;
		}
	}
	vec3 rgb = c.rgb;
	if (color_levels > 0) {
		// Quantise brightness only, keeping hue — per-channel rounding turns dark
		// browns into saturated red/green blocks.
		float n = float(color_levels);
		float v = max(max(rgb.r, rgb.g), rgb.b);
		if (v > 0.0001) {
			rgb *= (floor(v * n + 0.5) / n) / v;
		}
	}
	COLOR = vec4(rgb, 1.0);
}
