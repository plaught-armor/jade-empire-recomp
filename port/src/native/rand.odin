// The CRT's rand and srand, one LCG state at RAND_STATE. The renderer's
// calls (from RAND_RENDER) take a stream of their own: how much it draws
// follows the look settings, which online peers keep their own of, and it
// must not move the stream the game's play draws from. So does a crowd's
// update (Crowd_Update), with the game's own LCG as well: it runs only near
// the camera, which is each peer's own. WHY: docs/hle.md §11
package native

import "../x86"

RAND_STATE :: 0x00769e00
RAND_RENDER :: [2]u32{0x005e0000, 0x00640000}

rand_render: u32 = 1

// The game's own LCG, at [GAME_RAND_PP]+0x24, and the crowd's streams.
GAME_RAND_PP :: 0x0076c588
GAME_RAND :: 0x24
rand_crowd: [2]u32 = {1, 1}

guest_crowd_update: x86.Func

guest_rand: x86.Func
guest_srand: x86.Func

// The state the call from return address ret uses.
@(private = "file")
rand_state :: #force_inline proc(ret: u32) -> ^u32 {
	if ret >= RAND_RENDER[0] && ret < RAND_RENDER[1] {return &rand_render}
	return (^u32)(&x86.mem[RAND_STATE])
}

// cdecl () -> eax, 0..0x7fff.
rand_006b2cc3 :: proc() {
	c := &x86.cpu
	s := rand_state(ld(c.esp))
	s^ = s^ * 214013 + 2531011
	c.eax = (s^ >> 16) & 0x7fff
	c.esp += 4
}

// cdecl (seed), eax = seed.
srand_006b2cb9 :: proc() {
	c := &x86.cpu
	c.eax = ld(c.esp + 4)
	rand_state(ld(c.esp))^ = c.eax
	c.esp += 4
}

// CCrowdObject's update, thiscall (). It draws from the CRT's and the
// game's LCG only when the camera is near (0x4d7ee4), so on the crowd's
// streams in their place.
Crowd_Update_004d7e70 :: proc() {
	game := ld(GAME_RAND_PP) + GAME_RAND
	crowd_swap(game)
	guest_crowd_update()
	crowd_swap(game)
}

@(private = "file")
crowd_swap :: proc(game: u32) {
	rand_crowd[0], (^u32)(&x86.mem[RAND_STATE])^ = ld(RAND_STATE), rand_crowd[0]
	if game == GAME_RAND {return}
	rand_crowd[1], (^u32)(&x86.mem[game])^ = ld(game), rand_crowd[1]
}
