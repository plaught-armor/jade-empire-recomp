// Lockstep: every peer of an online game runs the whole game from boot on
// the same inputs, so everything the guest reads must follow from those
// inputs alone. The host clock gives way to a virtual one that a presented
// frame moves on by LOCK_STEP, a Sleep by its length and each clock read by
// LOCK_READ, so a loop that waits on the clock still ends. The wall clock
// the guest sees is the host's at the handshake plus the virtual clock.
// WHY: docs/hle.md §11
package win32

import "core:fmt"
import "core:os"
import "core:time"
import "../x86"

lockstep := false

LOCK_RATE :: 60
LOCK_STEP :: time.Second / LOCK_RATE
LOCK_READ :: time.Microsecond

// The virtual clock, frames presented under it and the wall clock at its 0
// as Unix nanoseconds.
vclock: time.Duration
vframe: i64
lock_epoch: i64

// Turns lockstep on, before the settings load; JE_LOCKSTEP alone (no net)
// runs from LOCK_EPOCH_SOLO on the local pads, to test that two runs on the
// same input stay the same.
LOCK_EPOCH_SOLO :: 1_767_225_600_000_000_000 // 2026-01-01
lockstep_start :: proc() {
	lockstep = true
	lock_scratch_make()
	lock_epoch = LOCK_EPOCH_SOLO
	fps_cap = LOCK_RATE
	x86.frame_rate = LOCK_RATE
}

// The game's scratch folder (the save being loaded or written, its image)
// and logs folder (d3d.log) under lockstep: fresh ones per process, in a temp
// folder lock_dir, so what the guest finds there follows from the inputs
// alone, not from games before or a second peer on the same game folder.
// host_path maps the guest's scratch and logs onto them. lock_logs is left
// for the game to make, as on a first run: whether logs already existed
// changed guest memory by frame 60 (docs/hle.md §11).
lock_dir: string
lock_scratch: string
lock_logs: string

@(private = "file")
lock_scratch_make :: proc() {
	tmp, err := os.temp_directory(context.temp_allocator)
	if err == nil {lock_dir, err = os.make_directory_temp(tmp, "jade_scratch_*", context.allocator)}
	if err == nil {
		lock_scratch = fmt.aprintf("%s/scratch", lock_dir)
		lock_logs = fmt.aprintf("%s/logs", lock_dir)
		err = os.make_directory(lock_scratch)
	}
	if err != nil {
		fmt.eprintfln("lockstep: no scratch folder: %v", err)
		os.exit(1)
	}
}

// A rejoining peer replaying the log (net.odin): frames run as fast as they
// go, with no vsync and no sound out.
lock_fast := false

lock_fast_set :: proc(on: bool) {
	lock_fast = on
	swap_apply()
}

// Ends the game: tells the peer when bye is set, puts a rejoin's saves back,
// removes the lockstep scratch folder and exits.
game_exit :: proc(code: int, bye := true) -> ! {
	game_end(bye)
	os.exit(code)
}

// game_exit short of exiting; also closes the socket and the router's
// forward of its port, for a game run again (relaunch.odin).
game_end :: proc(bye: bool) {
	net_end(bye)
	net_close()
	upnp_close()
	net_save_close()
	if lock_dir != "" {_ = os.remove_all(lock_dir)}
}

// Host time since boot, or the virtual clock under lockstep.
host_now :: proc() -> time.Duration {
	return lockstep ? vclock : time.tick_since(start_tick)
}

// A guest clock read: under lockstep it moves the virtual clock on a little.
clock_read :: proc() -> time.Duration {
	if lockstep {vclock += LOCK_READ}
	return host_now()
}

// The wall clock as Unix nanoseconds.
wall_now :: proc() -> i64 {
	return lockstep ? lock_epoch + i64(vclock) : time.time_to_unix_nano(time.now())
}

// A frame presented: the virtual clock is at least the next frame's start,
// and pad_in holds the next frame's inputs.
lock_frame :: proc() {
	vframe += 1
	vclock = max(vclock, time.Duration(vframe) * LOCK_STEP)
	if net_on {
		net_frame(vframe + 1, pad_sample(pad))
	} else {
		pad_in = {pad_sample(pad), pad_sample(pad2)}
	}
	if lock_hash_every > 0 && (vframe + 1) % lock_hash_every == 0 {
		fmt.eprintfln("lockstep: frame %d hash %016x clock %d mixed %d", vframe + 1, state_hash(), i64(vclock), ds_mixed)
	}
	if vframe + 1 == lock_dump_frame {lock_dump()}
}

// JE_LOCK_DUMP=frame:path: at that frame, the hashed memory written to
// path.img (from NET_IMG_LO), path.heap (from HEAP_LO) and path.va (from
// VA_LO), to find what two runs disagree on.
lock_dump_frame: i64
lock_dump_path: string

@(private = "file")
lock_dump :: proc() {
	parts := [3]struct {
		ext:    string,
		lo, hi: u32,
	}{{"img", NET_IMG_LO, NET_IMG_HI}, {"heap", HEAP_LO, heap_top}, {"va", VA_LO, va_top}}
	for d in parts {
		path := fmt.tprintf("%s.%s", lock_dump_path, d.ext)
		if err := os.write_entire_file(path, x86.mem[d.lo:d.hi]); err != nil {fmt.eprintfln("lockstep: cannot write %s: %v", path, err)}
	}
	fmt.eprintfln("lockstep: frame %d dumped to %s", vframe + 1, lock_dump_path)
}

// JE_LOCKSTEP=n: log the state hash every n frames, to compare two runs.
lock_hash_every: i64

// Host time since boot in milliseconds, for message and input event times.
host_ms :: proc() -> u32 {
	return u32(time.duration_milliseconds(host_now()))
}
