// Online play over UDP, input lockstep (lockstep.odin): the host is player
// 1 and the peer that joins player 2. Each peer sends the input of its own
// pad a delay of frames ahead of the frame it is for, and a frame starts only
// once both inputs for it are in. The host picks the delay from round trips
// it times in the handshake; then each peer moves its own with the round
// trips its inputs take to be acked. Every NET_HASH_EVERY frames
// each peer sends a hash of guest memory; a mismatch is a desync, logged.
// When the peer that joined leaves or is lost, the host plays on alone:
// player 2's input is released, so player 2 is out as with a couch pad off.
// The host keeps every frame's inputs and hashes from boot, so a peer that
// joins again while it plays alone (or after a restart) rejoins: it boots as
// the host did, replays the log as fast as frames go, then takes player 2
// back from a frame the host names. The joining peer always plays on the
// host's Save as it was at the host's boot, its JadeEmpire.ini and its
// gameplay settings, fetched from the host (net_save.odin), so a rejoin
// boots as the host's boot did. An open host (JE_NET_OPEN) plays alone from
// boot, so every peer joins it that way.
// JE_NET_HOST=port hosts, JE_NET_JOIN=host:port joins; JE_NET_DELAY on the
// host sets the delay in frames instead, and on either peer keeps its fixed.
// A game the main menu started (JE_NET_MENU, native/menu_online.odin) that
// fails or ends for the joining peer starts over offline (relaunch.odin)
// rather than exiting.
// WHY: docs/hle.md §11
package win32

import "base:intrinsics"
import "core:fmt"
import "core:hash/xxhash"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "vendor:zlib"
import "../x86"

NET_MAGIC :: 0x494e454a // "JENI"
NET_VERSION :: 9
// The delay covers half the round trip most pings came back within
// (NET_PING_KEEP of NET_PINGS) plus NET_DELAY_MARGIN frames for frame-time
// jitter, and is at least NET_DELAY_MIN.
NET_PINGS :: 16
NET_PING_KEEP :: 14
NET_PING_WAIT :: 250 * time.Millisecond
NET_DELAY_MARGIN :: 2
NET_DELAY_MIN :: 3
NET_DELAY_MAX :: 30
NET_DELAY_OPEN :: 4 // an open host's delay, before round trips move it
// In play, the delay a peer's inputs need is the same pick over the last
// NET_RTT_N round trips from an input made to the peer's ack of it. The
// delay rises a frame a frame while it is short, and once none has asked for
// as much for NET_CALM, falls a frame a frame to what they ask.
NET_RTT_N :: 64
NET_CALM :: time.Second
NET_STALL :: time.Millisecond // a wait longer than this counts as a stall
NET_RING :: 128 // inputs kept per player, a power of 2
NET_SEND_MAX :: 32 // inputs per packet
#assert(NET_SEND_MAX < NET_HASH_EVERY && NET_SEND_MAX <= NET_COUNT)
// A peer stalled on the other's input sends its own again after NET_RESEND,
// then after twice as long each time, up to NET_RESEND_MAX: quick when a
// packet was lost, few packets while a slow link catches up.
NET_RESEND :: 5 * time.Millisecond
NET_RESEND_MAX :: 250 * time.Millisecond
NET_LOST :: 10 * time.Second
NET_JOIN_WAIT :: 30 * time.Second
NET_HASH_EVERY :: 60
// The guest image, the port's data page included: the game's globals. The
// heap and VirtualAlloc regions are hashed up to their tops.
NET_HASH_LO :: 0x00400000
NET_HASH_HI :: 0x00a01000
// A rejoining peer asks for the log up to NET_LOG_AHEAD frames past the one
// it plays, every NET_LOG_ASK while it holds less than half of that; each
// ask is answered with up to NET_LOG_BURST packets of NET_LOG_BYTES at most.
// Within NET_READY_LAG frames of the host's last it says it is ready, every
// NET_READY_EVERY until the host names the handover frame, NET_HANDOVER_LEAD
// frames past its last.
NET_LOG_AHEAD :: 4096
NET_LOG_ASK :: 20 * time.Millisecond
NET_LOG_BURST :: 16
NET_LOG_BYTES :: 1200
NET_READY_LAG :: 30
NET_READY_EVERY :: 50 * time.Millisecond
NET_HANDOVER_LEAD :: 60
// The joining peer asks for a blob (net_save.odin) from the byte it has,
// again every NET_BLOB_ASK or once a burst is in; each ask is answered with
// up to NET_BLOB_BURST packets of NET_LOG_BYTES at most.
NET_BLOB_BURST :: 32
NET_BLOB_ASK :: 50 * time.Millisecond
// The most the joining peer takes the host's manifest to inflate to; a Save
// of thousands of files with a long ini is well under 1 MB.
NET_MANIFEST_MAX :: 16 << 20
Net_Kind :: enum u8 {Input = 1, Hello, Welcome, Reject, Bye, Ping, Pong, Log_Req, Log, Ready, Handover, Blob_Req, Blob}

Net_Head :: struct #packed {
	magic: u32,
	kind:  Net_Kind,
}

// What both peers must have the same of, each part hashed apart so a
// mismatch can say which. Save, the ini and the settings come from the host.
Net_Config :: struct #packed {
	version: u32,
	port:    u64, // this port's own binary: same code, same -microarch
	exe:     u64, // the unpacked game exe
	files:   u64, // names and sizes under override and textures_hd
}

// hero: the hero the joining peer, player 2, picked.
Net_Hello :: struct #packed {
	using head: Net_Head,
	cfg:        Net_Config,
	hero:       i32,
}

// A ping from the host while it times round trips, echoed back as a pong.
Net_Ping :: struct #packed {
	using head: Net_Head,
	seq:        u32,
}

// hero: player 2's hero, the one the hello carried, or for a rejoin the one
// of the session's start; switches: for a rejoin, the hero switches of the
// session so far, which its replay makes again.
Net_Welcome :: struct #packed {
	using head: Net_Head,
	epoch:      i64,
	delay:      i32,
	hero:       i32,
	rejoin:     b8,
	switch_n:   u8,
	switches:   [NET_SWITCH_MAX]Net_Switch,
}

// At frame, player 2's hero becomes hero: a rejoin's handover to a peer
// that picked another. A session holds NET_SWITCH_MAX; past that the hero
// stays.
Net_Switch :: struct #packed {
	frame: u32,
	hero:  i32,
}
NET_SWITCH_MAX :: 16

// The hero native code switches player 2 to at the next frame it sets player
// 2's creature up, or -1: set on both peers at the frame of a switch.
net_hero_switch: i32 = -1

// Which part of the config differs, as the host tells a peer it turns away.
Net_Mismatch :: enum u8 {None, Version, Port, Exe, Files}

NET_MISMATCH_SAY := [Net_Mismatch]string {
	.None     = "the host turned us away",
	.Version  = "the host runs another version of the port",
	.Port     = "the host runs another build of the port (both need the same jade)",
	.Exe      = "the host has another JadeEmpire.exe",
	.Files    = "the host's override or textures_hd differ from ours",
}

Net_Reject :: struct #packed {
	using head: Net_Head,
	why:        Net_Mismatch,
}

// A rejoining peer's ask for the log's frames from up to to.
Net_Log_Req :: struct #packed {
	using head: Net_Head,
	from, to:   u32,
}

// Frames first to first + count of the host's log, the host's last frame
// top. Each frame is the state hash first when it is a NET_HASH_EVERY one,
// then both players' inputs, each against the frame before's in the packet
// (against a released pad for the first), as in Net_Input.
Net_Log :: struct #packed {
	using head: Net_Head,
	first, top: u32,
	count:      u16,
}

// The joining peer's ask for blob id from its byte from on.
Net_Blob_Req :: struct #packed {
	using head: Net_Head,
	id, from:   u32,
}

// Bytes at to at + count of blob id, deflated, size bytes in all, raw
// inflated; size 0 when the host cannot send it.
Net_Blob :: struct #packed {
	using head:    Net_Head,
	id, size, raw: u32,
	at:            u32,
	count:         u16,
}

// The frame from which the rejoined peer plays player 2 again, and the
// delay its inputs start at.
Net_Handover :: struct #packed {
	using head: Net_Head,
	start:      u32,
	delay:      i32,
}

// An input packet: the kind byte alone for a head, as input is taken only
// from the peer's address; ack, the last frame of the receiver's inputs the
// sender has, and first, the first frame of those carried, as their low 16
// bits; then count, the inputs carried, with NET_HAS_HASH set when the
// sender's last hash (Net_Hash) follows. Each input then follows, against the
// one before it (frame first - 1's, which the receiver has, for the first):
// a byte of NET_CHANGED bits, one per axis, NET_BUTTONS and NET_ON, then for
// each changed axis the difference zigzagged and for changed buttons the
// bits that flipped, as LEB128 varints. A pad held still costs a byte a
// frame. The hash rides with the input of frame hash_at, the first one made
// after it, so it is sent until the peer has that input.
Net_Input :: struct #packed {
	kind:  Net_Kind,
	ack:   u16,
	first: u16,
	count: u8,
}
NET_COUNT :: 0x7f
NET_HAS_HASH :: 0x80
// hash_frame as its low 16 bits.
Net_Hash :: struct #packed {
	frame: u16,
	hash:  u64,
}
NET_BUTTONS :: len(Pad_Axis)
NET_ON :: NET_BUTTONS + 1
#assert(NET_ON < 8)
NET_INPUT_MAX :: 1 + len(Pad_Axis) * 3 + 3 // bytes, one input at most

net_on := false
net_slot: int // the local player: 0 the host, 1 the peer that joined
net_menu := false // JE_NET_MENU: the main menu started this game

@(private = "file")
Net :: struct {
	sock:        net.UDP_Socket,
	peer:        net.Endpoint,
	delay:       i64,
	fixed:       bool, // JE_NET_DELAY: the delay does not move
	delay_lo:    i64,
	delay_hi:    i64,
	made:        [NET_RING]time.Tick, // when each local input was made
	rtt:         [NET_RTT_N]time.Duration, // the last round trips, a ring
	rtt_n:       int,
	calm:        time.Tick, // the last time the round trips asked for the delay or more
	frame_end:   time.Tick, // when the last frame's wait for the peer ended
	work:        time.Duration, // the last frame's time less its wait
	cfg:         Net_Config,
	hero:        i32,
	pick:        i32, // the joining peer's pick of player 2's hero
	switches:    [dynamic]Net_Switch,
	epoch:       i64,
	local:       [NET_RING]Pad_Input,
	remote:      [NET_RING]Pad_Input,
	local_top:   i64, // last frame with a local input
	remote_top:  i64, // last frame with the peer's input, all before it in too
	acked:       i64, // last frame of local input the peer has
	sent_at:     time.Tick,
	hash_frame:  i64,
	hash:        u64,
	hash_at:     i64, // the first local input made after the hash
	peer_frame:  i64, // the peer's last hash
	peer_hash:   u64,
	desynced:    bool,
	alone:       bool, // the host, its peer gone: no input from a peer
	// The host's every frame's inputs and every NET_HASH_EVERY frame's hash
	// from boot, by frame and by frame / NET_HASH_EVERY, to serve a rejoin;
	// on a rejoining peer, those it has of them.
	log:         [dynamic][2]Pad_Input,
	hashes:      [dynamic]u64,
	rejoin:      bool, // the joining peer, replaying the log
	rejoining:   bool, // the host, alone with a peer rejoining
	handover:    i64, // the frame the rejoining peer plays from, 0 before it is named
	heard:       time.Tick, // last packet from the peer, while rejoining
	asked:       time.Tick, // last log ask
	readied:     time.Tick, // last ready
	host_top:    i64, // the host's last frame, as the log last said
	sent, recvd: [2]i64, // packets and bytes in play
	stalls:      i64, // frames that waited on the peer over NET_STALL
	stalled:     time.Duration,
	waiting:     time.Tick, // start of the wait for the peer's input, while in it
	// On the joining peer, the blob it fetches: its id, the bytes in so
	// far, and its sizes once a packet of it has come.
	blob_id:     u32,
	blob:        [dynamic]u8,
	blob_size:   u32,
	blob_raw:    u32,
	blob_known:  bool,
}
@(private = "file")
nt: Net

// Hosts on port or joins addr (host:port), then agrees with the peer on the
// game's start; before boot, before the settings are in force. settings:
// every setting's value, which the host sends the joining peer (net_save.odin);
// hero: this peer's pick of player 2's hero; open: host without waiting,
// alone until a peer joins. Returns player 2's hero: the joining peer's pick,
// or an open host's own. The joining peer then has net_save, net_ini and
// net_settings.
net_connect :: proc(port: string, addr: string, exe: string, settings: []i32, hero: i32, open: bool) -> i32 {
	nt.cfg = {
		version = NET_VERSION,
		port    = file_hash(self_path()),
		exe     = file_hash(exe),
		files   = files_hash(),
	}
	// Frames 0 and 1 run before the first exchange, on released pads.
	append(&nt.log, [2]Pad_Input{}, [2]Pad_Input{})
	append(&nt.hashes, 0)
	nt.delay = -1
	nt.hero, nt.pick = hero, hero
	if d, ok := strconv.parse_int(os.get_env("JE_NET_DELAY", context.temp_allocator), 10); ok {
		nt.delay = i64(clamp(d, 0, NET_DELAY_MAX))
		nt.fixed = true
	}
	net_on = true
	if port != "" {
		p, ok := strconv.parse_int(port, 10)
		if !ok {net_fail("JE_NET_HOST=%s is not a port", port)}
		sock, err := net.make_bound_udp_socket(net.IP4_Any, p)
		if err != nil {net_fail("cannot listen on port %d: %v", p, err)}
		nt.sock = sock
		net_slot = 0
		nt.epoch = time.time_to_unix_nano(time.now())
		net_save_host(settings)
		if open {
			nt.alone = true
			if nt.delay < 0 {nt.delay = NET_DELAY_OPEN}
			fmt.eprintfln("net: hosting on port %d, open: peers join while it plays", p)
			upnp_start(p)
		} else {
			fmt.eprintfln("net: hosting on port %d, waiting for a peer", p)
			net_host_wait()
		}
	} else {
		ep, err := net.resolve_ip4(addr)
		if err != nil {net_fail("cannot resolve %s: %v", addr, err)}
		sock, serr := net.make_unbound_udp_socket(.IP4)
		if serr != nil {net_fail("cannot open a socket: %v", serr)}
		nt.sock, nt.peer = sock, ep
		net_slot = 1
		fmt.eprintfln("net: joining %s", net.endpoint_to_string(ep))
		net_join_wait()
		title_set(fmt.tprintf("online with %s", addr))
	}
	if net.set_blocking(nt.sock, false) != nil {net_fail("cannot make the socket non-blocking")}
	if net_slot == 1 {
		// A host that is not open answers once it boots, after its welcome.
		m, _ := net_blob_fetch(NET_BLOB_MANIFEST, "list of its Save", NET_MANIFEST_MAX, NET_JOIN_WAIT)
		net_save_join(m)
		delete(m)
		if nt.rejoin {
			lock_fast = true
			nt.heard = time.tick_now()
			fmt.eprintfln("net: rejoining a game in play, player 2's hero %d", nt.hero)
		}
	}
	lock_epoch = nt.epoch
	// Frames up to the delay have no input from either side: centred,
	// released. Both peers have them.
	nt.local_top, nt.remote_top, nt.acked = nt.delay, nt.delay, nt.delay
	nt.delay_lo, nt.delay_hi = nt.delay, nt.delay
	nt.calm = time.tick_now()
	if !open {fmt.eprintfln("net: connected to %s as player %d, delay %d frames, player 2's hero %d", net.endpoint_to_string(nt.peer), net_slot + 1, nt.delay, nt.hero)}
	return nt.hero
}

// Logs why online play cannot go on and exits, or for a game the main menu
// started, starts over offline with the reason for the menu to show.
net_fail :: proc(f: string, args: ..any) -> ! {
	msg := fmt.tprintf(f, ..args)
	fmt.eprintln("net:", msg)
	if net_menu {relaunch(false, fmt.tprintf("JE_NET_ERROR=%s", msg))}
	game_exit(1, false)
}

// At exit: the socket closed, so a game run again can take its port.
net_close :: proc() {
	if !net_on || nt.sock == 0 {return}
	net.close(nt.sock)
	nt.sock = 0
}

@(private = "file")
net_send :: proc(p: ^$T) {
	net_send_to(p, nt.peer)
}

@(private = "file")
net_send_to :: proc(p: ^$T, to: net.Endpoint) {
	p.magic = NET_MAGIC
	_, _ = net.send_udp(nt.sock, slice.bytes_from_ptr(p, size_of(T)), to)
}

// Blocks until a peer says hello with the same config, and welcomes it.
@(private = "file")
net_host_wait :: proc() {
	buf: [2048]u8
	for {
		n, from, err := net.recv_udp(nt.sock, buf[:])
		if err != nil || n < size_of(Net_Hello) {continue}
		h := (^Net_Hello)(&buf[0])
		if h.magic != NET_MAGIC || h.kind != .Hello {continue}
		nt.peer = from
		if why := net_cfg_check(h.cfg); why != .None {
			r := Net_Reject{kind = .Reject, why = why}
			net_send(&r)
			continue
		}
		nt.hero = h.hero
		if nt.delay < 0 {nt.delay = net_pick_delay()}
		net_welcome(false)
		return
	}
}

// Times NET_PINGS round trips to the peer, one at a time, and picks the
// delay from them.
@(private = "file")
net_pick_delay :: proc() -> i64 {
	if net.set_option(nt.sock, .Receive_Timeout, 20 * time.Millisecond) != nil {
		net_fail("cannot set a receive timeout")
	}
	rtt: [NET_PINGS]time.Duration
	got := 0
	buf: [2048]u8
	for i in 0 ..< NET_PINGS {
		p := Net_Ping{kind = .Ping, seq = u32(i)}
		net_send(&p)
		sent := time.tick_now()
		for time.tick_since(sent) < NET_PING_WAIT {
			n, from, err := net.recv_udp(nt.sock, buf[:])
			if err != nil || from != nt.peer || n < size_of(Net_Ping) {continue}
			r := (^Net_Ping)(&buf[0])
			if r.magic != NET_MAGIC || r.kind != .Pong || r.seq != u32(i) {continue}
			rtt[got] = time.tick_since(sent)
			got += 1
			break
		}
	}
	if got == 0 {net_fail("no pings came back")}
	slice.sort(rtt[:got])
	hi := rtt_pick(rtt[:got])
	d := delay_for(hi)
	ms :: time.duration_milliseconds
	fmt.eprintfln("net: %d of %d pings back, round trip %.1f to %.1f ms, %.1f ms within %d of %d; delay %d frames", got, NET_PINGS, ms(rtt[0]), ms(rtt[got - 1]), ms(hi), NET_PING_KEEP, NET_PINGS, d)
	return d
}

// Of the round trips rtt, sorted, the one NET_PING_KEEP of NET_PINGS came
// back within.
@(private = "file")
rtt_pick :: proc(rtt: []time.Duration) -> time.Duration {
	return rtt[min(len(rtt) - 1, NET_PING_KEEP * len(rtt) / NET_PINGS)]
}

// The delay that covers half the round trip rtt.
@(private = "file")
delay_for :: proc(rtt: time.Duration) -> i64 {
	d := i64((rtt / 2 + LOCK_STEP - 1) / LOCK_STEP) + NET_DELAY_MARGIN
	return clamp(d, NET_DELAY_MIN, NET_DELAY_MAX)
}

@(private = "file")
net_welcome :: proc(rejoin: bool) {
	w := Net_Welcome{kind = .Welcome, epoch = nt.epoch, delay = i32(nt.delay), hero = nt.hero, rejoin = b8(rejoin)}
	w.switch_n = u8(len(nt.switches))
	copy(w.switches[:], nt.switches[:])
	net_send(&w)
}

// Says hello until the host welcomes or rejects us.
@(private = "file")
net_join_wait :: proc() {
	if net.set_option(nt.sock, .Receive_Timeout, 100 * time.Millisecond) != nil {
		net_fail("cannot set a receive timeout")
	}
	start := time.tick_now()
	hello: time.Tick
	buf: [2048]u8
	for time.tick_since(start) < NET_JOIN_WAIT {
		if time.tick_since(hello) >= 100 * time.Millisecond {
			h := Net_Hello{kind = .Hello, cfg = nt.cfg, hero = nt.hero}
			net_send(&h)
			hello = time.tick_now()
		}
		n, _, err := net.recv_udp(nt.sock, buf[:])
		if err != nil || n < size_of(Net_Head) {continue}
		head := (^Net_Head)(&buf[0])
		if head.magic != NET_MAGIC {continue}
		#partial switch head.kind {
		case .Ping:
			if n < size_of(Net_Ping) {continue}
			p := (^Net_Ping)(&buf[0])^
			p.kind = .Pong
			net_send(&p)
		case .Reject:
			why := n >= size_of(Net_Reject) ? (^Net_Reject)(&buf[0]).why : .None
			if why > max(Net_Mismatch) {why = .None}
			net_fail("%s", NET_MISMATCH_SAY[why])
		case .Welcome:
			if n < size_of(Net_Welcome) {continue}
			w := (^Net_Welcome)(&buf[0])
			nt.epoch, nt.delay, nt.hero, nt.rejoin = w.epoch, i64(w.delay), w.hero, bool(w.rejoin)
			clear(&nt.switches)
			append(&nt.switches, ..w.switches[:min(int(w.switch_n), NET_SWITCH_MAX)])
			return
		}
	}
	net_fail("no answer from the host")
}

// Logs the mismatch it returns.
@(private = "file")
net_cfg_check :: proc(c: Net_Config) -> Net_Mismatch {
	m := nt.cfg
	switch {
	case c.version != m.version: fmt.eprintfln("net: peer runs another port version (%d, ours %d)", c.version, m.version); return .Version
	case c.port != m.port: fmt.eprintln("net: peer runs another build of the port (copy one jade binary to both)"); return .Port
	case c.exe != m.exe: fmt.eprintln("net: peer has another JadeEmpire.exe"); return .Exe
	case c.files != m.files: fmt.eprintln("net: peer's override or textures_hd differ"); return .Files
	}
	return .None
}

// At a frame boundary: sends this peer's input for frame next + delay and
// waits for the peer's input for frame next, then puts both in pad_in.
// Each peer's inputs are a run of frames only it writes, so it moves its
// delay alone: a rise repeats the last input for the frame it skips, and a
// fall makes no input, on a frame whose input is the last one's.
net_frame :: proc(next: i64, local: Pad_Input) {
	net_switch_at(next)
	if nt.rejoin && !net_replay(next) {return}
	if nt.alone && next != nt.handover {
		net_alone(next, local)
		return
	}
	if next == nt.handover {net_hand_over(next)}
	now := time.tick_now()
	if nt.frame_end != {} {nt.work = time.tick_diff(nt.frame_end, now)}
	net_delay_step(local)
	top := next + nt.delay
	for f in nt.local_top + 1 ..= top {
		nt.local[f & (NET_RING - 1)] = f == top ? local : nt.local[nt.local_top & (NET_RING - 1)]
		nt.made[f & (NET_RING - 1)] = now
	}
	nt.local_top = max(nt.local_top, top)
	if next % NET_HASH_EVERY == 0 {
		nt.hash_frame, nt.hash, nt.hash_at = next, net_hash(next), nt.local_top
		net_hash_check()
	}
	start := time.tick_now()
	nt.waiting = start
	net_send_inputs()
	resend := NET_RESEND
	for nt.remote_top < next {
		net_recv()
		if nt.alone {break}
		if nt.remote_top >= next {break}
		if time.tick_since(nt.sent_at) >= resend {
			net_send_inputs()
			resend = min(2 * resend, NET_RESEND_MAX)
		}
		if time.tick_since(start) > NET_LOST {
			net_gone("peer lost at frame %d", next)
			break
		}
		time.sleep(200 * time.Microsecond)
	}
	nt.waiting = {}
	// A peer that waited runs ahead of the other: its frame schedule moves
	// later by the wait, so it does not catch up with a burst of frames
	// and wait again.
	if w := time.tick_since(start); w > NET_STALL {
		net_stall_add(w)
		fps_next = time.tick_add(fps_next, w)
	}
	nt.frame_end = time.tick_now()
	net_recv()
	if nt.alone {
		pad_in[0], pad_in[1] = local, {}
	} else {
		pad_in[net_slot] = nt.local[next & (NET_RING - 1)]
		pad_in[1 - net_slot] = nt.remote[next & (NET_RING - 1)]
	}
	net_log_add(next)
}

// The host's frame next with no peer in play: player 2 released. It still
// hashes and logs the frame, and takes in a rejoin.
@(private = "file")
net_alone :: proc(next: i64, local: Pad_Input) {
	pad_in[0], pad_in[1] = local, {}
	if next % NET_HASH_EVERY == 0 {_ = net_hash(next)}
	net_log_add(next)
	net_recv()
	if nt.rejoining && time.tick_since(nt.heard) > NET_LOST {net_drop("rejoining peer lost at frame %d", next)}
}

// The state hash at frame next, which the host logs.
@(private = "file")
net_hash :: proc(next: i64) -> u64 {
	h := state_hash()
	if net_slot == 0 {
		assert(i64(len(nt.hashes)) == next / NET_HASH_EVERY)
		append(&nt.hashes, h)
	}
	return h
}

// On the host, frame next's inputs, pad_in, onto the log.
@(private = "file")
net_log_add :: proc(next: i64) {
	if net_slot != 0 {return}
	assert(i64(len(nt.log)) == next)
	append(&nt.log, [2]Pad_Input{pad_in[0], pad_in[1]})
}

// The rejoining peer's frame next: its inputs from the log, waited for, and
// the hash checked against the host's. True at the handover frame instead,
// which plays on as lockstep.
@(private = "file")
net_replay :: proc(next: i64) -> bool {
	if nt.handover != 0 && next >= nt.handover {return true}
	for i64(len(nt.log)) <= next {
		net_recv()
		if nt.handover != 0 && next >= nt.handover {return true}
		net_log_ask(next)
		if time.tick_since(nt.heard) > NET_LOST {net_gone("host lost at frame %d", next)}
		time.sleep(200 * time.Microsecond)
	}
	net_recv()
	net_log_ask(next)
	if nt.handover == 0 && nt.host_top != 0 && nt.host_top - next <= NET_READY_LAG && time.tick_since(nt.readied) >= NET_READY_EVERY {
		r := Net_Head{kind = .Ready}
		net_send(&r)
		nt.readied = time.tick_now()
	}
	pad_in = nt.log[next]
	if next % NET_HASH_EVERY == 0 && !nt.desynced {
		if h := state_hash(); h != nt.hashes[next / NET_HASH_EVERY] {
			fmt.eprintfln("net: desync replaying frame %d (ours %016x, host %016x)", next, h, nt.hashes[next / NET_HASH_EVERY])
			nt.desynced = true
		}
	}
	return false
}

// Asks the host for more of the log when this rejoining peer, at frame
// next, holds less than half of NET_LOG_AHEAD past it.
@(private = "file")
net_log_ask :: proc(next: i64) {
	have := i64(len(nt.log))
	if have - next >= NET_LOG_AHEAD / 2 || time.tick_since(nt.asked) < NET_LOG_ASK {return}
	r := Net_Log_Req{kind = .Log_Req, from = u32(have), to = u32(next + NET_LOG_AHEAD)}
	net_send(&r)
	nt.asked = time.tick_now()
}

// The host's answer to a log ask r: up to NET_LOG_BURST packets of the log
// from r.from, none past the handover frame.
@(private = "file")
net_log_send :: proc(r: ^Net_Log_Req) {
	top := i64(len(nt.log))
	if nt.handover != 0 {top = min(top, nt.handover)}
	f, to := i64(r.from), min(i64(r.to), top)
	for _ in 0 ..< NET_LOG_BURST {
		if f >= to {return}
		buf: [NET_LOG_BYTES]u8
		p := (^Net_Log)(&buf[0])
		p^ = {magic = NET_MAGIC, kind = .Log, first = u32(f), top = u32(len(nt.log) - 1)}
		n := size_of(Net_Log)
		prev: [2]Pad_Input
		for f < to && n + size_of(u64) + 2 * NET_INPUT_MAX <= len(buf) && p.count < max(u16) {
			if f % NET_HASH_EVERY == 0 {
				intrinsics.unaligned_store((^u64)(&buf[n]), nt.hashes[f / NET_HASH_EVERY])
				n += size_of(u64)
			}
			for i in 0 ..< 2 {
				n += input_put(buf[n:], prev[i], nt.log[f][i])
				prev[i] = nt.log[f][i]
			}
			f += 1
			p.count += 1
		}
		_, _ = net.send_udp(nt.sock, buf[:n], nt.peer)
	}
}

// A log packet b from the host, on a rejoining peer: the frames past those
// it has, when it has those before them.
@(private = "file")
net_log_take :: proc(b: []u8) {
	if len(b) < size_of(Net_Log) {return}
	p := (^Net_Log)(&b[0])
	nt.host_top = max(nt.host_top, i64(p.top))
	first := i64(p.first)
	if first > i64(len(nt.log)) {return}
	n := size_of(Net_Log)
	prev: [2]Pad_Input
	for f in first ..< first + i64(p.count) {
		h: u64
		if f % NET_HASH_EVERY == 0 {
			if len(b) < n + size_of(u64) {return}
			h = intrinsics.unaligned_load((^u64)(&b[n]))
			n += size_of(u64)
		}
		in_: [2]Pad_Input
		for i in 0 ..< 2 {
			k: int
			in_[i], k = input_get(b[n:], prev[i])
			if k == 0 {return}
			n += k
		}
		prev = in_
		if f < i64(len(nt.log)) {continue}
		if f % NET_HASH_EVERY == 0 {append(&nt.hashes, h)}
		append(&nt.log, in_)
	}
}

// A hero switch at frame f, on both peers: at a handover the rejoined peer's
// pick, the host having it from the hello, joins the session's list when it
// is not player 2's hero already, so a rejoin on the same hero takes no
// place in the list; one the list has for f, as a replay meets them, goes to
// native code.
@(private = "file")
net_switch_at :: proc(f: i64) {
	n := len(nt.switches)
	now := n == 0 ? nt.hero : nt.switches[n - 1].hero
	if f == nt.handover && n < NET_SWITCH_MAX && nt.pick != now && (n == 0 || i64(nt.switches[n - 1].frame) != f) {
		append(&nt.switches, Net_Switch{frame = u32(f), hero = nt.pick})
	}
	for sw in nt.switches {
		if i64(sw.frame) == f {net_hero_switch = sw.hero}
	}
}

// At the handover frame s, on both peers: lockstep again, from the log's
// inputs before s. The host's inputs for s up to s + delay repeat its last,
// frame s - 1's, and the rejoined peer's are released, as player 2's were.
@(private = "file")
net_hand_over :: proc(s: i64) {
	d := nt.delay
	now := time.tick_now()
	host, peer: ^[NET_RING]Pad_Input = &nt.local, &nt.remote
	if net_slot != 0 {host, peer = &nt.remote, &nt.local}
	host[(s - 1) & (NET_RING - 1)] = nt.log[s - 1][0]
	for f in s ..< s + d {
		peer[f & (NET_RING - 1)] = {}
		nt.made[f & (NET_RING - 1)] = now
	}
	if net_slot == 0 {
		nt.local_top, nt.remote_top, nt.acked = s - 1, s + d - 1, s - 1
		nt.alone = false
	} else {
		nt.local_top, nt.remote_top, nt.acked = s + d - 1, s - 1, s + d - 1
		nt.rejoin = false
		delete(nt.log)
		delete(nt.hashes)
		nt.log, nt.hashes = {}, {}
		lock_fast_set(false)
	}
	nt.rtt_n, nt.calm, nt.frame_end, nt.work = 0, now, {}, 0
	nt.delay_lo, nt.delay_hi = d, d
	nt.peer_frame, nt.hash_frame, nt.desynced = 0, 0, false
	fmt.eprintfln("net: player 2 back in play at frame %d, delay %d frames", s, d)
}

// Moves the delay a frame toward what the last round trips ask for: up at
// once, down only after NET_CALM with none asking as much and when this
// frame's input local is the last one's, so the input not made loses nothing.
@(private = "file")
net_delay_step :: proc(local: Pad_Input) {
	if nt.fixed || nt.rtt_n == 0 {return}
	rtt: [NET_RTT_N]time.Duration
	n := min(nt.rtt_n, NET_RTT_N)
	copy(rtt[:], nt.rtt[:n])
	slice.sort(rtt[:n])
	hi := rtt_pick(rtt[:n])
	want := delay_for(hi)
	if want >= nt.delay {nt.calm = time.tick_now()}
	switch {
	case want > nt.delay:
		nt.delay += 1
	case want < nt.delay && time.tick_since(nt.calm) >= NET_CALM && local == nt.local[nt.local_top & (NET_RING - 1)]:
		nt.delay -= 1
	case:
		return
	}
	nt.delay_lo, nt.delay_hi = min(nt.delay_lo, nt.delay), max(nt.delay_hi, nt.delay)
	fmt.eprintfln("net: delay %d frames at frame %d, round trip %.1f ms", nt.delay, vframe + 1, time.duration_milliseconds(hi))
}

@(private = "file")
net_send_inputs :: proc() {
	buf: [size_of(Net_Input) + size_of(Net_Hash) + NET_SEND_MAX * NET_INPUT_MAX]u8
	first := nt.acked + 1
	count := clamp(nt.local_top - first + 1, 0, NET_SEND_MAX)
	at := nt.hash_at
	has_hash := nt.hash_frame != 0 && at >= first && at < first + count
	p := (^Net_Input)(&buf[0])
	p^ = {kind = .Input, ack = u16(nt.remote_top), first = u16(first), count = u8(count) | (has_hash ? NET_HAS_HASH : 0)}
	n := size_of(Net_Input)
	if has_hash {
		(^Net_Hash)(&buf[n])^ = {u16(nt.hash_frame), nt.hash}
		n += size_of(Net_Hash)
	}
	prev := nt.local[(first - 1) & (NET_RING - 1)]
	for f in first ..< first + count {
		in_ := nt.local[f & (NET_RING - 1)]
		n += input_put(buf[n:], prev, in_)
		prev = in_
	}
	_, _ = net.send_udp(nt.sock, buf[:n], nt.peer)
	nt.sent += {1, i64(n)}
	nt.sent_at = time.tick_now()
}

// The frame nearest ref with the low 16 bits low.
@(private = "file")
frame_near :: proc(ref: i64, low: u16) -> i64 {
	return ref + i64(i16(low - u16(ref)))
}

// Writes in_ against prev at the start of b; returns the bytes written.
@(private = "file")
input_put :: proc(b: []u8, prev, in_: Pad_Input) -> int {
	mask := u8(0)
	n := 1
	for a, i in Pad_Axis {
		d := i32(in_.axes[a]) - i32(prev.axes[a])
		if d == 0 {continue}
		mask |= 1 << u8(i)
		n += varint_put(b[n:], u32((d << 1) ~ (d >> 31)))
	}
	if x := in_.buttons ~ prev.buttons; x != 0 {
		mask |= 1 << NET_BUTTONS
		n += varint_put(b[n:], u32(x))
	}
	if in_.on != prev.on {mask |= 1 << NET_ON}
	b[0] = mask
	return n
}

// Reads an input against prev from the start of b: the input and the bytes
// read, 0 when b ends first.
@(private = "file")
input_get :: proc(b: []u8, prev: Pad_Input) -> (in_: Pad_Input, n: int) {
	if len(b) == 0 {return}
	mask := b[0]
	in_ = prev
	at := 1
	for a, i in Pad_Axis {
		if mask & (1 << u8(i)) == 0 {continue}
		v, k := varint_get(b[at:])
		if k == 0 {return {}, 0}
		at += k
		in_.axes[a] = i16(i32(prev.axes[a]) + (i32(v >> 1) ~ -i32(v & 1)))
	}
	if mask & (1 << NET_BUTTONS) != 0 {
		v, k := varint_get(b[at:])
		if k == 0 {return {}, 0}
		at += k
		in_.buttons = prev.buttons ~ u16(v)
	}
	if mask & (1 << NET_ON) != 0 {in_.on = !prev.on}
	return in_, at
}

@(private = "file")
varint_put :: proc(b: []u8, v: u32) -> int {
	v := v
	n := 0
	for v >= 0x80 {
		b[n] = u8(v) | 0x80
		v >>= 7
		n += 1
	}
	b[n] = u8(v)
	return n + 1
}

// The value and the bytes read, 0 when b ends first or the value runs past
// 32 bits.
@(private = "file")
varint_get :: proc(b: []u8) -> (v: u32, n: int) {
	for i in 0 ..< min(len(b), 5) {
		v |= u32(b[i] & 0x7f) << (7 * u32(i))
		if b[i] < 0x80 {return v, i + 1}
	}
	return 0, 0
}

// On the joining peer: blob id (net_save.odin), what for the log, fetched
// from the host and inflated, and the bytes it took; heap-allocated. Fails
// when the host goes wait without sending more of it, cannot send it, or
// says it inflates to more than max_raw bytes or deflates to more than
// zlib's bound for that, which fails before anything is inflated.
net_blob_fetch :: proc(id: u32, what: string, max_raw: u32, wait := NET_LOST) -> (data: []u8, sent: int) {
	nt.blob_id, nt.blob_known = id, false
	clear(&nt.blob)
	chunk := NET_LOG_BYTES - size_of(Net_Blob)
	asked: time.Tick
	asked_from := -1
	moved := time.tick_now()
	for !nt.blob_known || len(nt.blob) < int(nt.blob_size) {
		have := len(nt.blob)
		if time.tick_since(asked) >= NET_BLOB_ASK || have >= asked_from + NET_BLOB_BURST * chunk {
			r := Net_Blob_Req{kind = .Blob_Req, id = id, from = u32(have)}
			net_send(&r)
			asked, asked_from = time.tick_now(), have
		}
		net_recv()
		if len(nt.blob) > have {moved = time.tick_now()}
		if time.tick_since(moved) > wait {net_fail("the host did not send its %s", what)}
		if nt.blob_known && nt.blob_size == 0 {net_fail("the host cannot send its %s", what)}
		if nt.blob_known && (nt.blob_raw > max_raw || u64(nt.blob_size) > u64(zlib.compressBound(zlib.uLong(nt.blob_raw)))) {
			net_fail("the host sends its %s at %d bytes as %d, over %d", what, nt.blob_raw, nt.blob_size, max_raw)
		}
		time.sleep(200 * time.Microsecond)
	}
	return net_save_inflate(nt.blob[:], nt.blob_raw, what), len(nt.blob)
}

// The host's answer to a blob ask r: up to NET_BLOB_BURST packets of the
// blob from r.from, or one of size 0 when it cannot be sent.
@(private = "file")
net_blob_send :: proc(r: ^Net_Blob_Req) {
	data, raw, ok := net_save_blob(r.id)
	buf: [NET_LOG_BYTES]u8
	p := (^Net_Blob)(&buf[0])
	if !ok {
		p^ = {magic = NET_MAGIC, kind = .Blob, id = r.id}
		_, _ = net.send_udp(nt.sock, buf[:size_of(Net_Blob)], nt.peer)
		return
	}
	at := int(r.from)
	for _ in 0 ..< NET_BLOB_BURST {
		if at >= len(data) {return}
		n := min(len(data) - at, len(buf) - size_of(Net_Blob))
		p^ = {magic = NET_MAGIC, kind = .Blob, id = r.id, size = u32(len(data)), raw = raw, at = u32(at), count = u16(n)}
		copy(buf[size_of(Net_Blob):], data[at:at + n])
		_, _ = net.send_udp(nt.sock, buf[:size_of(Net_Blob) + n], nt.peer)
		at += n
	}
}

// A blob packet b from the host, on the joining peer: its bytes when they
// are of the blob it fetches and follow those it has.
@(private = "file")
net_blob_take :: proc(b: []u8) {
	if len(b) < size_of(Net_Blob) {return}
	p := (^Net_Blob)(&b[0])
	if p.id != nt.blob_id || len(b) < size_of(Net_Blob) + int(p.count) {return}
	nt.blob_known, nt.blob_size, nt.blob_raw = true, p.size, p.raw
	if int(p.at) != len(nt.blob) || len(nt.blob) + int(p.count) > int(p.size) {return}
	append(&nt.blob, ..b[size_of(Net_Blob):][:p.count])
}

// Takes in every packet waiting.
@(private = "file")
net_recv :: proc() {
	buf: [4096]u8
	for {
		n, from, err := net.recv_udp(nt.sock, buf[:])
		if err != nil {return}
		if n < 1 {continue}
		if from != nt.peer {
			if nt.alone {net_rejoin_hello(buf[:n], from)}
			continue
		}
		if Net_Kind(buf[0]) == .Input {
			if !nt.alone && !nt.rejoin {net_take_inputs(buf[:n])}
			continue
		}
		if n < size_of(Net_Head) {continue}
		head := (^Net_Head)(&buf[0])
		if head.magic != NET_MAGIC {continue}
		nt.heard = time.tick_now()
		if !net_take(head.kind, buf[:n], from) {return}
	}
}

// A packet b of kind k from the peer, from, other than input; false when it
// ended play with the peer.
@(private = "file")
net_take :: proc(k: Net_Kind, b: []u8, from: net.Endpoint) -> bool {
	serving := net_slot == 0 && (nt.rejoining || nt.handover != 0)
	#partial switch k {
	case .Hello:
		switch {
		case nt.alone: net_rejoin_hello(b, from)
		case nt.recvd[0] == 0: net_welcome(false) // our welcome was lost
		case:
			// It restarted: a rejoin.
			net_gone("peer restarted at frame %d", vframe + 1)
			net_rejoin_hello(b, from)
			return false
		}
	case .Bye:
		if nt.alone {
			if nt.rejoining {net_drop("rejoining peer left at frame %d", vframe + 1)}
		} else {
			net_gone("peer left at frame %d", vframe + 1)
		}
		return false
	case .Log_Req:
		if serving && len(b) >= size_of(Net_Log_Req) {net_log_send((^Net_Log_Req)(&b[0]))}
	case .Ready:
		if !serving {return true}
		if nt.handover == 0 {
			nt.handover = i64(len(nt.log)) + NET_HANDOVER_LEAD
			fmt.eprintfln("net: rejoining peer caught up at frame %d; player 2 back at frame %d", len(nt.log) - 1, nt.handover)
		}
		h := Net_Handover{kind = .Handover, start = u32(nt.handover), delay = i32(nt.delay)}
		net_send(&h)
	case .Log:
		if nt.rejoin {net_log_take(b)}
	case .Handover:
		if !nt.rejoin || nt.handover != 0 || len(b) < size_of(Net_Handover) {return true}
		h := (^Net_Handover)(&b[0])
		nt.handover, nt.delay = i64(h.start), i64(h.delay)
	case .Blob_Req:
		if net_slot == 0 && len(b) >= size_of(Net_Blob_Req) {net_blob_send((^Net_Blob_Req)(&b[0]))}
	case .Blob:
		if net_slot == 1 {net_blob_take(b)}
	}
	return true
}

// A hello b from from while the host plays alone: a rejoin, welcomed when
// its config matches ours. It takes the place of any rejoin before it.
@(private = "file")
net_rejoin_hello :: proc(b: []u8, from: net.Endpoint) {
	if net_slot != 0 || len(b) < size_of(Net_Hello) {return}
	h := (^Net_Hello)(&b[0])
	if h.magic != NET_MAGIC || h.kind != .Hello {return}
	if why := net_cfg_check(h.cfg); why != .None {
		r := Net_Reject{kind = .Reject, why = why}
		net_send_to(&r, from)
		return
	}
	if !nt.rejoining || from != nt.peer {
		fmt.eprintfln("net: %s rejoins at frame %d", net.endpoint_to_string(from), vframe + 1)
	}
	nt.peer, nt.rejoining, nt.handover, nt.heard = from, true, 0, time.tick_now()
	nt.pick = h.hero
	net_welcome(true)
}

// The rejoining peer left or was lost before play, as f says of the frame.
@(private = "file")
net_drop :: proc(f: string, frame: i64) {
	fmt.eprint("net: ")
	fmt.eprintfln(f, frame)
	nt.rejoining, nt.handover = false, 0
}

// The peer left or was lost, as f says of the frame. The game is the host's,
// which plays on alone; the peer that joined has nothing to play on.
@(private = "file")
net_gone :: proc(f: string, frame: i64) {
	fmt.eprint("net: ")
	fmt.eprintfln(f, frame)
	if net_slot != 0 {
		if net_menu {relaunch(false, fmt.tprintf("JE_NET_ERROR=the online game ended: %s", fmt.tprintf(f, frame)))}
		game_exit(0, false)
	}
	net_end(false)
	fmt.eprintln("net: playing on alone; the peer can join again")
	nt.alone, nt.rejoining, nt.handover = true, false, 0
}

// An input packet from the peer, b.
@(private = "file")
net_take_inputs :: proc(b: []u8) {
	if len(b) < size_of(Net_Input) {return}
	p := (^Net_Input)(&b[0])
	n := size_of(Net_Input)
	if p.count & NET_HAS_HASH != 0 {
		if len(b) < n + size_of(Net_Hash) {return}
		h := (^Net_Hash)(&b[n])
		n += size_of(Net_Hash)
		if f := frame_near(nt.remote_top, h.frame); f > nt.peer_frame {
			nt.peer_frame, nt.peer_hash = f, h.hash
			net_hash_check()
		}
	}
	nt.recvd += {1, i64(len(b))}
	nt.rejoining = false
	if acked := min(frame_near(nt.local_top, p.ack), nt.local_top); acked > nt.acked {
		nt.acked = acked
		// The ack goes out with the peer's next frame and is read at this
		// peer's next frame, a frame's work each that a ping does not wait.
		nt.rtt[nt.rtt_n % NET_RTT_N] = max(0, time.tick_since(nt.made[acked & (NET_RING - 1)]) - 2 * nt.work)
		nt.rtt_n += 1
	}
	// The first input is against frame first - 1's: one the ring still holds.
	first := frame_near(nt.remote_top + 1, p.first)
	if first > nt.remote_top + 1 || first <= nt.remote_top - NET_RING + 1 {return}
	prev := nt.remote[(first - 1) & (NET_RING - 1)]
	for f in first ..< first + i64(p.count & NET_COUNT) {
		in_, k := input_get(b[n:], prev)
		if k == 0 {return}
		n += k
		prev = in_
		if f <= nt.remote_top {continue}
		if f - nt.local_top >= NET_RING / 2 {net_fail("peer is %d frames ahead", f - nt.local_top)}
		nt.remote[f & (NET_RING - 1)] = in_
		nt.remote_top = f
	}
}

@(private = "file")
net_stall_add :: proc(w: time.Duration) {
	if w <= NET_STALL {return}
	nt.stalls += 1
	nt.stalled += w
}

@(private = "file")
net_hash_check :: proc() {
	if nt.desynced || nt.peer_frame == 0 || nt.peer_frame != nt.hash_frame {return}
	if nt.peer_hash != nt.hash {
		fmt.eprintfln("net: desync at frame %d (ours %016x, peer %016x)", nt.hash_frame, nt.hash, nt.peer_hash)
		nt.desynced = true
	}
}

// At exit: logs the traffic and, when bye is set, tells the peer this game
// is over.
net_end :: proc(bye: bool) {
	if !net_on {return}
	if bye && (!nt.alone || nt.rejoining) {
		b := Net_Head{kind = .Bye}
		for _ in 0 ..< 3 {net_send(&b)}
	}
	if nt.alone || nt.rejoin {return}
	// The peer lost or gone in a wait: the wait so far, which the log would
	// otherwise miss.
	if nt.waiting != {} {net_stall_add(time.tick_since(nt.waiting))}
	fmt.eprintfln("net: sent %d input packets, %d bytes; received %d, %d bytes; last hash checked frame %d", nt.sent[0], nt.sent[1], nt.recvd[0], nt.recvd[1], nt.peer_frame)
	ms :: time.duration_milliseconds
	fmt.eprintfln("net: %d frames stalled on the peer, %.0f ms in all; delay %d to %d frames", nt.stalls, ms(nt.stalled), nt.delay_lo, nt.delay_hi)
}

// The game's globals, heap and virtual memory, and the virtual clock.
state_hash :: proc() -> u64 {
	regions := [?][2]u32{{NET_HASH_LO, NET_HASH_HI}, {HEAP_LO, heap_top}, {VA_LO, va_top}}
	h: xxhash.XXH3_state
	xxhash.XXH3_64_reset(&h)
	for r in regions {xxhash.XXH3_64_update(&h, x86.mem[r[0]:r[1]])}
	clock := [2]u64{u64(vclock), u64(ds_mixed)}
	xxhash.XXH3_64_update(&h, slice.to_bytes(clock[:]))
	return xxhash.XXH3_64_digest(&h)
}

// The port's own executable.
@(private = "file")
self_path :: proc() -> string {
	p, err := os.get_executable_path(context.temp_allocator)
	if err != nil {net_fail("cannot find the port's executable: %v", err)}
	return p
}

@(private = "file")
file_hash :: proc(path: string) -> u64 {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {net_fail("cannot read %s", path)}
	return xxhash.XXH3_64(data)
}

// Every file under override and textures_hd, by path (lower case, sorted)
// and size.
@(private = "file")
files_hash :: proc() -> u64 {
	list: [dynamic]string
	list.allocator = context.temp_allocator
	walk :: proc(dir, name: string, list: ^[dynamic]string) {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {return}
		for fi in infos {
			p := fmt.tprintf("%s/%s", dir, fi.name)
			n := fmt.tprintf("%s/%s", name, fi.name)
			if fi.type == .Directory {
				walk(p, n, list)
			} else {
				append(list, fmt.tprintf("%s %d", strings.to_lower(n, context.temp_allocator), fi.size))
			}
		}
	}
	for d in ([]string{"override", "textures_hd"}) {walk(d, d, &list)}
	slice.sort(list[:])
	return xxhash.XXH3_64(transmute([]u8)strings.join(list[:], "\n", context.temp_allocator))
}
