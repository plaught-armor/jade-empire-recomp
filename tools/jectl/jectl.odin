// Client for the port's live control channel (JE_CTL=<dir>, docs/recompiler.md §7).
//
// Usage: jectl <dir> <command> [<command> ...]
//
// Each command is sent as one line and its answer printed. Commands run in
// order; each waits for its answer (timeout 120 s). Client-side commands:
//   png PATH [WIDTH]   screenshot the next frame to PATH as PNG, scaled to WIDTH
//                      (default 960).
// Everything else goes to the port as is: frame, wait N, shot PATH, key NAME [N],
// down NAME, up NAME, move X Y, click X Y [L|M|R], btn L|M|R down|up,
// pad NAME [N], axis NAME V, peek ADDR N, poke ADDR HEX, scan TYPE V, next V,
// list, set KEY VALUE ([Port] setting, until exit), quit.
package jectl

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import stbi "vendor:stb/image"
import "../common"

USAGE :: `Usage: jectl <dir> <command> [<command> ...]
Client-side command: png PATH [WIDTH]; everything else goes to the port as is.`

TIMEOUT :: 120 * time.Second
BATCH_MAX :: 48 // lines per batch, appended in one write
POLL :: 4 * time.Millisecond // between reads of the answer file (a frame is ~33 ms)

// Sends one command line, returns the answer text after the id.
send :: proc(d, line: string) -> string {
	return send_batch(d, {line})[0]
}

// Sends command lines in one write, so the port runs them in the same frame
// (it reads <dir>/in once per frame); returns their answers in order. A query
// that costs a frame per round trip is too slow to react to a foe's wind-up.
// WHY: docs/modding.md §3
send_batch :: proc(d: string, lines: []string) -> []string {
	fmt.assertf(0 < len(lines) && len(lines) <= BATCH_MAX, "%d lines", len(lines))
	out_path := strings.concatenate({d, "/out"})
	out, err := os.open(out_path)
	if err != nil do common.die("%s: %v", out_path, err)
	pos, _ := os.file_size(out)
	cid := fmt.aprintf("%d%06d", os.get_pid(), time.tick_now()._nsec / 1000 % 1000000)
	ids := make([]string, len(lines))
	sb := strings.builder_make()
	for ln, i in lines {
		ids[i] = fmt.aprintf("%s_%d", cid, i)
		fmt.sbprintf(&sb, "%s %s\n", ids[i], ln)
	}
	in_path := strings.concatenate({d, "/in"})
	f, ferr := os.open(in_path, {.Write, .Append, .Create})
	if ferr != nil do common.die("%s: %v", in_path, ferr)
	_, werr := os.write_string(f, strings.to_string(sb))
	os.close(f)
	if werr != nil do common.die("%s: %v", in_path, werr)
	got := make([]string, len(lines))
	have := make([]bool, len(lines))
	tail: [dynamic]u8
	buf: [1 << 16]u8
	left := len(lines)
	start := time.tick_now()
	for time.tick_since(start) < TIMEOUT {
		for {
			n, _ := os.read_at(out, buf[:], pos)
			if n <= 0 do break
			append(&tail, ..buf[:n])
			pos += i64(n)
		}
		done := strings.last_index_byte(string(tail[:]), '\n') + 1
		text := string(tail[:done])
		for ln in strings.split_lines_iterator(&text) {
			sp := strings.index_byte(ln, ' ')
			if sp < 0 do continue
			for id, k in ids {
				if !have[k] && ln[:sp] == id {
					got[k], have[k] = strings.clone(ln[sp + 1:]), true
					left -= 1
				}
			}
		}
		remove_range(&tail, 0, done)
		if left == 0 {
			os.close(out)
			return got
		}
		time.sleep(POLL)
	}
	common.die("timeout waiting for answers to %v", lines)
}

// Screenshot of the next frame as a PNG width pixels wide.
png :: proc(d, path: string, width: int) -> string {
	ppm := strings.concatenate({path, ".ppm"})
	// The port runs in the game directory, so it gets an absolute path.
	abs := ppm
	if !filepath.is_abs(ppm) {
		cwd, err := os.get_working_directory(context.allocator)
		if err != nil do common.die("working directory: %v", err)
		abs = strings.concatenate({cwd, "/", ppm})
	}
	r := send(d, strings.concatenate({"shot ", abs}))
	if !strings.has_prefix(r, "ok") do return r
	w, h, c: i32
	px := stbi.load(strings.clone_to_cstring(ppm), &w, &h, &c, 3)
	if px == nil do common.die("%s: %s", ppm, stbi.failure_reason())
	defer stbi.image_free(px)
	ow, oh := i32(width), h * i32(width) / w
	dst := make([]u8, int(ow * oh * 3))
	stbi.resize_uint8(px, w, h, 0, raw_data(dst), ow, oh, 0, 3)
	if stbi.write_png(strings.clone_to_cstring(path), ow, oh, 3, raw_data(dst), ow * 3) == 0 do common.die("%s: write failed", path)
	os.remove(ppm)
	return r
}

main :: proc() {
	if len(os.args) < 3 do common.die(USAGE)
	d := os.args[1]
	for cmd in os.args[2:] {
		w := common.py_fields(cmd)
		r: string
		if len(w) > 0 && w[0] == "png" && len(w) > 1 {
			width := 960
			if len(w) > 2 {
				ok: bool
				if width, ok = strconv.parse_int(w[2], 10); !ok || width <= 0 do common.die("bad width %s", w[2])
			}
			r = png(d, w[1], width)
		} else do r = send(d, cmd)
		fmt.printf("%s -> %s\n", cmd, r)
		if strings.has_prefix(r, "err") do os.exit(1)
	}
}
