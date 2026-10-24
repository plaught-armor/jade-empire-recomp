// Smoother animation blending, a deliberate change rather than a bit-exact
// replacement. The game cross-fades a new animation layer in with a weight
// that ramps linearly over the layer's transition time, often 0 to 0.15
// seconds from the MDL, so moves start and stop with a jolt. The port gives
// every layer starting a blend at least BLEND_MS_DEFAULT milliseconds of it
// (setting BLEND_MS) and eases the weight the pose is built with by smoothstep.
// JE_BLEND=0 keeps the original blending. JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §10
package native

import "../x86"

guest_anim_play: x86.Func
guest_anim_apply: x86.Func

BLEND_MS_DEFAULT :: 120

blend_on := true
blend_min: f32 = BLEND_MS_DEFAULT / 1000.0

// The animation layers of an object, layer struct 0x38 bytes (ctor 0x60b8a0).
LAYERS :: 0x268 // u32 array of layer pointers
LAYER_N :: 0x26c
LAYER_WEIGHT :: 0x20 // f32
LAYER_DUR :: 0x24 // f32 transition time, seconds
LAYER_STATE :: 0x30 // u32: 1 blending in, 2 full, 3 blending out, 4 dead
LAYER_ELAPSED :: 0x34 // f32 seconds into the transition
LAYER_BLENDING_IN :: 1

// PlayAnimation, thiscall(name, ?, flags, start, blend, out), ret 0x18. A
// layer it starts blending in (weight 0, nothing elapsed) gets at least
// blend_min seconds, except for a blend of 0 asked for explicitly: a cut.
// Flag 2 snaps the layer in at full weight and is left alone.
Anim_Play_0060d2f0 :: proc() {
	c := &x86.cpu
	obj, blend := c.ecx, ld(c.esp + 0x14)
	guest_anim_play()
	if !blend_on || blend == 0 {return}
	layers, n := ld(obj + LAYERS), ld(obj + LAYER_N)
	for i in 0 ..< n {
		l := ld(layers + i * 4)
		if ld(l + LAYER_STATE) == LAYER_BLENDING_IN && ld(l + LAYER_WEIGHT) == 0 && ld(l + LAYER_ELAPSED) == 0 &&
		   lf(l + LAYER_DUR) < blend_min {
			st(l + LAYER_DUR, transmute(u32)blend_min)
		}
	}
}

// Applies one layer to the model's nodes, cdecl(model, anim, flag, prev,
// time, weight): each node becomes sample * weight + node * (1 - weight). The
// weight is eased; 0 and 1 stay as they are.
Anim_ApplyLayer_0060e8f0 :: proc() {
	c := &x86.cpu
	if blend_on {
		w := lf(c.esp + 0x18)
		if w > 0 && w < 1 {
			st(c.esp + 0x18, transmute(u32)(w * w * (3 - 2 * w)))
		}
	}
	guest_anim_apply()
}
