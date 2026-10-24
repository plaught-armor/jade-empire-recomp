// Attack magnetism, a deliberate change rather than a bit-exact replacement.
// A swing a hero (the player, or player 2's hero) starts at its target inside
// a cone ahead and within reach slides the hero in to striking distance over the swing's first
// moments, through the want position the move collision 0x45d6b0 takes, so
// walls and the walkmesh still stop it. The game already turns a swing toward
// the target. Cone and reach grow with mastery of the style in use, the bar
// on the styles screen: its upgrades bought, full at MASTERY_FULL.
// JE_MAGNET=0 keeps the original swings. JE_NATIVE has no effect here.
// WHY: docs/recompiler.md §10
package native

import "core:math"
import "../x86"

guest_collide: x86.Func

magnet_on := true

MAGNET_CONE_MIN :: 25 * math.PI / 180 // half-angle off the facing, no upgrades
MAGNET_CONE_MAX :: 60 * math.PI / 180 // at full mastery
MAGNET_REACH_MIN :: 1.5 // m, centre to centre, at which a swing engages
MAGNET_REACH_MAX :: 3.0
MAGNET_STAND :: 0.8 // m, centre to centre, where the slide stops
MAGNET_SLIDE_S :: 0.2 // seconds the slide takes at its full length
MASTERY_FULL :: 15 // upgrades that fill the styles screen's bar (ui_spoints_15)

CREATURE_STYLE :: 0x584 // u32 index of the style in use
CREATURE_STYLE_N :: 0x464 // u32 styles known
CREATURE_STYLES :: 0x46c // ^^style entry
STYLE_LEVEL :: 5 // u8: 1 + upgrades bought

// Mover (the second argument of 0x45d6b0).
MOVER_POS :: 0x3c // f32 x, y, z: the position the move starts from

@(private = "file")
magnet_foe: u32 // the player's target creature, seen by its AI update

// A hero's slide in progress, from a swing's start until it reaches the
// stand-off, its length runs out or the hero's next anim other than an idle
// starts.
@(private = "file")
Slide :: struct {
	hero:   u32,
	foe:    u32,
	left:   f32, // m still to slide
	speed:  f32, // m per second
	frame:  u32, // the frame the last step was taken, one per frame
}
@(private = "file")
slides: [2]Slide // the player's, player 2's hero's

// From the foe AI update: notes the creature the player targets.
magnet_seen :: proc(cre: u32) {
	p := world_player()
	if p != 0 && ld(cre + CREATURE_ID) == ld(p + CREATURE_TARGET) {magnet_foe = cre}
}

// A hero's mastery of the style in use, 0 to 1.
@(private = "file")
mastery :: proc(p: u32) -> f32 {
	i := ld(p + CREATURE_STYLE)
	if i >= ld(p + CREATURE_STYLE_N) {return 0}
	e := ld(ld(p + CREATURE_STYLES) + 4 * i)
	if e == 0 {return 0}
	up := max(i32(x86.mem[e + STYLE_LEVEL]) - 1, 0)
	return f32(min(up, MASTERY_FULL)) / MASTERY_FULL
}

// From the anim start hook: cre starts the anim name with flags; p is the
// player. A hero's swing starts a slide when its target is in the cone and
// reach; any other anim of the hero but an idle ends one.
magnet_anim :: proc(cre, p, name, flags: u32) {
	if flags == ANIM_FLAGS_IDLE {return}
	i: int
	f: u32
	switch {
	case cre == p:
		i, f = 0, magnet_foe
	case coop_driven(cre):
		i, f = 1, coop_fight_foe(cre)
	case:
		return
	}
	slides[i] = {}
	m, d := x86.mem[name], x86.mem[name + 1]
	if !magnet_on || flags != ANIM_FLAGS_ACTION || m != 'm' || d < '0' || d > '9' {return}
	if f == 0 || ld(f + CREATURE_ID) != ld(cre + CREATURE_TARGET) || lf(f + CREATURE_HEALTH) <= 0 {return}
	k := mastery(cre)
	dx, dy := lf(f + CREATURE_POS) - lf(cre + CREATURE_POS), lf(f + CREATURE_POS + 4) - lf(cre + CREATURE_POS + 4)
	dist := math.sqrt(dx * dx + dy * dy)
	if dist <= MAGNET_STAND || dist > math.lerp(f32(MAGNET_REACH_MIN), MAGNET_REACH_MAX, k) {return}
	fx, fy := lf(cre + CREATURE_FACING), lf(cre + CREATURE_FACING + 4)
	off := abs(math.atan2(fx * dy - fy * dx, fx * dx + fy * dy))
	if off > math.lerp(f32(MAGNET_CONE_MIN), MAGNET_CONE_MAX, k) {return}
	left := dist - MAGNET_STAND
	slides[i] = {cre, f, left, left / MAGNET_SLIDE_S, x86.frame_now}
}

// Collide, thiscall(f32 *out, mover, f32 *want, int *ok), ret 0x10: moves the
// mover from its position toward want with walkmesh and wall slide. While a
// hero's slide is live its want steps toward the foe, once a frame.
Collide_0045d6b0 :: proc() {
	c := &x86.cpu
	this := c.ecx
	mover, want := ld(c.esp + 0x8), ld(c.esp + 0xc)
	for &s in slides {
		if s.foe != 0 && s.frame != x86.frame_now {magnet_step(&s, mover, want)}
	}
	c.ecx = this
	guest_collide()
}

@(private = "file")
magnet_step :: proc(s: ^Slide, mover, want: u32) {
	h, f := s.hero, s.foe
	if lf(mover + MOVER_POS) != lf(h + CREATURE_POS) || lf(mover + MOVER_POS + 4) != lf(h + CREATURE_POS + 4) {return}
	s.frame = x86.frame_now
	if ld(f + CREATURE_ID) != ld(h + CREATURE_TARGET) {
		s^ = {}
		return
	}
	wx, wy := lf(want), lf(want + 4)
	dx, dy := lf(f + CREATURE_POS) - wx, lf(f + CREATURE_POS + 4) - wy
	dist := math.sqrt(dx * dx + dy * dy)
	step := min(s.speed * lf(ld(APP) + APP_DT), s.left, dist - MAGNET_STAND)
	if step <= 0 {
		s^ = {}
		return
	}
	s.left -= step
	sf(want, wx + dx / dist * step)
	sf(want + 4, wy + dy / dist * step)
}
