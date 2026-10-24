// Frame-count immediates for an unlocked frame rate.
package x86

// Presented frames per second, rounded; set by the D3D9 layer each frame.
frame_rate: u32 = FRAME_RATE_GAME

// The rate the game's frame counts were written for (ClampFPS).
FRAME_RATE_GAME :: 30

// n frames at FRAME_RATE_GAME as a count at frame_rate, at least 1. The
// generator emits it for the immediates tools/x86rec.py FRAME_COUNTS lists.
// WHY: docs/rendering.md §5
frames :: proc "contextless" (n: u32) -> u32 {
	return max(1, (n * frame_rate + FRAME_RATE_GAME / 2) / FRAME_RATE_GAME)
}
