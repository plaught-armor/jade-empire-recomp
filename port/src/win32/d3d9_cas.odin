// Sharpening and vibrance (JE_SHARPEN, JE_VIBRANCE): one full-screen pass
// after SMAA, in the same chain (smaa_frame), before the UI is drawn. The
// sharpening is AMD's contrast-adaptive sharpening (FidelityFX CAS, MIT) at
// the image's own size; vibrance raises the saturation of muted colours more
// than of saturated ones. WHY: docs/rendering.md §14
package win32

cas_sharp: u32 // JE_SHARPEN; 0 = off, 1..3 = low, medium, high
cas_vibrance: u32 // JE_VIBRANCE; 0 = off, 1..3 = low, medium, high

CAS_VS :: `#version 460 core
out gl_PerVertex { vec4 gl_Position; };
void main() {
	gl_Position = vec4(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0, 0.0, 1.0);
}
`

// k.x is CAS's peak weight, -1 / mix(8, 5, sharpness), or 0 for none; k.y the
// vibrance. Pixels at the edge repeat the edge.
CAS_PS :: `#version 460 core
layout(binding = 0) uniform sampler2D color_tex;
layout(location = 0) uniform vec2 k;
layout(location = 0) out vec4 o;
vec4 at(ivec2 p) { return texelFetch(color_tex, clamp(p, ivec2(0), textureSize(color_tex, 0) - 1), 0); }
void main() {
	ivec2 p = ivec2(gl_FragCoord.xy);
	vec4 e4 = at(p);
	vec3 e = e4.rgb;
	vec3 a = at(p + ivec2(-1, -1)).rgb, b = at(p + ivec2(0, -1)).rgb, c = at(p + ivec2(1, -1)).rgb;
	vec3 d = at(p + ivec2(-1, 0)).rgb, f = at(p + ivec2(1, 0)).rgb;
	vec3 g = at(p + ivec2(-1, 1)).rgb, h = at(p + ivec2(0, 1)).rgb, i = at(p + ivec2(1, 1)).rgb;
	vec3 r = e;
	if (k.x != 0.0) {
		vec3 mn = min(min(min(d, e), min(f, b)), h);
		mn += min(mn, min(min(a, c), min(g, i)));
		vec3 mx = max(max(max(d, e), max(f, b)), h);
		mx += max(mx, max(max(a, c), max(g, i)));
		vec3 amp = sqrt(clamp(min(mn, 2.0 - mx) / max(mx, vec3(1e-5)), 0.0, 1.0));
		vec3 w = amp * k.x;
		r = clamp(((b + d + f + h) * w + e) / (1.0 + 4.0 * w), 0.0, 1.0);
	}
	float l = dot(r, vec3(0.2126, 0.7152, 0.0722));
	float s = max(r.r, max(r.g, r.b)) - min(r.r, min(r.g, r.b));
	r = clamp(mix(vec3(l), r, 1.0 + k.y * (1.0 - s)), 0.0, 1.0);
	o = vec4(r, e4.a);
}
`

CAS_SHARPNESS := [4]f32{0, 0, 0.5, 1}
CAS_VIBRANCE := [4]f32{0, 0.15, 0.3, 0.5}

cas_on :: proc() -> bool {
	return cas_sharp != 0 || cas_vibrance != 0
}

// The pass's uniform for the settings in force.
cas_k :: proc() -> [2]f32 {
	peak := f32(0)
	if cas_sharp != 0 {
		t := CAS_SHARPNESS[min(cas_sharp, 3)]
		peak = -1 / (8 + (5 - 8) * t)
	}
	return {peak, CAS_VIBRANCE[min(cas_vibrance, 3)]}
}
