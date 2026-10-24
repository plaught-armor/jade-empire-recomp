# x86 → Odin static recompiler

Generator: `tools/x86rec.py <JadeEmpire.exe> <re/ghidra_funcs.txt> port/src/rec`
(needs pefile and capstone). Output: `port/src/rec/mNN/code.odin`, about 40 000
instructions per package; each package is a separate LLVM module under
`-use-separate-modules`. Runtime: `port/src/x86/`. Regenerate after every
generator change. Generated code is never edited by hand.

Iteration time (16 threads):

- The whole-program analyses (flag and GPR liveness, transparency), about
  three quarters of a run, depend only on the image, the function list and
  the generator source. Their results are cached in
  `port/build/x86rec_analysis.pickle`, keyed by a hash of those three files,
  so a regen for a new native or hook takes about 50 s instead of 230 s.
  Any edit to `tools/x86rec.py` (PATCHES included) reruns them. The cached
  and fresh outputs are byte-identical.
- `port/build.sh` takes about 35 s. LLVM codegen is all of it. Before
  `COLD_LABELS` it took 143 s: two cold functions with over 5000 labels each
  (§1) held one thread for about 90 s while the other modules had finished.
- Smaller packages do not help: calls across packages go through
  `x86.call_ext`, so splitting adds dispatch at run time, and with the long
  functions unoptimized, 81 packages built no faster than 22.
- `port/build_windows.sh` cross-builds `port/build/win/jade.exe` on Linux in
  about 31 s, with the SDL3 and FFmpeg DLLs and their licences beside it
  (first run downloads them). It links with lld-link against the Windows SDK
  and CRT that `xwin splat` puts in `$XWIN` (default
  `~/.local/share/xwin`), naming the library paths itself, since Odin's
  `-windows-sdk-root` expects the MSVC folder layout. Odin's own
  `vendor/sdl3` holds git-lfs pointers instead of `SDL3.lib` and `SDL3.dll`,
  so the script builds a shadow `ODIN_ROOT` (`build/odin-win`) whose
  `vendor/sdl3` copy holds the real files. `movie.c` is compiled `/MT`: Odin
  links the static CRT, and a `/MD` object brings duplicate CRT symbols.
  With a very large open-file limit (1048576, the default in some shells)
  the Windows-target `odin build` stalls on one thread and grows past 35 GB,
  so the script sets `ulimit -n 1024`. `./build_windows.sh -debug` also
  writes `jade.pdb` (about 110 MB) for the fault backtrace; lld-link warns
  (LNK4099) that the CRT's own PDBs are missing. The exe runs under Wine 11
  (headless gamescope), including online co-op between two Wine peers.
  `build/jade-win.zip` holds what a Windows PC needs: jade.exe, the DLLs,
  their licences and `play.bat` (from `port/play.bat`, converted to CRLF),
  which runs the game from the Steam folder with the unpacked
  `JadeEmpire.exe` beside it and logs to `logs\play-<timestamp>.log`. The
  zip never holds jade.pdb, game files or the unpacked exe.

## §1 Function model

- Function regions come from the Ghidra function list. Entries are the region
  start, plus every in-region target reached from outside: call targets, tail-jump
  targets, data pointers into .text and switch-table entries.
- A function is one Odin proc over its basic-block labels, emitted structured
  (`structure`): blocks in address order, a jump back to label q is `continue
  L_q` in a labeled `for` loop opened at q, and a jump forward to q is `break
  B_q` out of a labeled block that closes just before q. Loops and blocks nest
  by widening (a block opens earlier, a loop closes later) until every pair
  nests. A function with more than one entry gets an entry `switch` that jumps
  to its block. Unreachable blocks are dropped (Odin rejects code after a
  `return`). A jump table is a `switch pc` over its targets.
- Why structured: the older form, `for { switch pc { case <label>: ... } }`,
  is lowered by LLVM to a compare tree over the sparse guest addresses, and
  every `pc = K; continue` walked that tree again, since jump threading does
  not thread through the loop header. Structured output was 6.7% fewer
  instructions per frame and 6% fewer cycles, about +4.7% fps.
- Fallback to the switch form (`dispatch`), where fallthrough between blocks
  is an Odin `fallthrough`: an irreducible region (a forward jump into a loop),
  nesting deeper than `MAX_NEST` (128; the Odin compiler overflows its stack
  near ten thousand levels, as in 0x6c1790), or a block that is not reachable
  from where it lands. About 650 of 7500 functions fall back; the generator
  prints the counts.
- A function with more than `COLD_LABELS` (2000) labels is emitted with
  `@(optimization_mode="none")`. LLVM's dominator-tree and branch-probability
  passes are superlinear in one function's blocks. The two such functions are
  cold: the C++ EH unwind funclets at the end of .text, which the Ghidra list
  leaves as one region from 0x6c1790 (10 210 labels, entries only through
  data pointers), and the HRESULT name lookup 0x69d936 (5127 labels, a
  compare tree).
- `call` pushes the guest return address, then makes a host call through
  `x86.call`. `ret n` pops the return address plus n bytes, then makes a host
  return. The guest return address is not checked; the code never alters it.
- A jump out of the region is a tail call: `x86.call(target)`, then a host return.
- Instructions in `FRAME_COUNTS` have their immediate, a frame count written
  for 30 fps, emitted as `x86.frames(imm)` (`docs/rendering.md` §5).
- An unknown label (the `case:` arm) dispatches through `x86.call(pc)` and returns.
- Switch tables: `jmp [idx*4+table]` reads entries upward from the table. When
  the previous instruction is `neg idx` on the same register, the index is
  non-positive and entries are read downward from slot 0 instead. The CRT
  memmove 0x6b3d80 does `neg ecx; jmp [ecx*4+0x6b4018]` with index -7..0.
- Overlapping instruction streams: an entry can fall inside an instruction
  that is also reached by fallthrough, and then decodes as a different stream.
  In this binary the known cases are false data pointers: 0x464c44 is a 6-byte
  `cmp`, and the "entry" 0x464c45 is the string "ELF\0" at 0x715528 read as a
  pointer. False pointers that decode cleanly are kept, since a missing real
  entry is fatal at runtime while a false one is never reached.
  `split_overlaps` labels both the true successor and the out-of-order pc at
  every break in address order. The emitter writes `fallthrough` only when the
  previous instruction's successor is the next label, else an explicit
  `pc = succ; continue`; an unlabeled break is an assertion failure.

## §2 CPU state and dispatch

- `x86.cpu` holds the guest registers, flags as separate bools, the x87 stack, the
  XMM registers and MXCSR. Guest memory is one 4 GiB reservation: a guest address
  is an offset. The low 64 KiB stay inaccessible so null dereferences fault.
- Each register and flag in `Cpu` is followed by an unused slot of its size.
  A recompiled body reloads its registers from `cpu` after every call, and
  LLVM's SLP vectorizer paired adjacent reloads (eax with ecx, sf with of)
  into one 64-bit or 16-bit load. The callee had stored them as two narrow
  stores, which Zen 4 cannot forward to one wide load, so every such reload
  stalled until the stores retired. With the gaps, no two registers share a
  load: `r_004d82b0`, the worst case, fell from 2.97% to 1.54% of samples
  (v65). Odin has no switch to turn off the SLP vectorizer.
- `dispatch` is a flat table over .text indexed by `addr - TEXT_LO`. A call to a
  registered entry is one load plus an indirect call.
- Imports resolve to `HLE_BASE + 4*k` (0xff000000+). `call` routes them to the
  `hle[k]` Odin implementation. An unimplemented import, or an unregistered code
  address, is fatal: a wrong guess at behavior is worse than a stop.
- Host faults (SIGSEGV, SIGBUS, SIGFPE, SIGILL) are reported by `x86/fault.odin`
  on a 1 MiB alternate stack: fault address (and guest address when inside
  guest memory), host pc, guest registers as last stored to `cpu`, and a host
  backtrace of `jade(+offset)` frames. `addr2line -f -i -e port/jade <offset>`
  names the frame; recompiled procs are `r_<guest entry>`. The handler then
  restores the default action, so the fault repeats and still dumps core.
  That is `fault_linux.odin`; on Windows `fault_windows.odin` installs an
  unhandled-exception filter that prints the exception code with the same
  addresses and registers, and a backtrace of raw addresses beside the exe's
  load base, then lets Windows end the process. Guest memory is reserved by
  `mem_linux.odin` (mmap) or `mem_windows.odin` (VirtualAlloc) at the same
  base.
- Helper inlining. Under `-use-separate-modules` Odin emits one LLVM module per
  source file of a large package (`-keep-temp-files` shows `t-m-code.ll`), and
  `#force_inline` does not cross modules. Every `x86.rd32`, `set_st`, `fpush`
  and similar call from generated code was an out-of-line call, about 43% of
  the profile. The generator (`inline_helpers`) therefore appends to each
  `code.odin` a copy of every contextless `#force_inline` proc in
  `port/src/x86/*.odin`, with x86 names qualified, and rewrites calls to use
  the local copy. The x86 sources stay the single definition; regenerate after
  changing a helper. Check: `objdump -d port/jade` shows no call to an
  `x86::` helper from an `mNN::` proc.
- Calls across packages. A generated call or indirect call is
  `x86.call_ext(addr)`, a `#force_inline` copy of `call`'s .text path: the
  range check and dispatch-table load inline, and for a constant address the
  range check folds. Imports, unregistered addresses and probes (`probe_n >
  0`, §7) go through `x86.call`. Indirect calls this way were about 1.5% of
  the frame.
- HLE calls inline (v52). Imports and the methods of HLE COM objects (D3D,
  DirectSound, DirectInput vtables) are HLE slots, so every one went out of
  line through `x86.call`, sharing its single indirect jump: about 2% of a
  combat frame in `x86::call`. `call_ext` now also handles an HLE slot
  inline (the `hle[k]` load, the crash log's ring record, the call), so each
  call site predicts its own target. HLE tracing, unset slots and probes
  still go through `x86.call`. Combat check: 33.5 M native calls, no mismatches.
  Against v51 over four rounds on a loaded machine, instructions 12.56-12.65
  to 12.24-12.40 M per frame (-2%), cycles lower in three rounds of four.
  The binary grows 120 to 125 MB.
- x87 rounding. `round_cw`, the `fist*` stores and `fldcw` are native
  `#force_inline` procs: round to nearest-even, down, up or toward zero per
  the control word, with x87's integer-indefinite value on overflow and the
  sign of zero as x87 produces it.
- Bounds checks. Odin's index check is an out-of-line call to
  `runtime::bounds_check_error` (it compares inside), so each x87 register
  access through `st`, `set_st`, `set_st_raw` and `fpush` paid one: about 4%
  of a combat frame. Those indexes are masked to 0..7 over `[8]f64`, so the
  helpers use `#no_bounds_check`. Check: `objdump -d port/jade` shows no
  `bounds_check_error` call after an `and $0x7` with count 8.
- GL debug wrapper. `-debug` sets vendor:OpenGL's `GL_DEBUG`, which wraps
  every GL call with a `glGetError` loop; under Mesa's threaded GL each one
  waits for the driver thread. `build.sh` passes `-define:GL_DEBUG=false`
  (`JE_GL_DEBUG=true ./build.sh` restores it). Combat at a 144 fps cap went
  from 80-90 fps to 104-112.
- Register promotion (`promote_regs` in `tools/x86rec.py`). The guest
  registers and flags live in `x86.cpu`, a global, and LLVM must assume any
  guest store aliases it, so `c.esp` (677k references) was reloaded after every
  push and stack store. Each function now keeps the registers it names in
  locals `g_<reg>`, loaded at entry. A sync line is a `return` or a call of
  anything outside `PURE_HELPERS` (generated procs, `x86.call`, `call_ext`,
  string ops, `cpuid`, flag helpers): it keeps its `c.<reg>` references, the
  locals the function writes are stored before it, and every local reloads
  after it unless it returns. The generator asserts that the inline helpers
  listed as pure name no promoted register. Diagnostics that read `x86.cpu`
  outside a sync (the fault report, the `JE_WATCH` write watch) see the
  registers as of the last sync.
- Fixed guest base. Guest memory is mapped at `MEM_BASE` (0x100_0000_0000,
  `FIXED_NOREPLACE`), and the accessors index `guest()`, a constant, instead
  of the `mem` pointer global, which LLVM reloaded after every store for the
  same aliasing reason.
- Rep string ops. `rep movs` and `rep stos` with DF clear, no wrap past 4 GiB
  and no write watch run as one `mem_copy` or a fill loop. A `movs` whose
  destination lies inside the source above its start keeps the element loop:
  element by element it repeats the first elements, which memmove does not.
  The element loop works on locals and writes the registers back once.
- Measured on the idle benchmark (v9 to v12): 9.10 to 8.33 M cycles and 21.7
  to 19.7 M instructions per frame; promotion 0.22 M cycles, the fixed base
  0.28, rep ops 0.27.
- Dirty tracking (`promote_regs`). A sync stores only locals written since
  the last sync on the straight-line path. At a point control can reach from
  elsewhere (a loop head, a `case`, the close of a labeled or `if` block)
  every written local counts as dirty. A local the sync neither stores nor
  reloads stays dirty.
- Liveness-narrowed syncs (`gpr_liveness`, `Sync`). A direct call stores only
  the registers the callee reads at entry and reloads only those it, or
  anything it calls, may write (`gpr_mod`). A return stores only those a
  caller or tail-jumper reads after it. The model is §3's, applied to the
  eight GPRs. `gpr_effect` adds the accesses capstone does not report
  (`cmpxchg`, `xlatb`, `enter`), treats `bsf`, `bsr` and `cmpxchg` writes as
  uses, and does not count `xor`/`sub`/`sbb r, r`, `and r, 0` or `or r, -1`
  as a read of r.
- Taken entries (`taken_entries`). Code the analysis does not see may reach
  some entries: the program entry, any entry whose address appears as an
  aligned or unaligned 32-bit word in the image (function pointers, vtables,
  immediates), and any entry no direct transfer reaches. Their returns store
  every register.
- Saved-register transparency (`transparency`, section "saved registers").
  An entry is transparent in a register when it leaves it with its entry
  value and reads that value only to save and restore it. A direct call to
  it then neither stores nor reloads that register. The callee's returns
  store the registers it is transparent in and writes, so `x86.cpu` holds
  the caller's values after the return, as on the machine. This matters for
  a caller that never names the register.
  - Per entry, an abstract interpretation tracks the esp offset from entry,
    each register as `(value, taint)` and stack slots at known offsets. A
    value is an entry register (`E`), an esp-relative pointer (`S`) or
    unknown. The taint is the set of entry values a word may hold. Copies by
    `push`, `pop`, `mov r, r` and moves between registers and slots keep the
    taint. Any other read of a tainted word is a leak and fails the bit.
  - A call leaks the taint of the registers the callee reads or changes
    without being transparent in them, then kills the registers it changes.
    The esp after it comes from the callee's consistent `ret imm`, or else
    from backward offsets measured from the function's own returns.
  - A value is also a constant (`C`, from `mov r, imm` and `push imm`), so
    `sub esp, eax` with eax known keeps the offset (`__chkstk` and
    `__SEH_prolog` callers), or a load from a constant address (`M`).
  - A callee whose body is straight-line code ending in `ret` (at most
    `INLINE_MAX` instructions, one entry) is interpreted in place at the
    call. Its `ret` must pop the return address the call pushed.
  - Entries from which no path returns (`no_return`: `_exit`, `abort`,
    `terminate`, CRT `unexpected`) end the path at a call to them and do
    not count as exits. The test is per entry, since one function can hold
    both a no-return entry and funclet entries that return.
  - An indirect call through an IAT slot (`call [slot]`, or `call r` with r
    an `M` load of the slot) reaches the host: it reads and changes only
    eax, ecx and edx, and pops what its HLE proc pops. `host_pops` reads
    that from the procs in `port/src/win32`: a proc counts when every
    `ret(n, v)` in it has the same literal n (180 of 199 imports).
    `JE_HLE_TRACE` prints each call's pop count; a combat run exercised 125
    of the 180 and all matched. The 10 decorated `@N` imports also match.
  - A `ret` passes when the offset is 0 and each register holds its entry
    value. A tail jump passes when the target is also transparent in the
    register.
  - An entry value still held at a `ret` or tail jump by another register,
    or by a stack word at offset 0 or above, reaches the caller and fails
    the bit (`escaped`). Without this, `mov eax, ecx; ret` (0x43f350) was
    transparent in ecx, so a caller that set ecx just before the call never
    stored it and the callee returned a stale ecx. That crashed every manual
    save, in the GFF ResRef writer 0x652760 (fixed v96; a few dozen call
    sites gained stores).
  - Greatest fixpoint: every entry starts transparent in all registers but
    esp. A worklist re-runs the users of an entry whose set shrinks, and a set
    never grows back.
  - Indirect calls and unknown indirect jumps reach a taken entry or the
    host. Their read and change sets are the union over all taken entries,
    plus eax, ecx and edx for host code. One non-transparent taken entry
    puts a register in that union, so in practice indirect transfers stay
    opaque (the union is every register but esp).
  - Assumptions: a store through an unknown pointer never hits a saved
    slot; a callee does not read an entry value passed to it as a stack
    argument; exceptions are fatal, so no handler sees a half-restored
    frame. Host code changes only eax, ecx and edx, and `control.odin`
    restores the whole cpu after it runs. HLE procs that call guest code
    (window procs, APCs, vorbis callbacks) go through `guest_enter`, which
    restores ebx, ebp, esi and edi as a Win32 API does across its callbacks.
    The IAT keeps its load-time values: no instruction stores to it at a
    constant address, and a store through a pointer is assumed to miss it.
  - Coverage for ebx: 3,806 entries were transparent at v16 and 3,991 at
    v17 (ebp 4,826, esi 16,068, edi 6,330). With every indirect call
    assumed ABI-conformant the ceiling is 4,907. At v16: The largest remaining
    groups of blocked entries are callers of `__SEH_prolog` (0x6b601c;
    its esp delta is variable, about 2,300 entries), partial writes such as
    `mov bl, [..]` after `push ebx` (about 700), and returns whose esp offset
    was lost (about 500).
  - At v17 the largest root is `__sbh_free_block` (0x6baaa1, about 7,000
    ebx entries through `free`): its call to memmove (0x6b3d80) has no
    known pop, because two of memmove's tables decode badly. `jmp
    [ecx*4 + 0x6b3edc]` indexes slots -4..-1 (after `sub ecx, 4; jb`) and
    `switch_table` scans only upward. The `neg ecx` table at 0x6b4018 reads
    one slot too far down and takes 0x498d00 as a tail-jump target.
  - The analysis adds about 145 s to the generator run (75 s to 220 s).
- Traced HLE calls (`hle_call_traced` in `x86/cpu.odin`). Under
  `JE_HLE_TRACE` the formatting needs a large stack frame. In `call` itself
  that frame was paid on every call, so the traced path is a separate
  `@(cold)` proc.
- Measured on the idle benchmark (v12 to v16): 8.33 to 7.20 M cycles and
  19.7 to 16.6 M instructions per frame. Sync stores fell from about 482k to
  439k lines and reloads from 731k to 645k. Of that, the transparency pass
  alone took v15's 8.14 M cycles to 7.20. Real frame rate at `JE_FPS=1000`
  under gamescope (`-r` set above the cap, or the frame count is capped
  instead) is 624 fps, against 357 at the start of the headroom work and
  538 at v12.
- v17 (constants, inlining, no-return entries, host IAT calls): stores fell
  from 439k to 435k lines and reloads from 645k to 635k. The idle benchmark
  did not move: 7.09 M cycles and 16.67 M instructions per frame, against
  7.07 and 16.52 for v16 in the same session. The newly transparent entries
  are cold. Rounding every x87 result to single precision (`round_pc`)
  costs at most about 1% of the frame: a build without it measured 7.02.
- v19, tried and reverted: a native register ABI. Each recompiled entry
  took eax, ecx, edx and esp as host arguments and returned them as a
  16-byte struct (rax:rdx); other registers stayed in `cpu`. Behavior
  matched v18 (identical idle-benchmark logs, same screenshot, clean combat
  run), but the idle benchmark measured 7.70 M cycles and 19.6 M
  instructions per frame against 7.13 and 16.5 for v18, run alternately. The
  four registers are live across every helper call, `movs`/`stos`, x87
  flush and HLE call, and each of those stores and reloads them through
  `cpu`; every call site also packs and unpacks the struct. The
  `x86::call_regs` samples in a profile are skid: LBR shows HLE procs
  (`Dev_SetRenderState`, `const_io`) returning straight into it, because
  `call` tail-jumps to them. A retry would need the helpers and HLE entry to
  take registers too, so the sync traffic goes away rather than moves.

## §3 Flag liveness

A flag is computed only when a later instruction can read it. Most arithmetic
then needs no flag code.

- Per function: backward liveness over the CFG. `flag_effect` gives (use, def)
  per instruction.
- Across functions: compiled MSVC code never passes flags across call, ret or
  tail jump, but the hand-written CRT math helpers do. Example: acos path
  0x6b34d0 calls 0x6b9238, which does `cmp eax, 0x7ff00000; ret`. The next
  callee, 0x6b34ed, branches on ZF at its entry. With function-local liveness the
  `cmp` emitted no ZF write, the stale ZF took the inf/NaN path, and acos returned
  NaN for every input. That NaN reached the skinning bone constants, and skinned
  meshes vanished.
- Model (`flag_liveness`): `entry_live[e]` = flags read at entry e;
  `ret_live[f]` = flags any caller or tail-jumper reads after f returns.
  - `call T`: uses `entry_live[T]`, defines all flags (the callee's own liveness
    decides what it writes). Its live-out feeds `ret_live[owner(T)]`.
  - `ret`: live-out = `ret_live[f]`.
  - Tail jump, fallthrough out of the region, or an out-of-region switch entry to
    T: live-out includes `entry_live[T]`. `ret_live[f]` flows into
    `ret_live[owner(T)]`.
  - Indirect calls and jumps pass no flags. `check_indirect_calls` fails the
    generator if code after any indirect call reads a flag before writing it.
    The other direction, an indirect target that reads flags at entry, cannot
    be checked directly. Every address-taken entry that does is a false pointer:
    ASCII text (0x00444557 is "WED\0") or the non-code table of rising values
    at 0x6e1024.
- The solver is `reg_liveness`, shared with the GPR liveness of §2. The flag
  analysis passes only `flag_effect`. The GPR one adds the registers a callee
  keeps (`keeps`), those an indirect transfer may read (`unknown`), and the
  transparent registers hidden from callers (`hidden`).
- Shifts and rotates by `cl` may have a count of 0, which leaves the flags
  unchanged. Their flags are a may-def: neither a use nor a kill, so live-in
  equals live-out. The lifted code writes flags only under `if n != 0`.
  Modeling them as reads of every flag made all flags live at the return of
  four functions and before one indirect call.
- Fixpoint: a worklist over functions, revisited when a neighbour's entry or ret
  set grows. Sets only grow, so it terminates. The iteration cap raises an error
  rather than emitting under-approximated code. The current binary has 2
  functions with flags live at ret and 26 entries with flags live at entry.

## §4 x87

- Registers are f64, not 80-bit. Rounding control applies to integer stores and
  `frndint`.
- Precision control (CW bits 8-9) matters. D3D9 `CreateDevice` without
  `D3DCREATE_FPU_PRESERVE` sets single precision: CW &= ~0xf3f, |= 0x3f, as Wine
  does. The game relies on it. Slerp 0x5c1180 compares an x87 dot product
  against 1.0 (`fcomp` with qword 0x6e3568) and then reuses the value's f32
  store. In double the dot product of equal quaternions is 0.99999998 < 1, so
  slerp runs with sin θ = 0 and computes 0·inf = NaN; in single it is 1.0 and
  takes the lerp path.
- So `set_st` (every arithmetic result) rounds the significand to 24 bits when
  PC = 00. The exponent keeps its range: on hardware precision control narrows
  only the significand, so a single-precision result can exceed FLT_MAX. The
  inverse square root at 0x5c0320 depends on it. Its first guess for x = 0 is
  2^511; converting through f32 made that inf and the result 0·inf = NaN, so the
  conversation speaker search at 0x44e310 (nearest object by `fcom` against
  FLT_MAX) rejected a speaker standing at distance 0 and conversations closed
  at once. Double and
  extended precision both run as f64. Loads, `fst/fstp st(i)`, `fxch` and
  `frstor` use `set_st_raw`: register moves never round, as on hardware.
- Run cache (`class X87` in `tools/x86rec.py`). `c.fpu` is a global and every
  guest store may alias it as far as LLVM knows, so a direct `st(i)` or
  `set_st` reloaded top, the control word and the register each time. Within a
  run of x87 instructions in one block, top moves by an amount known at
  generation time, so the run keeps each register it touches in a proc local
  `x87_j`, standing for physical register `(x87t + j) & 7` with `x87t` = top at
  the run's start, and `x87s` holds the precision-control test once. Pushes and
  pops only shift the generator's offset. `flush` writes back dirty registers
  through `st_phys`/`set_st_phys` (unchecked index), the changed tag bits
  rotated into place by `rot8`, and the new top. Flush points: every label,
  control instruction, call, unsupported instruction, the function's end, and
  any instruction that reads the whole x87 state (`fxam`, `fprem`,
  `fninit`, `fnsave`, `frstor`). `fldcw` drops the cached precision test.
  Arithmetic results still round through `round_pc`, so results match the
  direct form bit for bit. Measured on the idle benchmark: 10.27 to 9.10 M
  cycles and 26.8 to 21.7 M instructions per frame, with idle screenshots
  within same-build noise.
- Carrying the run across branches was tried and reverted (v20). `fstsw`
  computed its value from `x87t` plus the generator's offset without a flush,
  and a conditional jump wrote the cache back only on the taken edge, keeping it
  on fall-through. Run starts fell only from 9637 to 9592, because the
  fall-through after a compare branch is usually a join label, which flushes
  anyway; cycles per frame stayed within noise. A real gain needs the cache
  state carried across labels, which needs every predecessor to agree on it.
  The generator is kept outside the tree as `x86rec.py.v20`.
- Lighter write-back (v51). A flush no longer writes the value of a register
  the run leaves empty: the guest cannot read an empty register without
  loading it again, and check mode compares only valid registers. A
  `fld; fcomp; fnstsw; test; jcc` loop iteration now writes back only the tag
  bits. `fstsw` also stopped being a flush point: it reads the status word,
  which compares write directly, and takes top as `x87t` plus the run's
  offset. The two corner cases that see an empty register's contents, `fxam`'s
  C1 sign bit and `fnsave`'s register image, are not used on empty registers
  by the game. Combat check: 33.5 M calls, no mismatches. Against v50:
  instructions 12.58-12.68 to 12.39-12.48 M per frame (-1.5%), cycles
  5.84-5.91 to 5.84-5.87 M.

## §5 CPUID

`cpuid` reports a Pentium-class part with FPU only: no MMX, SSE or SSE2. The CRT
and the engine pick their x87 paths, which the recompiler covers most fully.
Code that uses SSE unconditionally still runs through `x86/sse.odin`.

The generator emits `x86.unsupported(pc)` (fatal when reached) for 11
instructions. Ten are in the CRT's SSE2 math paths (0x6b9843..0x6ba0f8:
cvtdq2pd, cvtsd2si, unpcklpd, pmaxsw, pmovmskb), which run only when CPUID
reports SSE2, so they are unreachable. The eleventh, `div byte ptr
[ebx + edx - 0x75]` at 0x657675, is the second byte of `test esi, esi` at
0x657674, decoded as an overlapping stream (§1) from a false entry; no real
control flow reaches it. Implement an
instruction only when a reachable site appears.

## §6 Debug environment

| Variable | Effect |
|---|---|
| `JE_HLE_TRACE=1` | Log every HLE call: return address and the first seven stack arguments. |
| `JE_TRACE_FRAME=N` | HLE trace only during presented frame N; overrides `JE_HLE_TRACE` per frame. |
| `JE_FRAME_DUMP=<dir>` | Write the back buffer as `frame_NNNNN.ppm` every 30th presented frame. |
| `JE_SHADER_DUMP=<dir>` | Write each generated GLSL program as `{vs,ps}NNN_<key>.glsl`. |
| `JE_INPUT_SCRIPT=f:Action,...` | Scripted input, up to 1024 events. `Key`: tap SDL scancode name, held 4 frames; `Key~N` holds it N frames. `Move@x/y`: move pointer to guest client pixel. `Click@x/y`: move, then left-button tap. `Pad.<name>`: SDL gamepad button ("a", "start", "dpdown") or axis ("leftx", "lefttrigger") at full deflection, on a virtual gamepad attached at startup; `~N` holds. Example: `150:Return,420:Click@296/408`. |
| `JE_LOCKSTEP=n` | Lockstep without a network: virtual clock, inputs sampled once per frame, state hash logged every n frames (docs/hle.md §11). |
| `JE_NET_HOST=port` | Host an online game on UDP port, as player 1 (docs/hle.md §11). |
| `JE_NET_JOIN=host:port` | Join an online game as player 2, driving the henchman. |
| `JE_NET_DELAY=n` | Input delay in frames for the host, 0..30; unset, the host picks it from round trips timed in the handshake. |
| `JE_MARK_DIR=<dir>` | F12 writes the back buffer as `mark_NN_frame_NNNNN.ppm` there. Without it F12 only logs the mark. |
| `JE_STICK_LOG=1` | Log the left stick (SDL raw, after the deadzone, the game's pad), the move length n, and the player's wanted facing, facing and movement heading relative to the camera, every 3rd frame while moving. Format in `port/src/native/stick_log.odin`. |
| `JE_FULLSCREEN=1` | Start in borderless fullscreen. |
| `JE_INTRO=1` | Play the boot logo and movie sequence; the default overrides `[Render] NoLogos=1`, which skips it (0x551240). `NoMovies` is never forced: it stops every Bink movie, in-game ones included (0x6801b0), and a scripted `PlayMovieBlocking` then never returns control. |
| `JE_SCALE=N` | Render-target scale; 0 or unset = auto. See `docs/rendering.md` §1. |
| `JE_FPS=N` | Lift the game's 30 fps cap (`ClampFPS`) and cap at N fps instead; 0 = vsync only. Unset: the game's cap. See `docs/rendering.md` §5. |
| `JE_NATIVE=0\|check` | `0`: run the recompiled bodies of the §8 native replacements. `check`: run both on every call from the same state, report the first 20 differences in registers, x87 state or outputs, and keep the guest's result. |
| `JE_MENU_FPS=N` | With `JE_FPS`: cap at N fps while a menu is up (default 60; 0 = menus at `JE_FPS`). See `docs/rendering.md` §5. |
| `JE_ANISO=N` | Minimum anisotropy on linear mipmapped samplers, default 16; 1 = off. See `docs/rendering.md` §2. |

The port's settings (§11) also read `JE_<key>` from the environment, which
wins over the ini: `JE_FPS`, `JE_MENU_FPS`, `JE_SCALE`, `JE_SMAA`, `JE_SOFT`, `JE_BLOOM`, `JE_SHADOW`,
`JE_ANISO`, `JE_FULLSCREEN`, `JE_INTRO`, `JE_BLEND`, `JE_BLEND_MS`, `JE_TURN`,
`JE_STICK_DZ`, `JE_FLICK`, `JE_CAMERA` and `JE_AIM`. `JE_STICK=0` sets the stick deadzone to Original.

Play sessions: `port/play.sh` builds, then runs the game with stdout and
stderr in `port/logs/play-<timestamp>.log` and `JE_MARK_DIR` set to
`port/logs/play-<timestamp>/`, and `JE_STICK_LOG=1`. Host keys, not passed to the game: F12 logs
`mark N at frame F`, so a report like "mark 3 looked wrong" points at a frame;
Alt+Enter toggles borderless fullscreen. The window is resizable and the image
is letterboxed at the guest aspect; pointer input maps through the same
rectangle. Every 10 s the log gets `status: frame F, X fps`.

Crash context (`x86/crash_log.odin`): `fatal` and the fault handler print the
presented frame, guest return addresses found on the guest stack, and the
last 64 HLE calls with their return addresses. The stack scan keeps a dword
when it points into .text right after a call instruction (E8, or FF /2), so
stale values from dead frames can appear; read it as candidates, innermost
first.

Test runs are headless and muted: `SDL_AUDIO_DRIVER=dummy gamescope --backend
headless -W 1280 -H 720 -- ./jade <game dir> <JadeEmpire.exe>`. The Windows
build under Wine ignores `SDL_AUDIO_DRIVER` and plays through Wine's audio
drivers, so a muted Wine run also disables them:
`WINEDLLOVERRIDES="winepulse.drv=d;winealsa.drv=d;wineoss.drv=d;winejack.drv=d"`.
The port then finds no device and falls back to the dummy driver.

## §7 Live control channel

`JE_CTL=<dir>` (`win32/control.odin`) makes the empty file `<dir>/in`, reads the
lines appended to it once per presented frame, and answers each line `<id> <command> args...` with `<id> ok
[data]` or `<id> err <reason>` in `<dir>/out`. `tools/jectl.py` is the command
line client and lists the syntax; `tools/jeplay.py` drives play with it. Input
commands queue real SDL events through the `JE_INPUT_SCRIPT` path. `wait N`
holds every later command until N frames have been presented. `pad NAME N`
and `axis NAME V` drive the virtual gamepad, `pad2` and `axis2` a second one,
player 2 (both are attached when `JE_CTL` is set; `pad2 off` unplugs the
second and `pad2 on` plugs it back). Names are SDL's: buttons
"a", "b", "x", "y", "dpup" ..., axes "leftx", "lefty", "lefttrigger",
"righttrigger" ("rt" is not a name).

- `probe ADDR [ARG0]` (`x86/probe.odin`): each call to the guest function logs,
  on return, the return address, ecx, the first four stack arguments, eax and
  st(0); strings an argument points at are shown. At most 8 probes and 256
  lines each. While any probe is set every call goes through `x86.call`,
  since `call_ext` skips the probe check only when `probe_n` is 0.
- `watch ADDR N`: each guest store into the range logs the value and a host
  backtrace. The check sits in every store, so it is built in only with
  `-define:JE_WATCH=true`; otherwise `watch` answers `err watch needs a build
  with -define:JE_WATCH=true`.

## §8 Native replacements

- `port/src/native` holds hand-written Odin for hot guest functions. A proc
  named `Name_xxxxxxxx` replaces the function at `0xxxxxxxxx`: the generator
  finds it by that name in `native` beside its output directory (as it finds
  `x86`; link both when generating elsewhere), still emits and registers the
  recompiled body, and
  makes every call to that address, from any package, call the native proc
  directly.
  `native.register`, run last in `rec.register`, moves each recompiled body
  out of the dispatch table into the native package (fallback and check
  reference) and puts the native proc in its place.
- The contract is the recompiled body's architectural effects, bit for bit,
  including what it leaves out: a register write the GPR liveness of §2 drops
  as dead is not made by the native proc either. The effects are:
  every guest memory store above the caller's stack pointer after the return,
  the GPRs, and the x87 top, tag, status and control words with the contents
  of non-empty registers. Stores below that stack pointer (the guest's own
  temporaries) are dead and skipped. Floating-point steps run in the guest's
  instruction order as f32 SSE operations. Where every operand is a dword
  load or an earlier single-precision result, that gives the bits the
  recompiled body's f64-then-`round_pc` gives (53 >= 2 * 24 + 2), as long as
  every value stays a normal f32; the proc clears the MXCSR exception flags
  first and treats invalid, denormal, overflow or underflow afterwards, or a
  non-finite output, as leaving that range. Outside that range, and outside
  the state the f32 path was written for (double precision control, a
  non-empty x87 stack, non-default MXCSR rounding, flush-to-zero or
  denormals-are-zero), the proc runs its exact path instead. The f32 work
  sits in a `#force_no_inline` proc so no operation moves across the MXCSR
  accesses.
- `JE_NATIVE=check` (§6) runs native then guest from the same registers and
  outputs on every call and reports differences. A new replacement needs a
  clean check run through combat before it ships.
- Zero fallback (v49): no native hands a call back to the recompiled body.
  Each keeps its f32 path as the fast case and carries an exact path that
  replays the recompiled body itself: its f64 operations rounded with
  `round_pc` under the control word's precision, narrowed with an fstp/fld
  pair (`xspill`) wherever the guest spills, in the guest's operation order,
  reading guest memory through the pointers and indexes the guest uses and
  writing in its store order. The fast path writes nothing until its rule
  holds, so the exact path reruns from the entry state. Rules the exact
  paths follow:
  - CRT and helper calls the guest makes (operator new, `_CIacos`, the
    emitter's atlas cell steps) go through `call_guest` with the guest's
    arguments, return addresses and esp, not a native stand-in.
  - The x87 state left is the guest's: top, status word (the last compare's
    `fcom_bits`) and the tag bits its blocks mark empty (`rot8`). Registers
    the guest leaves empty need not be written.
  - A check's output regions include every frame and argument slot the
    guest writes, since the exact path writes them too.
  - Inputs the f32 path refuses (NaN, infinity, denormals, overflow, growing
    arrays, overlapping buffers, trees past the walk's limits) are the exact
    path's to handle. The only refusal left is `Skeleton_GatherWorldPose` for
    a tree deeper than 1 << 19 levels, past where the guest's 16 MB stack
    would end.
  The descriptions below give each native's fast path; where they say "falls
  back" the exact path now runs. Coverage was checked by forcing the exact
  paths (`f32_state` false) through a combat run: 33.5 M calls, no
  mismatches. Emitter passes 1 to 4 (5 passes when the emitter definition's
  byte 0xf6 is set, which the combat run never sets) were exercised by
  setting that byte under check mode: about 0.66 M calls per pass, no
  mismatches. v49 against x3 (before the exact paths): instructions
  12.61-12.78 to 13.07-13.22 M per frame (+3.5%); cycles too noisy under
  other load to separate.
- f32 paths restored (v50): writing the exact paths had left `BoxZGap`,
  `Quat_ToMatrix3`, `Aabb_Transform3x3`, `Segment_SphereTest` and
  `Segment_SphereHit` exact-only. Each again takes its f32 path under
  `f32_state` with finite inputs. Where the f32 path stores into guest memory
  before its rule is known to hold, `apart` (disjoint byte ranges) requires
  the outputs not to overlap the inputs, so a rejected f32 attempt leaves the
  inputs the exact path rereads. Combat checks, normal and forced exact:
  16.7 M and 33.5 M calls, no mismatches. Against v49 on a quiet machine:
  cycles 5.96-5.99 to 5.84-5.91 M per frame, instructions 12.91-12.99 to
  12.57-12.68 M (x3: 5.81-5.86 M, 12.50-12.53 M).
- Rejected: an f32 path for the emitter's `basis_rotated`. It checked clean
  (16.7 M and 33.5 M calls, no mismatches) and cut instructions 12.41-12.50
  to 12.25-12.30 M per frame, but cycles rose 5.88-5.91 to 6.03-6.12 M: the
  per-call MXCSR switch costs more than the rounding it removes.
- Frame analysis and register transparency still use the guest instructions;
  that holds because the native proc has the same effects.
- `Node_GetWorldPosOri` (0x59e170, about 5.7% of guest instructions): a node's
  world position and orientation, rotated and composed up its parent chain
  (`[node+0x34]`, links with flags `& 0x1001 == 0x1001` skipped), then through
  its owner (`[node+0x38]`). Quaternion w equal to ±1 skips the rotation.
  f64 with a per-operation `round_single` copy gave -1% cycles; the f32 rule
  gave 6.87 against 7.06 M cycles per frame for v18 (-2.7%, instructions -4%).
- `Quat_ToMatrix3` (0x40eba0): a unit quaternion's 3x3 matrix, 6.82 against
  6.89 M cycles per frame (-1%). Check run: 2M calls, no mismatches.
- `Aabb_Outcode` (0x5c1e70): a point's Cohen-Sutherland outcode against a
  box. Compares only, so the f32 rule is not needed: an f32 compare agrees
  with the guest's compare of the same values widened to f64. The proc also
  leaves what the guest leaves: eax holds the last `fnstsw` (low byte replaced
  by the outcode on the z < min branch), and the pushed-then-popped register
  holds p.z. Its profile share fell from 1.45% to 0.92%, instructions -0.4%.
  Check run: 8M calls across all three natives, no mismatches.
- `Segment_SphereTest` (0x5c2690): whether a segment passes within r1 + r2
  of a point (closest point a, b or a + t d). The f32 rule applies; inputs
  must also be finite, because SSE and the guest's f64 path may propagate a
  different NaN, and quiet-NaN arithmetic raises no MXCSR flag. edx keeps one
  dword of the guest's copy of the closest point; the recompiled body drops the
  ecx write. Profile share 1.84% to 0.53%, instructions -1% (v26, about 6.79 M
  cycles per frame). Check run clean.
- MXCSR access goes through `llvm.x86.sse.stmxcsr`/`ldmxcsr` declared in
  `native.odin`. Under `-use-separate-modules`, `core:simd/x86`'s
  `_mm_getcsr` stayed an out-of-line call, about 1% of the profile. No
  `enable_target_feature` on these helpers: SSE is baseline on x86-64, and the
  attribute forbids inlining into callers without it. With Aabb_Outcode
  (v25): about 6.85 against 7.03 M cycles per frame for v23 in alternating
  runs, instructions -1%.
- `x87.odin` keeps native's own copies of `st_phys`, `set_st_phys`, `rot8`,
  `round_pc`, `round_single`, `round_cw`, `fist64` and `fstsw`, so they inline
  into native procs under `-use-separate-modules` instead of staying calls
  into `x86`.
- `Emitter_InterpColorSize` (0x630fb0) and `Emitter_ParticleBasis`
  (0x631670): particle colour/size interpolation and the billboard basis.
  The f32 rule applies.
- `ftol2` (0x6b32a0): the CRT float to int64 conversion. Integer and x87
  work only, replayed under the control word; `ftol2_body` is shared with
  native callers, which inline the call.
- `ceil` (0x6ba8f0): the CRT ceil. The guest sets the control word through
  `_ctrlfp`, rounds with frndint and restores it; the native replays the
  rounding under the same word and leaves the registers, status bits and
  freed x87 registers the guest leaves. NaN, infinity and an inexact result
  with the precision exception unmasked fall back. It shares a recompiled
  body with `ValidateEH3RN` (0x6ba6c7), which put the pair near the top of
  the profile.
- `AnimTrack_FindKey` (0x5ffa00): binary search of a track's u16 key frames
  and the fraction within the interval. Its few x87 steps are replayed with
  `round_pc`, so no f32 rule; it calls `ftol2_body` in place of the guest
  call and leaves the registers that call leaves.
- `Segment_AabbClip` (0x5c2320): a segment clipped against a box. f32 rule.
- `Quat_Slerp` (0x5c1180): dot = ((a0 b0 + a1 b1) + a3 b3) + a2 b2, a negated
  when dot is negative. dot at or above 1.0 (the guest's lerp and normalize
  path) falls back. Otherwise the proc calls the guest CRT `_CIacos` with the
  x87 stack, esi, esp and return address as the guest sets them, saving the
  fpu and eax, ecx, edx, esi first so a range failure after the call can
  restore them and fall back. Then r = 1/sqrt(1 - dot^2) and the weights
  f32(sin(f64(f32((1 - t) theta)))) r and r f32(sin(f64(f32(theta t)))),
  `fsin` being exact on these f64 arguments; non-finite outputs fall back.
  Stores: the negated a, the first weight over its arg slot, the result.
  2.6% of the v33 profile; v34 6.69/6.74 against v33 6.72/6.72 M cycles per
  frame (neutral, kept for nativity).
- `Plane_BoxMaxDist` (0x5c0480): a plane's signed distance to the box corner
  farthest along its normal, pushed in st(0); eax keeps the z compare's
  `fnstsw`. f32 rule, inputs finite.
- `Quat_Unpack` (0x5b6f50): a 64-bit packed quaternion, x and y from 21-bit
  fields and z from 22, scaled to [-1, 1]; w = sqrt(1 - s), or 0 with the
  vector normalized when s > 1. With Plane_BoxMaxDist (v35): 6.76/6.72 against
  6.70/6.72 M cycles per frame, instructions -0.05 M. Check run (v35): 33.5 M
  calls, 0.61 M fallbacks, no mismatches.
- Tried and reverted: the profile's hotspot at rec function entry (an 8-byte
  `movsd` load of the adjacent eax/ecx fields) looked like a
  store-forwarding stall. Volatile entry loads, with or without volatile
  reloads, gave no gain (+0.5 M instructions per frame with reloads); the
  hotspot is sample skid.
- `Quat_Unpack32` (0x5b6e60): the 32-bit packing (11, 11 and 10 bits) of
  Quat_Unpack. `Quat_Normalize` (0x5c10d0): q / |q|, or the identity written
  through q's argument slots when |q| < 1e-9 (an f64 compare, done widened).
- `Math_SqrtNewton` (0x5c0320): sqrt of a double by a bit-trick 1/sqrt
  estimate and four Newton steps, each step f64 rounded by `round_pc` as the
  recompiled body runs it. Under single precision control `sqrt_newton` takes
  an f32 path when x is within 2^-100 to 2^100: every operand after the steps
  that read x or the estimate y0 is a single, and a double +, - or * of two
  singles rounded to single equals the f32 operation (53 >= 2 * 24 + 2, so the
  double rounding is innocuous); the steps that read x or y0 form their
  product in f64 and narrow it, which is what `round_single` does. The range
  keeps every value a normal single, so no MXCSR bracket is needed beyond the
  one the f64 path already relies on. Outside it, or under double precision,
  the f64 path runs. Segment_SphereHit fell from 4.8% to 1.3% of samples, the
  cave from about 620 to 631 fps (v65). Check run: 8.4 M calls, no mismatches.
- `Segment_SphereHit` (0x5c55c0): Segment_SphereTest against the sphere
  through the segment's two end points (centre their midpoint, radius half
  their distance, the distance by `sqrt_newton`). `Aabb_Transform3x3`
  (0x5c3eb0): a box's min and max corners under a 3x3 matrix, each term
  taking the min or max component by the sign of its matrix entry. Both f32
  rule. v37 and v38 against v36: instructions 14.90 to 14.70 M per frame;
  cycles 6.59/6.63 against 6.67 M at best, the runs noisy under other load.
  Check runs (v37, v38): 33.5 M calls, no mismatches.
- Natives may call guest code: `call_guest` (native.odin) makes the call as
  the recompiled body's `call_ext` does, after the proc has set the registers,
  stack arguments and return address the guest gives the callee.
  `Object_BoxZGap` (0x5aa990) is the first whole function with guest calls in
  its tail: the f32 work (relative quaternion, `quat_matrix`,
  `aabb_transform`, the offset rotated by a quaternion) runs first, so a
  range fallback happens before any call; then the tail's virtual calls run
  as the guest makes them. Under `JE_NATIVE=check` those calls run twice, once
  per body, so a check of such a proc is only exact when they are repeatable.
  v39 against v38: instructions 14.70-14.84 to 14.52-14.59 M per frame,
  cycles 6.63 against 6.66 M at best. Check run (v39): 16.7 M calls, no
  mismatches.
- Native spans replace a stretch of a function instead of the whole of it.
  A proc named `Name_xxxxxxxx_yyyyyyyy :: proc() -> bool` covers the guest
  code from label `0xxxxxxxxx` to label `0xyyyyyyyy` of one function; both
  must be block starts of that function (the generator asserts it). At the
  start label the generator emits `span_ok = x86.probe_n == 0 &&
  native.Name()` and, when it returns true, a jump to the exit label; false
  runs the recompiled stretch. The call is a sync line, so all registers are
  stored before it and reloaded after. A false return must leave the guest
  state as the recompiled stretch can rerun it from: a span is only safe when
  the stretch rewrites everything it reads that the proc may have written, or
  when the proc writes nothing before deciding.
- Under `JE_NATIVE=check` a span proc calls `span_check(exit, proc, outs,
  live)`: it saves the cpu and the output regions, runs the native body with
  mode `.On`, keeps its cpu and outputs as pending, restores the saved state
  and returns false, so the recompiled stretch runs. At the exit label the
  generator emits `native.span_end(exit)`, which compares the outputs and the
  GPRs selected by `live` (bits in eax ecx edx ebx esp ebp esi edi order:
  registers written before they are read after the exit are left out) and
  the x87 state with the pending copy. A span starting at a loop head is
  entered again on each pass of the recompiled loop, and one starting at a
  function's entry again by each recursive call; while a check is pending for
  the same exit at the same or a deeper stack pointer, those entries run
  nothing and the exits of deeper frames compare nothing, so the first
  entry's native run is the one compared, at its own frame's exit.
- `SkinMesh_Bones` (0x62d181 to 0x62d6aa), the bone loop of
  `SkinMesh_Render` (0x62cb90): each bone's skinning matrix as three rows of
  the shader-constant table at 0x7ed7e0. q = bone rotation, v = rotate(q,
  bind pose) + bone position, P = rotate(Q, v) + A for the parent-walk
  rotation Q and translation A, t = Q (inverse bind q), rows (m0 m3 m6 Px),
  (m1 m4 m7 Py), (m2 m5 m8 Pz) of `quat_matrix(t)` at the bone's slot,
  clamped to the 0x11 or 0x30 slots of the table. The two rotations add the
  x terms in different orders and spill different products; both are
  replicated, as is every frame temporary the guest writes. f32 rule over the
  whole loop, a fallback rerunning the recompiled loop from its start (it
  rewrites every frame slot before reading it). Its stretch was the hottest
  part of SkinMesh_Render (2.1% of the v39 profile, store-forwarding stalls
  on the loop's frame temporaries). v40 against v39, alternating:
  6.49-6.53 against 6.58-6.90 M cycles per frame, instructions 14.62-14.66 to
  14.33-14.35 M. Check run (v40): 16.7 M calls, no mismatches.
- `Rope_Relax` (0x6052e0 to 0x60554b), the relaxation passes of r_00604fa0:
  two lists of 12-byte links (i0, i1, length L) over the particle positions
  at `[rope + 0x80]`. With k = L^2 / (|d|^2 + L^2) - 0.5, an approximation of
  the distance correction without a square root, each pin moves p[i1] by
  -2 d k (d = p[i0] - p[i1]) and each link moves p[i0] by -d k and p[i1] by
  +d k (d = p[i1] - p[i0]), in list order. Passes run while the frame counter
  is below the frame's f32 limit. The span starts at the loop head, so a
  fallback costs one recompiled pass before the next try. The positions
  are relaxed in a copy (at most 256 particles, 64 passes, 1024 links per
  list, the positions overlapping nothing the loop reads) and committed after
  the f32 rule holds; the frame is dead at the exit and is not written. Profile
  share 1.60% to 0.74%. v41 against v40, alternating: 6.41-6.56 against
  6.52-6.71 M cycles per frame, instructions 14.33-14.42 to 14.05-14.14 M.
  Check run (v41): 16.7 M calls, no mismatches.
- `Skeleton_GatherWorldPose` (0x629dc0 to 0x62ab50), a whole function as a
  span from its entry to its epilogue: a bone tree's world positions and
  rotations pushed to two arrays in depth-first order, each node's p +
  rotate(q, v) (v when q's w is exactly +-1) and q composed with its
  rotation, from its parent's p and q. The guest unrolls five levels of the
  recursion and calls itself below them; the rotation is the same at every
  level, but the compose's x and y sums associate differently at each, so the
  native picks the order by depth mod 6. The native walks the tree itself (at
  most 128 nodes, depth 64, 64 children each) and falls back when an array
  would grow (the guest reallocates through operator new), the two counts
  differ (the guest indexes both arrays by the positions' count), or the
  pushed elements or the guest's stack overlap anything it reads. The
  epilogue pops the saved registers, so the proc stores them where the
  prologue would. Profile share 1.50% to 0.35% plus 0.34% (compute), 0.32%
  (walk) and 0.19% (overlap checks). v42 against v41, alternating:
  6.33-6.55 against 6.43-6.60 M cycles per frame, instructions 14.06-14.14
  to 13.74-13.86 M. Check run (v42): 33.5 M calls, no mismatches.
- `Emitter_Quads` (0x63aba0 to 0x63aee5), the per-particle loop of
  Emitter_Update for the first pass: each particle's four vertices (0x18
  bytes: position, ARGB, u, v) into the vertex buffer. The loop's two calls,
  Emitter_InterpColorSize and Emitter_ParticleBasis (both natives), go
  through `call_guest` with the guest's pushed arguments and return
  addresses; the rest is the basis scaled by half the sizes, the atlas cell
  by idiv, the color packed through SSE `mulss` and `cvttss2si` and the four
  corners, the third corner's z summed in a different order from x and y.
  The calls of up to 64 particles run first (their outputs kept), then the
  vertices of all of them under one f32 rule check (v45): per particle, the
  MXCSR accesses cost more than its arithmetic. The batch's vertex range must
  overlap neither the frame nor its particles, so the calls cannot see the
  vertices. A batch commits whole, so a fallback hands the recompiled loop
  the first particle not committed; the calls have no side effects outside
  their outputs, so running them again is harmless. Later passes (fade and
  atlas cell from the cell step helpers) run in the exact path (v49). Check mode compares the frame slots and the
  first vertices up to SPAN_OUT_MAX. v43 against v42, alternating:
  6.29-6.33 against 6.30-6.36 M cycles per frame, instructions 13.74-13.76
  to 13.61-13.63 M. Check run (v43): 33.5 M calls, no mismatches. v45
  (batched, no bounds checks) against v44, alternating: 6.13-6.25 against
  6.23-6.56 M cycles per frame, instructions 13.30-13.41 to 13.05-13.11 M.
  Check run (v45): 33.5 M calls, no mismatches.
- `Emitter_Physics` (0x635c80 to 0x63688d), the per-particle loop of
  r_00635a50, the emitter tick's particle physics (v68). Per particle:
  age += dt (past the emitter's life the particle dies, or loops to age 0
  when the definition repeats), angle += spin dt wrapped by 2 pi, the
  position copied to the frame, then for a particle not landed P += (D speed
  + V) dt, V.z -= dt gravity-scale 9.81 and speed *= max(1 - dt, 0). The
  span takes only the emitters on the plain path: life not negative, not
  the immortal mode, not kind 6 (the trail lerp), no attractor target, the
  empty move callback (0x59f310) and no wind or collision flags. Everything
  else (a dying particle, one overlapping the frame, the emitter, its
  definition or the particle array) is handed to the recompiled loop at its
  head through a false return with the head's register state, and the span
  takes over again at the next head. Batches of 64 run under one f32 rule
  check with an undo log of the seven dwords a particle's step writes; a
  failed batch is rolled back and rerun in the exact path. The exit leaves
  eax (fstsw over the last 1 - dt compare), ecx, edx, esi and the frame's
  index slot as the guest's last iteration would. Check mode saves every
  particle's 26 dwords from p + 8 around span_check and restores them, since
  the span writes particles span_check cannot put back. Profile (cave, same
  spot): r_00635a50 3.19% self to 1.59% (`phys_run`) plus 0.40% (the
  recompiled remainder, the handed-off particles). The scene's particle load
  swings between runs, so fps samples (617-690 with the span) do not
  isolate it. Check run (v68): 8.4 M calls, about 100 K handed off (all at
  the loop exit), no mismatches.

The separate-module build (`-use-separate-modules`) never inlines
`runtime::bounds_check_error`, so every checked index is a call, a constant
one included: 30 in the quad vertices alone. The hot natives, whose indexes
are loop constants or bounded by their own guards (rope indexes below the
checked extent, pose nodes below POSE_NODES_MAX), carry `#no_bounds_check`,
and `sv` with them (v45, v46); the discovery patterns in x86rec.py accept
the tag on a native's header. Check: `objdump -d port/jade` shows
`bounds_check_error` only in native.odin's check-mode and registration code.
v46 against v45, alternating: 6.14-6.18 against 6.23-6.30 M cycles per
frame, instructions 12.99-13.09 to 12.44-12.49 M. Check run (v46): 33.5 M
calls, no mismatches.

The port builds for the host CPU (`-microarch:native` in build.sh, AVX2 and
AVX-512 where present; v44). The natives stay bit-exact under it because LLVM
neither fuses a multiply and an add nor reassociates without fast-math flags,
which the port never sets; the binary holds no `vfmadd` instruction. v44
(Zen 4) against v43, alternating: 6.27-6.37 against 6.37-6.65 M cycles per
frame, instructions 13.61-13.66 to 13.34-13.42 M. The Windows build targets
`x86-64-v3` (AVX2) instead, so one exe runs on any recent PC
(`JE_ARCH=<microarch> ./build_windows.sh` changes it).

## §9 Guest patches

`PATCHES` in `tools/x86rec.py` rewrites guest bytes before decoding. Each
entry names the original bytes, and the generator stops if they differ. A
patch goes on the list only when the code it changes holds a screen up for a
fixed time and nothing waits on that time, or when it removes a constant the
port's HLE layer takes over, which then keeps the original behavior behind
its own switch.

| Address | Site | Saved |
|---|---|---|
| 0x5699d9, 0x569a04 | New Game opener `FUN_00569940` shows the `hideload` box (panel 0x67) through `FUN_00554190(dur, 1)`, which sets the close timer at +0x74 to dur + 1.0. Dur is 1.5, or 0.25 when `HD0:\Data\mmenu_a` is already resident. `mmenu_a` is read synchronously before the box opens, so every box frame is idle; the bar only shows elapsed time (`0x51f920` clamps the negative value to 0). Both pushes become -0.999, so the timer is about 0.001 and the update `FUN_0051b920` runs the close callback on its first frame. A timer of 0 would never fire: the update only counts down a positive timer. The other caller, 0x40a760 (in-game loads with 3.0 or a -1.0 hold), keeps its timings. | 2.5 s per New Game |
| 0x668481 .. 0x668574 | CXbInput `0x6678e0` drops each stick axis within -6535..6535 of centre (`cmp ax/cx, 0xe679` and `0x1987` for left X, Y and right X, Y) and passes the rest unscaled, so a stick snaps to the axes and jumps from 0 to 20% of its range. The eight immediates become 0, and `win32/pad.odin` applies a radial deadzone instead, or the same per-axis one with `JE_STICK=0` (docs/hle.md §5). | not a timing patch |
| 0x54ee97, 0x54d4b0, 0x54d849, 0x54d4bc, 0x54f293, 0x54e4aa | CPanelCustomVideo reads its row labels from the nine-strref table at 0x75b868 and stops at nine rows. The three table references move to 0xa00000, a page nothing else uses, the two row-count compares go from 9 to 28, and the arrow test at 0x54e4aa (`cmp edi, 7; jne`, arrows only on row 7) becomes `cmp edi, 8; je`, arrows on every row but Brightness. The port fills the table and handles the new rows (§11). | not a timing patch |
| 0x574051, 0x574064, 0x57406f, 0x574181, 0x574296, 0x5742e6, 0x57015f | CPanelOptionsCont builds five rows from the 16-byte rows {strref, default, min, max} at 0x703448 and takes their descriptions from 0x6ff1fc. The two list sizes and the loop end go from 5 to 18, the three row-table references move to 0xa00100 and the description table reference to 0xa00280. Stepping (0x570390, 0x5704c0) and the game's config keep the original table and its five rows. The port fills both tables (§11). | not a timing patch |
| 0x4a4ed2, 0x5564e7 | After a save, the main loop (0x4a4ee0) and the save screen's callback `0x556320` (0x556500) redraw the save message 17 times, each pass a Present, about 280 ms at 60 Hz. Their sleeps are elided (docs/hle.md §2); the counts (`mov edi, 0x11`, `mov esi, 0x11`) become 1. Not 0: the do-while loop divides by the count. The port's Present holds the last game frame while the box is up (docs/rendering.md §3), so the one pass shows nothing. | about 280 ms per save |
| 0x4c3418, 0x4c354f, 0x4c369d, 0x4c36ee | DoEvade `0x4c3070` compares its dodge direction against ±cos 45° (the shared doubles 0x6e53c8, 0x6e53c0) for the front and back flips and the side rolls. The four compares read the port's doubles at 0xa00310 instead, filled by `native/dodge.odin` (§10). | not a timing patch |

## §10 Behavior hooks

A proc in `port/src/native` with the native naming can also change what a
guest function does on purpose. It is registered and called like a native
replacement, runs the recompiled body itself, and is outside the bit-exact
contract of §8: JE_NATIVE does not switch it, and check mode compares nothing
for it. Each has its own switch.

`docs/game_map.md` maps the gameplay functions, fields and globals these
hooks touch.

**Animation blending** (`native/blend.odin`, v56). An object's animation
layers are at `[obj+0x268]`, count `[obj+0x26c]`; a layer (0x38 bytes, ctor
0x60b8a0) holds the animation at +0xc, the weight at +0x20, the transition
time at +0x24, the state at +0x30 (1 blending in, 2 full, 3 blending out,
4 dead) and the seconds into the transition at +0x34. PlayAnimation
`0x60d2f0` (thiscall: name, ?, flags, start, blend, out) sets the transition
time to the blend argument, or to the MDL's `[anim+0x54]` when it is -1;
flag 2 snaps the layer in at weight 1. The update `0x60f760` moves the weight
linearly, dt * speed / transition per frame, so a 0 transition is a cut, and
calls `0x60e8f0` (cdecl: model, anim, flag, prev, time, weight) to build the
pose, each node set to sample * weight + node * (1 - weight) over the older
layers' pose. A combat run logged the MDL defaults: 0 for the impact,
cessation and duration phases, 0.04 between combo hits (m1b, m1c), 0.15 for
attacks and hit reactions (m1, dmgpbck1), 0.25 to 0.75 for locomotion and
idles.

- After PlayAnimation, a layer that starts blending in (state 1, weight 0,
  nothing elapsed) with a transition under 0.12 s gets 0.12 s, unless the
  caller passed a blend of 0. Flag 2 snaps are left alone.
- `0x60e8f0` gets the weight eased by smoothstep, `w * w * (3 - 2w)`, so the
  blend starts and ends without a jump in velocity. Weights 0 and 1 pass
  unchanged.
- `JE_BLEND=0` keeps the original blending; `JE_BLEND_MS` sets the minimum
  in milliseconds.

Check run (v56): 33.5 M calls, no mismatches.

**Turn-to-run** (`native/turn.odin`, v57). CPlayerControl's update `0x463570`
(control at `[player+0x7ec]`, vtable 0x6e86e8, stick at +0x10/+0x14) turns the
stick by the player's facing and builds a stack CMoveDataCreature (ctor
0x45bfd0, vtable 0x6e7ef0; creature at +0x90, current facing +0x6c, desired
facing +0x78, initialised to the current one). It calls `0x45c720` (thiscall:
dir, the turned stick; also the vtable's slot +8) to pick the move mode
through GetCombatMovementDirection `0x45c190` (0 forward, 1 back, 2/3 strafe,
4-7 diagonals) and write the move direction to +0x60. When the move runs,
`0x45e070` turns +0x6c toward +0x78 and the apply `0x45c980` sets the facing,
so out of combat the player keeps the facing and strafes or backpedals, and
the trailing camera swings round behind.

- For the player (`0x424700`, thiscall on `[[0x76c924]+0xa0]`) out of combat
  stance (`[creature+0x588]` 0) with the stick off center, `0x45c720` reads
  the stick against the camera's yaw round the player (camera position
  `[[[0x76c924]+0xa0]+0x124]+0x7c`) and writes the desired facing one step
  toward it, at most 2π rad/s times the frame time `[[0x76c924]+0x20]`. Its
  input becomes the current facing at the stick's length, so the mode is
  forward and the player runs along the facing while turning.
- The camera yaw is latched when the stick leaves center and held until it
  returns. Read live, the camera follows the turning player and the target
  turns with it, so the player runs in circles.
- (v94) A latch held for the whole push breaks steering by sweeping the
  stick: after the camera has swung behind, a new stick angle still maps to
  the old camera, so the player turns away from where the stick points on
  screen. Each frame, the latched yaw moves toward the live camera yaw by at
  most the change in the stick's angle on the pad since the last frame. A
  steady stick keeps the latch, so the player does not run in circles. A
  sweeping stick tracks the screen.
- (v95) Even so, steering felt pulled back: mid-sweep the latch trailed the
  shown camera by up to 0.8 rad. With the free camera (below) running, the
  stick is now read against the live shown camera with no latch. The camera
  holds its heading while the player turns, so nothing chases. The latch
  remains only for `JE_CAMERA=0`.
- (v102) The camera's yaw is the yaw of its view direction (local -z turned
  by the quaternion at camera +0x88, `cam_view_yaw` in `native/camera.odin`),
  not the angle from the camera's position to the player. Where collision
  pulls the camera in close, a small sideways offset of its position swung
  that angle far off the screen's up, and the walk direction jumped. Looking
  almost straight down (horizontal part under 0.1) it falls back to the
  position angle. Out of combat with the camera at range the two agree to
  0.1 degree (`JE_STICK_LOG` prints both, `view` and `round`).
- (v97) The stick's angle comes from the virtual pad's left stick (LX, LY
  at CXbInput +0x10, kept on each gameplay read in `Xb_Input_006678e0`), not
  from `0x45c720`'s input. Under camera type 0x1070 mode 0x51, `0x463570`
  measures an angle (`[esp+0x20]` near 0x464560, thresholds 45 and 135) and
  at `0x464762` negates the turned stick so the player backpedals. Read from
  the input, a stick a little past screen right became straight back and the
  player turned round and ran at the camera. The input still gives the
  stick's length, and its angle when the pad stick is centred (keys).
- (v98) Reversing ran a wide arc: the player kept full speed along the
  facing for the whole turn. The turn rate is now 3π rad/s, and the input
  length is scaled by the cosine of the turn still to go, floored at 0.15
  (`TURN_CRAWL`), so a quarter turn or more pivots near the spot. Tested:
  left to right turns in about 9 frames at 0.3 to 0.8 units/s, then runs at
  full speed.
- (v99) Rolling the stick from south toward east or west turned the body
  about twice as far as the facing, then snapped it back near pure east or
  west. Facing (`+0x50`), the desired facing (`+0x78`) and the creature's own
  orientation (`+0x758`/`+0x764`) were all smooth. The rendered model is not
  the facing. The move update `0x45e300` builds the model's heading as the
  desired facing turned by the stick's angle off ahead. It takes that angle
  from the unit stick at CMoveDataCreature `+0x94` (x across, y ahead, the
  stick relative to the facing in the original controls), using `acos` against
  ahead and skipping it while `|y|` is under 0.1. It hands the result to the
  model's orientation (`[creature+0x520]` vf `0x38` = `0x4ff500`, quaternion at
  gob `+0x84`). Turn-to-run already points the desired facing along the stick,
  so the angle was applied twice. `Move_Dir_0045c720` now leaves the stick at
  (0, length) after the game's call: straight ahead, which is what the stick
  is to a player who turns toward it. Tested on Save 29 with a 0 to 90 degree
  roll: model heading equals facing on every frame, with no snap.
- (v99) `0x45c980` (the move animation, CMoveDataCreature vtable) classifies
  the velocity against the model's heading into 45 degree sectors (`0x45c190`:
  0 ahead, 1 back, 2 and 3 sides, 4 to 7 diagonals). With both stick axes at
  0.1 or more it plays forward. Out of combat with x under 0.1 it folds the
  diagonals into ahead and back, and with y under 0.1 every sector survives.
  Either way a wall that slides the velocity more than 22.5 degrees off the
  heading plays a strafe (`cwalkl`, `cwalkfl`, `cwalkb` ...) through
  `0x4ba210`. `Move_Anim_0045c980` shows the stick as (1, 1) for the player
  out of combat, so it always plays walk, jog or run; the stick is restored
  after.
- The step is needed because `0x45e070`'s own turn stops short on wide
  angles: given the exact reverse it does not turn at all, and given a
  quarter turn it stalls about halfway.
- 0x45c720 is called directly from 0x4649cc, so adding or removing this hook
  needs the generator rerun (§8), not just a build.
- `JE_TURN=0` keeps the original movement.

Check run (v57): 33.5 M calls, no mismatches.

**Right-stick target switching** (`native/flick.odin`, v58). CXbInput
`0x6678e0` (thiscall(a1, a2), ret 8; one object per controller port, 0x33a8
bytes apart, called more than once a frame) rebuilds a virtual Xbox pad at
`this`: the left and right triggers as bytes at +0xe and +0xf, which the game
reads as previous and next target, and the sticks as i16 at +0x10 (left X, Y)
and +0x14 (right X, Y). The port's hook runs the body, then, while the player
is locked on:

- Locked means `[0x75ecdc]` nonzero, the app state `[[0x76c924]+0x38]` 0 or
  5, one party creature (`[[[0x76c924]+0xa0]+4]` 1, creature
  `[[[[0x76c924]+0xa0]]]`) in combat stance (+0x588 nonzero), target mode
  (u16 +0x590) 1 and a target (+0x58c) other than the invalid id
  `[0x75b394]`. These are the Controller Fix mod's conditions.
- Both right-stick axes within 0x2ccc of centre arm a flick. Armed, an X past
  0x5333 and past |Y| fires one: the trigger on that side reads 0xff for the
  frame, unless either trigger is already held. A flick is kept per CXbInput
  and frame, so every call in that frame sees it.
- The right stick reads centred while locked, so it no longer moves the
  camera there.
- 0x6678e0 is called directly, so the hook needs the generator rerun.
- `JE_FLICK=0` keeps the original right stick.

**Free camera** (`native/camera.odin`, v61). The exploration camera
behavior (vtable 0x6e37d0, Update `0x420f60`, thiscall(dt), ret 4) is a
spring that pulls the camera back behind the player's facing each frame,
so a pose written before Update is undone within two frames. The port keeps
its own yaw and pitch and shows a shadow pose instead:

- Out of combat (§10 flick conditions, without the target), the CXbInput hook
  takes the frame's largest right-stick reading for the camera and centres
  the pad's right stick, so the game never sees it.
- Before Update, if the camera (`[this+0x3c] - 4`; position f32 +0x7c,
  quaternion +0x88 stored w, x, y, z, looking down local -z) still holds
  the pose the port showed, bit for bit, the game's own pose is put back.
  Update then runs on its own state, and its result is saved.
- The stick moves the yaw (π rad/s) and the pitch (π/2 rad/s). When the
  stick has rested 0.75 s and the target (`this+0x48`) moves, the yaw decays
  back at 1.5 per second.
- (v95) With turn-to-run on and the player out of combat, the yaw also takes
  away each update's swing of the game's camera round its target (yaw of
  target minus the game's own position). The shown camera holds its heading, and the turn reads the stick
  against it without chasing itself. The decay back behind is scaled by how
  far the player runs away from the shown camera: the cosine of facing
  against view direction, floored at 0. Running sideways or toward the
  camera, it stays put; running away, it falls in behind.
- (v100) Only a cut passes the game's swing through: the update did not run
  the frame before (a new camera, a load, or a conversation or cutscene had
  the view). v95 took a jump of 1 rad or more in one update as a cut; where
  collision pulls the camera in close to the target (radius 3.1 down to
  under 1 against swamp reeds), the yaw round the target turns by that much
  while the player stands blocked, and the shown view spun.
- The look point is where the game's view ray passes the target's vertical.
  The pose is turned round it: pitch about the horizontal axis across the
  view, clamped to elevations -0.35..1.2 rad, then yaw about z. Position and
  quaternion turn by the same rotation.
- The turned position goes through the game's collision clip `0x420730`
  (thiscall(out*, want*), ret 8), with its flags at +0xe8 and +0xec saved
  and restored round the call.
- 0x420f60 is reached only through the vtable, so the hook needs no
  generator rerun.
- `JE_CAMERA=0` keeps the original camera.

**Aimed targeting** (`native/target.odin`). In combat stance the player
update `0x4f20d0` calls the player target update `0x434430` every frame. Its
gate `0x4340c0` lets it pick only when the target (`creature+0x58c`) is the
invalid id, destroyed (`[obj+4]` bit 2) or dead (`0x40ee80`). It then
gathers objects of types 2 and 9 within 20 m of the player (`0x4246d0`,
`0x4ad770`), filters them (hostility `0x46fd40`, vtable +0x3c, `0x4bc760`),
and keeps the least squared distance below 400 from the position `0x4123d0`
returns, setting it with `0x46ff70`. So a new target is always the nearest,
wherever the player is looking or pushing.

- `0x4123d0` (thiscall, returns ^f32 x, y, z) is hooked. Called from
  0x4345f4 (return 0x4345f9; edi is the player there), it returns a point on
  the line from the player to the candidate at s times its distance,
  s = (1 + K(1 - cos a) / 2) / (1 + K) with K = 2, where a is the angle in
  xy between the candidate and the aim. Ahead counts 1, side on 2, behind 3
  times its distance; scaled by 1 / (1 + K), so whatever passed the game's
  400 still passes.
- The aim is the movement direction the hook on `0x45c720` last saw for the
  player in combat stance (the stick turned by the facing; 0 when centred),
  else the camera's view, camera position to player.
- 0x4123d0 is called directly, so the hook needs the generator rerun.
- `JE_AIM=0` keeps the nearest pick.

**Input buffer** (`native/buffer.odin`). The player's combat presses reach
the press handler `0x44cb00` (thiscall(buttons, creature), ret 8; creature
0 is the player) on the combat controller `[[input+0x94]+0xc]`. It sets the
buttons in the held mask `[ctrl]`, picks a move (`0x44c420`) and queues it
(`0x443d80`); a repeat of the last move steps the combo (`creature+0x1220`).
It drops the press, clearing the buttons from `[ctrl]`, when no move fits or
the creature's flag set (`0x4b81f0`) holds 1 or 0x32, or 2 with a move other
than 0: the current move is still busy. Nothing remembers a dropped press,
so a click a little before the combo window opens is lost and the chain
ends after one or two hits.

- The hook on `0x44cb00` keeps the player's last dropped press while in
  combat stance. The hook on the per-frame combat input tick `0x44a8d0`
  (thiscall on the input block, called from 0x4336d5; it hands queued
  events to `0x448bd0` every second tick, then the held handler `0x44b9e0`)
  calls `0x44cb00` again for that press after the tick, for up to 0.35 s.
  An accepted press clears it.
- A release (`0x44c3c0`, same arguments) of the buffered buttons seen
  before the retry is taken is sent again after it, so the buttons do not
  stay held.
- Six clicks 2 frames down and 8 up gave m1, m1b, m1c; without the buffer
  four gave two hits.
- 0x44cb00, 0x44c3c0 and 0x44a8d0 are called directly, so the hooks need the
  generator rerun.
- `JE_BUFFER=0` keeps the original input.

**Enemy AI** (`native/ai.odin`, v84). The combat AI of a creature (`[cre+0x620]`;
+0xc its target creature, +0x7c aggressiveness, 0 to 10 in
combataitemplate.2da) keeps an action stack at `[ai+0x80]` (count, capacity,
24-byte entries {type, sub, f32 param, vec3}; the current entry is the last).
Its update `0x43df70` (thiscall on the stack, (creature), ret 4) runs the
current entry only while the creature has none of states 0x11 (blocking), 1
and 0x2c (staggered), and calls think `0x43dde0` when the stack is empty.
Think rolls one action from six template odds (`0x43c680` fills them; the
sixth is idle) and never looks at the player, so a foe walks into every
combo, idles between attacks, and the game's block action `0x43c870` (pushes
type 0x4a, sub 1, 45 to 150 frames by health) leaves a foe turtling for
up to five seconds.

- Player events come from the anim play hook `0x43fec0`: an 'm' plus digit
  anim with flags 0x41 is a swing ('3' a power attack), with flags 1 its
  recovery.
- Each AI update of a foe targeting the player answers each event once, not
  while busy (the states above), with chance tier times
  `0.5 + aggressiveness/18`: a swing at this foe pushes a block
  (`0x439030`) unless one is current, or with the tier's dodge share (always
  for a power swing, which no block stops) calls DoEvade `0x4c3070`
  (thiscall creature, (f32 x, f32 y, flag), ret 0xc; x ±1 is a side roll
  `cddglf`/`cddgrt`; it refuses in states 0x32 and 0x5c); a recovery calls attack `0x43a2a0`
  with 1 (quick); a player in state 0x11 calls it with 2 (power, breaks a
  block), at most every 1.5 s.
- Block entries about to run are capped to the tier's length (150, 90, 45
  frames). Idle odds and pattern idles (`0x43b0a0`, (frames)) are scaled by
  1, 0.6, 0.3; the idle odds removed go to attack.
- Seven tiers, 0 the original to 6; react/dodge/punish/anti-block run from
  0.15/0.15/0.15/0.1 (tier 1) through 0.35/0.3/0.35/0.25 (3) and
  0.65/0.45/0.65/0.5 (5) to 0.8/0.55/0.8/0.6 (6), with block caps 120 to 30
  frames and idle scales 0.85 to 0.2. Forced to always dodge, 8 of 9 calls
  were taken.
- A foe's tier comes from its rank.2da row (`[[cre+0x1c]+0xfc]`, see
  docs/modding.md §5): rows 1 and 12 (townsfolk, fodder) 1; 9 and 5
  (soldiers, bandits, ghosts) 2; 6 and 13 (arena fighters, golems) 3; 7 and
  11 (Lotus Assassins, demons) 4; 2, 4 and 8 (named bosses, henchmen) 5; 3
  and 10 (the Emperor, Death's Hand) 6. No foe stays at the original, which
  never watches the player. The setting caps it: 0 Original, 1 Skilled
  (tier 3 at most), 2 Master (no cap, the default). Gao's men read rank 1
  (tier 1); Dawn Star reads rank 8.
- Foes parry: a player blow taken on a foe's block (blk* with flags 0x41) from a swing started within SWING_SEC staggers the player through HIT_REACT 0x4442c0 on [player+0x358], at the tier's odds (0.05 at tier 1 rising to 0.45 at tier 6, times aggression). Tested forced on: HIT_REACT returned 1.
- Recovery: higher tiers play their reaction anims (dmg*, kb*, kd*, blk?2, blk?3, stun*) faster by Tier.recover, 1.05 at tier 1 to 1.5 at tier 6, through the speed argument of anim start 0x43fec0 ([esp+8], f32), while health [cre+0x470] is at least HEALTH_KNEE 0.5 of max [cre+0x478]; below that they recover as shipped. Faster anims shorten the busy states: at 2x, pushback recovery went from 750 to 394 ms and a blow taken on a block from 560 to 295 ms. Measured as shipped: blocked blow 0.3 to 0.56 s, light stagger 0.66 to 0.76 s, pushback 0.75 to 0.79 s, guard break (kbackc then kdbckkb) 1.3 to 2.2 s. Candidate parry anims: AS row 115 stunned, blk?3 step-back.
- Heals (v89): action odds 0x43c680 copy the combat AI template's odds (combataitemplate.2da, stored at [ai+0x30..0x44]: attack, block, heal, move, switch, idle) and, at 0x43c701, fold heal into move or attack unless [ai+0x158], the rank.2da boss column (rows 2, 3, 4, 6, 8, 10), is set. Pick 0x43da20 dispatches case 2 to 0x43ad00 only for AI creatures ([ai+0x10]==1); it heals only below 80% health (0x6e2f34 = 0.2), amount rand%15+5. Executor 0x43e280 type 3 (0x43e597) puts the creature in state 5 with [cre+0x5bc] heal frames from the style's healrate; its cost check reads max health 0x423d40, not chi, so shipped heals cost no chi (Dawn Star 146 to 156 hp with chi held at 50). Creature update 0x4ca7d6..0x4ca89b counts [cre+0x5bc] down and ends state 5 at 0. The port gives non-boss foes of tier HEAL_TIER 3 and up their template ProbHeal back when they hold at least HEAL_CHI 5 chi ([cre+0x488]), and charges one chi per health point restored, read off the health change each AI update; chi running out takes back the unpaid health and zeroes [cre+0x5bc]. Bosses keep the free shipped heal. Few tier 3+ templates carry chi (sailors 20, pirates 50); fodder never heals.
- Rank columns (v90): 0x436b50 copies the eight rank.2da columns into
  [ai+0x158..0x174] (defaults 0x43d99b: all 0, Intelligence 3, SlamChance and
  AAABlockChance 100). The shipped AI rolls three of them with 0x437620
  (rand/32767 < p): Evasion [ai+0x160] 0 skips its evade path (0x43c8f5), 2
  allows one more (0x43ac58); SlamChance [ai+0x16c] percent is the odds of a
  power attack (0x43a2a0 with 2) on a target in state 0x11 (0x437710, called
  0x43ebc9); AAABlockChance [ai+0x174] percent is the odds a foe in hit
  reaction 6 or pushback 7 (0x437960) blocks out of it (0x43e985). The port's
  reactions follow them: a foe with Evasion 0 never dodges (the dodge becomes
  a block, or nothing against a power swing), its blocks are rolled again at
  AAABlockChance and its anti-block power attack scaled by SlamChance. Rows
  1, 5, 9, 11, 12 (766 of 948 RIM templates) have Evasion 0.
- Tiers 4 to 6 read baits (wary 0.4, 0.8, 1; block hold 0.3, 0.5, 0.6 s). Each foe keeps a suspicion per reaction (block,
  dodge, punish, anti-block), 0 to 1. A hit anim on the foe (`dmg*`, `kb*`,
  `kd*`, flags 0x41) within 1 s of its last reaction adds 0.5 to that
  reaction's suspicion, which fades by 1 per 20 s. Suspicion times 0.8 cuts
  the punish and anti-block odds; a burned block moves the reaction's share
  toward dodges and a burned dodge back. A power attack waits for a block
  held 0.5 s, so flicking block does not draw one. Tested: a punish that
  was answered by a hit set punish suspicion to 0.5.
- Gao's men fight (Auto 1 save), 40 clicks: Original foes attacked 2 to 3
  times and blocked 44 to 54 samples; Master 14 attacks and 2 player hits in
  one run, flat in the other.
- 0x43df70, 0x43c680, 0x43b0a0 and 0x43fec0 are called directly, so the
  hooks need the generator rerun.
- `JE_AI=0` keeps the original AI.

**Foe personalities** (`native/persona.odin`, v135). A tier says how much a
foe can do; its personality says what it spends that on. Four traits, attack,
guard, evasion and cunning, are weighed by five archetypes (brawler, duelist,
trickster, turtle, berserker), each summing to four so a mix moves skill between
traits without adding any.

- A foe's mix is 0.6 of a primary and the rest less 0.1 of a secondary
  archetype, both picked by FNV-1a of its template resref (16 bytes at
  `cre+0xc`), so foes of one kind share a temperament; FNV-1a of its object id
  picks a 0.1 third archetype and moves up to 0.1 between the first two. Cached
  per creature address, rebuilt when the id there changes.
- Mood: below HEALTH_KNEE health the mix blends, up to 0.5 at no health, toward
  the berserker, or toward the trickster for a foe that guards more than it
  attacks.
- Habits: the player's swings, power swings and time blocking, faded over 8 s,
  make three levels (1.2 swings a second, half the time blocking, power share
  of the swings). They draw the turtle, the brawler and the trickster, up to
  0.5 of the mix, scaled by the foe's cunning against the trickster's.
- The traits are evened to a mean of one and scale the tier: react by
  (guard+evasion)/2, the dodge share reweighted by evasion against guard,
  punish by attack, anti-block by (attack+cunning)/2, idle removal by attack,
  parry by (guard+cunning)/2, block caps by guard (150 at most), wary and the
  block hold by cunning. Odds stay at 0.95 at most.
- Roles: each AI update of a foe on the player records its distance. A foe
  with PRESS_N (2, 3 while player 2 is in) nearer foes updated within 0.5 s
  waits: its punish halves, it breaks no guards, keeps the tier's idle, and its
  attack odds are cut to 0.25, the rest moved to moving.
- Original (tier 0) has no personality. All inputs are hashes and game events,
  so lockstep peers agree. Roles and habits count only foes on player 1.
- Tested (debug prints): mixes per foe (J01C_BSCOUT_02 turtle 0.53, berserker
  0.37, trickster 0.1); A mashed raised the spam level to 1, B held the turtle
  level to 1; with PRESS_N 1 the farther foe waited and its attack odds moved.

**Parry** (`native/ai.odin`, v85). The game has no parry window, so the port
adds one. The same anim hook tracks the player's block: `blk*` with flags 0x40
is the block raised (`blkl1`, replayed about every 2.3 s while held), with
flags 0x41 a blow taken on it (`blkl2`); any other anim ends it. It also
records the last foe that targets the player and started an attack (flags
0x41). A blow taken within `PARRY_SEC` (0.2 s) of raising the block, from a
swing started within 1 s, calls the hit reaction `0x4442c0` on that foe's
anim component (`[cre+0x358]`, thiscall (move 0, kind 1, 0, 0), ret 0x10).
Kind 1 is the plain-hit stagger (`dmgfr*`), the one the hit loop queues; the
call sets state 6 and queues the move, and it refuses when the AI flag
`0x4382f0(3)` is set or the creature has state 0x5e, 0x18, 1 or 7. Tested on
the Gao fight with the window widened: it returned 1 and the foe had state 6.
Power attacks break the block (`kbackc*`, then `kdbckup`) and never parry.
Other hit reactions: `dmgfrhilt*`/`dmgfrmilt*` stagger (states 6 and 0x2c),
`dmgpbck*` pushback (state 7, entry 0xb5 kind 0x10). `JE_PARRY=0` turns it off.

**Dodge sectors** (`native/dodge.odin`, guest patches §9). DoEvade
`0x4c3070` (thiscall(f32 x, f32 y, flag), ret 0xc) takes the stick: the
player's action dispatcher `0x4f3b30` (thiscall on the player, (actions*);
41 action slots of 28 bytes, the stick's X in slot 10 at +0x118 and Y in
slot 17 at +0x1dc) passes `-X, Y`, directly at `0x4f4a9e` and `0x4f4b3c` or
through `0x4f3600` (`0x4f39b0`, `0x4f3ac1`), when `[[0x76c924]+0x7c0]` is 1
or 2. DoEvade turns the stick into a world direction by the player's
flattened facing (GET_PLAYER `0x424700`, +0x50) and dots it with the
creature's own facing: at least cos 45° (`0x4c3418`) flips forward
(`cddgfr1`), at most -cos 45° (`0x4c354f`) flips back (`cddgbk1`).
Otherwise it dots with the facing's right and rolls (`cddglf`, `cddgrt`)
past ±cos 45° (`0x4c369d`, `0x4c36ee`); a direction that passes none falls
back to the front flip (anim entry 0xf4) and logs an error. For the player
both facings are the same, so the dodge is picked by the stick's angle on
the pad alone, and "left with a little up" crossed 45°. The four compares
read the port's doubles at 0x00a00310 instead: ±cos 30° for the flips and
±sin 30° for the rolls, so the rolls cover 120° each side and nothing falls
through. Narrowing only the flips sends 30°..45° to the fallback front flip.
Tested on the Gao fight with the stick 40° and 50° up from left and right:
all rolled toward the stick. Foes go through the same call (`ai.odin`) and
roll more often too. `0x447c79` and `0x447c9d` read the same doubles and
keep them.

**Combat pace** (`native/pace.odin`, v106). The same anim hook speeds up
the player's attacks: anims named `m` and a digit (`m1`, `m1b`, `m3`) play
faster through the speed argument of anim start `0x43fec0` (`[esp+8]`,
f32), by `attack` for the swing itself (flags 0x41) and by `recover` for its
`m…tran` recovery (flags 0x1). Damage lands on animation events, so it moves
with the swing. `JE_PACE` picks the pair: 0 Original {1, 1}, 1 Quick
{1.1, 1.4}, 2 Fast {1.2, 1.8}. Foe tier recovery (above) runs first and only
on foes.

Hit stop slows the game clock (`win32/kernel32.odin`, `clock_slow`) for a
moment of host time: `GetTickCount` and `QueryPerformanceCounter` return
`game_clock()`, which runs at 0.08 of real time until the slow ends. Frame
pacing and the frame-rate average use host time, so the screen keeps its
rate and only the game's time step shrinks. A blow the player lands is a
hit reaction (flags 0x41, `is_hit`) started on the player's target
(`[player+0x58c]` = `[foe+0x8]`) while the player's swing is live: from its
start until the player's next anim other than an idle (`ready`, flags 0x40,
restarted every frame). A time window does not work: a power `m3` lands
about 1.2 s after it starts. A light blow stops for 45 ms, a power attack
(`m3`) for 80 ms, a blow the player takes for 35 ms. `JE_HIT_STOP=0` turns
it off. Tested on the Gao fight: light attacks scaled, two stops on landed
blows.

**Attack magnetism** (`native/magnet.odin`, v107). A player swing (anim `m`
and a digit, flags 0x41) at the target (`[player+0x58c]`, the creature seen
by the foe AI hook) slides the player toward it when the target is within
reach (centre to centre) and inside a cone off the facing. The slide runs at
its length over 0.2 s and stops 0.8 m from the target, when its length runs
out, or at the player's next anim other than an idle. It moves the player
through collision: the hook on `0x45d6b0` (thiscall, `[esp+4]` out, `[esp+8]`
mover, `[esp+0xc]` want, `[esp+0x10]` ok, ret 0x10), which `0x45e300` calls
each frame with the mover at the creature's position (`mover+0x3c` equals
`[cre+0x44]`) and the anim's root motion already in `want`, adds one step
toward the target to `want` once a frame, so walls and the walkmesh stop it.
The game turns a swing toward the target itself (0 to 17 degrees off at
swing start, Gao fight). Reach and cone grow with mastery of the style in use:
entry `[[player+0x46c] + 4 * [player+0x584]]`, byte `+5` = 1 + upgrades
bought, mastery = min(upgrades, 15) / 15, the bar the styles screen draws
(`ui_spoints_<n>`, 0x57c08b). Reach 1.5 to 3.0 m, cone half-angle 25 to 60
degrees. `JE_MAGNET=0` turns it off. Tested on the Gao fight: two swings at
1.0 m slid in to 0.77 and 0.98 m (the foe stepped back).

**Couch co-op** (`native/coop.odin`, v108). A second pad (`win32/pad.odin`
`pad2`) drives the selected henchman, slot `[player+0x1144]` of the 0x8c-byte
slots at `player+0xa28` (object id at `+0x40`). Movement: the player control
update hook `0x463570` (CPlayerControl, thiscall(dt), ret 4) runs the guest
update a second time on a copy of the player's control at `0xa00400` (0xa0
bytes) with the henchman's id at `+0x80` and the second pad's stick at
`+0x10` (f32 ahead, across), saving and restoring the jump latch `0x76c650`
and target turn `0x75b390` the update keeps for the player. Turn-to-run
(`turn.odin`) keeps a second driver for her. Combat: the AI odds hook
`0x43c680` gives her idle only, so her AI picks nothing, and the AI update
hook `0x43df70` pushes what the pad asks before the guest update runs the
stack: RT held renews a block entry (type 0x4a, 10 frames), B a DoEvade
`0x4c3070` along the stick against the camera (given against the player's
facing, which DoEvade turns by), A and X `CCombatAI_Attack` `0x43a2a0` quick
and power. Before a push the hook removes state 0x2c from her
(`0x4be030`, thiscall(state, add, param, f32 seconds), ret 0x10, add 0
removes): long moves (`0x45c40e`), dodges and hits set it for 2 s, and the
update (0x43e007) runs no action while it is set, so a henchman who moves
stays on hold. The camera stays on the player. `JE_COOP=1` turns it on.
Tested on the bandit fight: A played the m1, m1b, m1c chain, X m3, RT blkl1,
B the dodges.

**Player 2's hero** (`native/coop_hero.odin`, v110). With player 2's pad on
(online, the remote peer's), the second pad drives a creature of the port's
own instead of the henchman, which stays with player 1. The hero is a
players.2da row (appearance, two starting styles), `JE_P2_HERO` 0..6
(Blossom default); online the joining peer's, which the net handshake
carries to the host (hle.md §11). Its template
`jec_p2.cre` is a generated resource (modding.md §1): a 372-byte GFF with
Looks/Appearance, DecalTint, Stats (HealthBase 100, FocusBase 0, Rank 1) and
an empty Scripts list. The control hook `0x463570` spawns it when its id no
longer finds an object (`win32.object_by_id`; first frame, and after an
area change) by running `jec_p2_spawn.ncs` as the player:
`CreateObject(2, "jec_p2", ...)` 1.5 m to the player's left, then
`EffectResurrection` (a template creature is created dead). The hook on
nws_CreateObject `0x4922e0` takes the new object's id off the script VM
stack (`[[0x76c924]+0x9c]`, cells at `[vm+0x1a0]`, count at `vm+0x190`)
while the spawn runs. Then the player's maxima go into the creature's own
base overrides (flag and value at `+0x7b0` health, `+0x7b8` chi; max focus
f32 `+0x488`; the player's from vtable `+0x18` AsCreature, `+0xe0` and
`+0xe4`), and `jec_p2_setup.ncs` runs as the hero: 34
`AddCombatStyle(self, style, 1, 0, 0)` (slot 0 keeps it off the hotkey ring,
the last 0 skips the "learned" notice), whose style constants are sentinels
`0x7e570000 + i` patched before the run (the hero's two styles, then the
player's from `[cre+0x46c]`, `[cre+0x464]` of them, sign-bit entries
skipped, spare slots repeating the first), `SetCurrentStyle`, and full
health, chi and focus. `port/src/native/coop/gen.sh` assembles both scripts.
Tested on the Two Rivers save: Blossom spawned with health 130, chi 150 and
3 styles, and walked on the second pad's stick.

**Changing player 2's hero** (v148). The hero is the Control panel setting
`P2_HERO` (§11; `JE_P2_HERO` still overrides it), the one gameplay
setting a joiner keeps its own of (`settings_sync`). Playing alone, a change sets `coop_hero_next`; online it
takes at the next join (hle.md §11), where the net code sets
`win32.net_hero_switch` on both peers at the same frame. `coop_hero` takes
either (the net one first) and `hero_switch` swaps: it logs `coop: player 2's
hero X, was Y`, re-registers `jec_p2.cre` for the new hero and marks the hero
for setup again, keeping the old hero's own style (its first players.2da
style). After the setup script, when neither the new hero nor the player has
that style, `jec_p2_drop.ncs` (`RemoveCombatStyle(self, 0x7e590000)`, the
sentinel patched before the run) takes it away. The setup's appearance check
reads the hero's own creature (vtable `+0x18` AsCreature) rather than the
player's, so a hero whose look differs is set up again.
Tested headless in couch co-op on the Two Rivers save: the control
channel's `set P2_HERO` swapped Blossom for Ling (Blossom's style dropped, 2
styles) and Ling for Tan, then the Control panel's 18th row, moved left and
accepted, swapped Tan for Prodigy and wrote `P2_HERO=5` to `[Port]`.

**The henchman while player 2 is in** (`native/coop_hench.odin`, v111).
Player 2's hero takes the follower's place, so the henchman leaves play but
not the party: scripts speak through her and swap her by the hundreds. Each
frame outside cutscenes (`[[0x76c924]+0xa0]+0x1ec` nonzero, as
GetInCutsceneMode `0x484970` tests) and conversations (the player's or
hers, as GetIsInConversation `0x483be0` tells: vtable `+0x7c` conversation
part, owner id at `+0x78`) she is deactivated as SetObjectActive `0x4946c0`
does (vtable `+0xb0(0)`; `+0x90` active, `+0x94` zero while inactive, `+0xac`
activates) and kept 1 m to the player's side, facing as the player does, so
she comes back there and not between the player and the camera. Her slot's
combat mode (`+0x2c`, a HenchmenAIData.2da row) is set to support (1) with
CPlayerCreature_SetHenchmanMode `0x4f4e80` (thiscall(slot, mode), as the
party panel does); the old mode is kept per slot. The support buff needs
more than the mode. CPlayerCreature `0x4f1200` (thiscall player(slot)) puts
it on the player, and only her own update (`0x4cf500`, at `0x4d0796`) calls
it, every frame, past a gate on her in-combat flag `+0x588` (set through
vtable `+0x114`, a plain store `0x4c6770` on CCreature). Out of the world,
she never updates, so the player got no buff (tested: Dawn Star's chi regen
gone). Calling `0x4f1200` for her crashes: after the buff it starts her
casting reaction (`0x4c2720`), and her animation part `+0x358` is null while
she is inactive. So the hook mirrors the player's `+0x588` onto her, and
when the player goes into a fight it applies the buff alone, as
`0x4f1783`..`0x4f17d2` do. It applies only when the mode row's status column
(HenchmenAIData.2da, rules 2da `0x50` from `0x65e030`, column 6 read by
`0x658500`(row, column, ^out)) is the support state `0x35`. The buff is an
effect made by `0x424c30`(type, param) on the module, from the slot's
SupportEffect `+0x34` and SupportEffectParam `+0x38` (loaded at
`0x4ebfd0`); it returns none for a type of 0 or less, which covers the
henchmen without a buff. The effect gets her id as its creator (`0x50fe80`),
byte `+0xa` `|= 0x20` and `+0xfc` = 1, and goes on the player with
`0x4c4eb0`(effect, 0, 0). The support effect's apply `0x50b1c0` puts its sub-effects
(types 9 to 12) on the player and has its creator react; so does its removal
`0x50b470`. Both look the creator up by id (`0x4611b0`, called from
`0x50b38f` and `0x50b4f6`) and use its `+0x358`. A hook on that lookup
returns none from those two sites when the creator is inactive. The creator
id stays hers, so the player's combat end (`0x4ef6f0`(slot, 0) from
CPlayerCreature_Update `0x4f356c`) still removes the buff by creator. Tested
with P2 in: chi after EffectDamageChi went 66, 70, 86 over the first 5 s of
the bandit fight, as it did with her in the world, and the player's death in that
fight took the buff off without a crash. In a cutscene or
conversation she is active again and player 2's hero is out (deactivated the
same way, and put back at the player's side when play resumes; its control
update does not run meanwhile). When player 2 is out (pad unplugged, peer
gone) she is activated, the modes come back, and player 2's creature is
deactivated in turn, to be put back at the player's side when player 2
returns. A henchman a script deactivated is left alone. This runs in a hook
on CPlayerControl_Frame `0x464aa0` (vtable `0x6e86e8` slot 8), which
CAppBase_Update `0x40ca50` calls every frame through `[player+0x7ec]`;
CPlayerControl_Update `0x463570` runs only when `[0x76c924]+0x38` is 0 or 5,
so not in dialogue or cutscenes. `JE_CTL`'s `pad2 off` and `pad2 on` unplug
and replug player 2's virtual pad. Tested on the Two Rivers save: at join
her mode went 0 to 1 and she left; `pad2 off` brought her back with mode 0
and took Blossom away, `pad2 on` the reverse; the bandit cutscene brought
her in and Blossom out, and the reverse after it; an NPC-only overheard conversation and a
villager's one-line bark did not.

While she is out, her HUD panel is hidden: it would show the portrait and
health of a henchman who is not there, and the heroes have no portrait of
their own (only the henchmen's `UI_PH_*` textures exist), so it cannot show
player 2 instead. The panel is lti_curselhench (vtable `0x6faf10`, ctor
`0x5499e0`, update `0x5498f0`), found in CGuiManager's panel list
(`+0x30` count, array at `+0x38`). It is drawn through its parent, so its own
show flag (`+0x49 & 2`) does nothing; its parts are hidden instead. They are
the labels at `+0xd4` (portrait), `+0x2c4` (its back) and `+0x4b4` (dead mark),
the bars at `+0x6a4` and `+0x8d0`, and the label at `+0xafc`. Bit `2` of each
part's flag byte `+0x38` (the base ctor `0x521e70` sets only that byte; the
other three are stale) is cleared on entry to CGuiManager's draw
`0x51e090` and restored on exit, so the game's own update, which sets the
flags each frame (it hides the dead mark that way), never sees the change.
Tested: no panel while player 2 is in, panel back after `pad2 off`; the area
transition test kept 58 of 58 hashes equal.

**Player 2's death** (`native/coop_hero.odin`, v112). Player 2's hero is
not in the party, so its death ends nothing. The control hook tests it each
update as GetIsDead `0x4839b0` does, creature states 8 (the death playing,
3 to 4 s) and 9 (dead) through CCreature_HasState `0x4b81f0`, and drives it
no more meanwhile. Once it is in state 9 and 3 s have passed since it fell
(the update's f32 dt summed, so peers count alike), it is put at the
player's side and `jec_p2_revive.ncs` runs as it: `EffectResurrection` and
full health, chi and focus. A resurrection in state 8 does not take. Tested
on the Two Rivers save with a test script applying `EffectDeath`: Blossom
fell, stood up beside Tan about 4.5 s later with one revive, twice in a row.

**Player 2 keeps up with the player** (`native/coop_hero.odin`, v114). The
setup above runs again whenever what it takes from the player changes: the
control hook hashes the player's maxima and each style entry's id, level and
upgrades every update and compares the hash with the one setup last saw. A
style entry (`[p+0x46c]` array, `[p+0x464]` long) holds the style id at
`+0`, the level at u8 `+5` (1 + upgrades bought, as
CCombatStyles_GetCombatStyleLevel `0x49d3b0` reads it) and the upgrades at
u64 `+0x10`, 12 groups of 5 bits, one choice per level (`0x4ceba0` compares
them group by group). After the styles script, each of the hero's styles the
player knows takes the player's level and upgrades; one the player does not
(the hero's own two) takes those of the player's highest style, mapped
between the two styles' LevelUp 2das (v141). The groups differ by kind of
style (a fist style's damage, chi strike and speed; a magic style's chi
cost, damage and duration; a weapon style's damage, focus and speed), and a
group's kind is the styleadvance.2da `Effect1` (column 3) of its first
choice (72 damage, 84 chi strike, 81 speed, 69 chi cost, 86 duration, 70
focus). Each target group takes the tiers of the first unused source group
with the same effect; tiers left over fill the target's groups in order;
each group is capped at its `choices` (Gimp_MartialLV has one damage group
of 4). Setup loads the tables the way `0x4ced10` does (styles 2da `0x12`
column 4, styledata `LevelUp2DA`, a 0x84-byte C2DA from ctor `0x658b90`
and load `0x659a70`). An entry holding more upgrade bits than the mapping
gives (a save from before v141) keeps its own. Monkeypaw's
`speed_increase` group lists lower_chi_cost rows (effect 69), so it matches
chi cost, not speed. The bits alone do nothing: an upgrade is its row's effects in
styleadvance.2da (rules 2da `0x57`; the style's LevelUp 2da, named in
styledata.2da `0x4d`, gives each group's 5 choices as its rows) put on the
entry's multipliers (`+0x28` damage, `+0x64` speed ...) by
CCreature_ApplyStyleAdvance `0x4cacf0`. So setup flags each entry to change
(`+0xbc` = 1, as a newly added style is) and calls
CCreature_SetUpNewStyles `0x4ced10`, which sets each flagged entry up afresh
(`0x46b510`: level 1, no upgrades, multipliers 1) and applies the upgrades
of a copy of it with CCreature_ApplyStyleUpgrades `0x4ceba0`; the hook on
that gives the copy the upgrades the entry is to have. Tested on Auto 28
(the player level 7, style `0x17` level 9 with upgrades `0x1c1f`): Blossom's
styles `0x34` (LegendaryFistLV, same groups) and `0x17` came out level 9
with `0x1c1f`, style `0` (Gimp_MartialLV) level 5 with `0xf`; net hashes
equal to frame 4620. XP alone changes nothing: a level is
spent at the level-up panel, which then raises the maxima. Tested on the Two
Rivers save with a test script adding a style to the player: Blossom ran
setup again and had 4 styles.

**Foes against two heroes** (`native/coop_foes.odin`, v115). Encounters
are made for one hero and a henchman, and with player 2 in the henchman is
out, so player 2 fights every fight the player does, solo fights included,
and the foes are made harder instead. While player 2's hero is in play,
each creature whose AI update runs (`0x43df70`) and that is the player's
enemy, as GetIsEnemy `0x483420` tells (faction at `+8` in the object's
vtable `+0x7c` part; `0x455f40` thiscall on `[0x76c928]+4` with both
factions), gets twice its health once: the base override (`+0x7b0`
flag, `+0x7b4` value) set to twice CCreature_GetHealthBase `0x4c63b0`,
and max and current health (f32 `+0x478`, `+0x470`) scaled alike. It also
fights one AI tier higher (`foe_tier` in `ai.odin`), still under the
`JE_AI` cap, so `JE_AI=0` keeps the shipped AI. When player 2 leaves, the
overrides come back and the health is divided again, so damage taken keeps
its share. Player 2's hero is also put back at the player's side whenever it
is more than 30 m away, which a script moving the player (an arena, a jump)
does. Tested at 1.5 times on the Two Rivers save: the two bandits went from 25 to 38
health; `pad2 off` mid-fight restored them and `pad2 on` scaled them again;
online, both peers scaled the same foes and the hashes were equal through
frame 4560. With player 2 standing idle, the player died in the bandit fight
that the player survives alone, with the henchman fighting.

**Co-op saves** (`native/coop_hero.odin`, v116). A saved game keeps player
2's hero like any creature made in play: the area's CreatureList holds it
under its object id (CCreature save `0x4cb340`, its template's resref by
CGameObject save `0x4d8840` from `+0xc`), and object ids persist across a
load. So the saved creature itself is the co-op flag, and the port only finds
it instead of spawning a second one. Ids of creatures made in play run up from
0x10008000 (type 2 in the top 5 bits, 0x8000 made in play, index low), and
the world (`[[0x76c924]+0xa0]`) counts them at `+0x3c` (`0x460630`). Each
frame, `Control_Frame_00464aa0` checks that `hero_id` still names an object
whose resref (stored upper case) is `JEC_P2`; when it does not, it scans the
ids up to the count plus 8, once per change of the player object or the
count. The first match becomes `hero_id`, the next are deactivated. Its hero
is the `HEROES` row of its own appearance (`+0x4cc`, -1 for the template's,
`0x408ac0`), which the save keeps too: setup runs SetAppearance (the
generated script `jec_p2_look.ncs`, appearance filled in like the setup
script's styles) whenever the creature has no appearance of its own or
another one, so a respawn from the boot pick's template, or the first spawn,
looks like the hero in play. Both peers load the same save, so the saved hero
wins over the joiner's pick on both. With co-op off, the found hero is
deactivated like a player 2 who left, so it never stands in the game as an
NPC. Area returns work the same: an area left with player 2 in keeps its
copy, found again on return; the copy spawned elsewhere stays in that area,
inactive. Tested on a Two Rivers save: a game saved with Jen Zi loaded with
the Blossom pick found Jen Zi (one hero, no spawn); with co-op off the hero
went out; the online test kept equal hashes to frame 4620.

**Minigames** (v117). Every StartMinigame in the shipped scripts (8 of them:
j01_a_dstar_end1, j00_a_kangmiss1-3, j04_a_hingoom, j07_a_startfly,
je3_een_mgame; all the flying game, args type, return module, return
waypoint) goes through a module load: CAppBase `0x40d9b0` launches it with
`CCampaign_LaunchMiniGame` `0x42cf20` on the freshly loaded module (the
minigame object at module `+0x120`, freed by `0x42a150`), so the area with
player 2's hero is gone with the old module, and with no world player
`Control_Frame_00464aa0` does not run. The game ends by loading the return
module, where `coop_hero_find` finds no `JEC_P2` (the area came from its
file, not a save) and player 2 spawns beside player 1 with full pools; the
henchman stays out. So the port does nothing for
minigames. Tested from a Two Rivers save with a test script running
j01_a_dstar_end1's StartMinigame: flying game with no hero, then the
Dawn Star conversation at the return waypoint, then a fresh hero beside
player 1 and no henchman.

**Script searches** (v118, `native/coop_search.odin`). Scripts that take
the nth nearest creature or act on every creature in a shape (25 shipped
scripts call GetNearestObject or GetNearestObjectToLocation, two walk
GetFirstObjectInShape/GetNextObjectInShape: zmf_a_resurrect,
j02_eud_convictj) were written for a world of player 1 and henchman; with
player 2's hero beside player 1 the nth would shift by one and a shape
script would revive or move it. `nws_GetNearestObject_etc` `0x485e50`
(actions 0xe3 and 0xe4) asks the area for the nth nearest through
`0x4ad720` (thiscall area (^out id, ^pos, type, flags, nth), ret 0x14; nth
counts from 0, the nws adds 1 when the target is itself of the type), from
`0x486027` only. The hook, when called from there, asks for 0..nth; if
the hero turns up among them it asks for nth + 1 instead. Shape walks go
through `0x4ad810` (first) and `0x4ad850` (next), thiscall area (shape,
^box), ret 8, returning the object; the hook steps over the hero when
called from `nws_GetFirstObjectInShape_etc` `0x4863b0` (return addresses
`0x486837`, `0x486845`, `0x486bbc`). Engine searches (sound sets,
`CTrigger_GetIsHenchmanData`, the AI) and the other 10 callers of the shape
walk still see the hero. Tested from the Two Rivers save with test
scripts: nearest creature to player 1 is the hero with the hook off, never
with it on (nth 0-2); a 40-step shape walk around player 1 finds it once
off, never on, one object fewer.

**Triggers** (v119, `native/coop_search.odin`). 580 shipped scripts read
GetEnteringObject or GetFirstInObject. Most gate on GetIsPC
(`0x483f30` tests vtable `+0x28`, so the hero, a plain creature, is never a
PC), but about 22 act on whatever enters: j03_abt_bwintro plays a movie,
j08_een_jump1/2 jump it, j04_a_cho_start starts a cutscene, j03_een_combo01-03
damage it, jde_e_combat02 adds it to the combat area. `CTrigger_EventHandler`
`0x4fd870` is a thiscall on the trigger (kind, ?, event by value {tag,
data}); kind 1 (`[0x6e148c]`) is a script event whose data has the type u16
at +0 (0xc enter, 0xd exit) and the objects at +0x28 (count) and +0x30
(array; `0x478a00` fetches one), the first the creature entering or
leaving. On enter it stores the id at trigger `+0x188` (GetEnteringObject
`0x483530` reads it), runs the area transition (`0x45eb40`, `0x4fb5b0`), the
trap (`0x4fa950`, `0x4fae20`) and the OnEnter script; exit runs script slot
2. A kind the handler does not know only frees the event, so the hook, when
the event is the hero entering or leaving, passes kind -1. The hero then
springs no trap and takes no area transition, which is the leader-decides
rule for free. GetFirstInObject/GetNextInObject (`0x484e20`, actions 262
and 263) walk the same area shape as GetFirstObjectInShape, then test the
point against the trigger's polygon (`0x4fe440`, trigger `+0x198`); its
return addresses `0x484ee2`, `0x484ef0`, `0x484f96` join the shape hook's
list. Tested from the Two Rivers save: walking the hero through
j01t_bfarmer and j01t_bscout posted its enter events and the hook dropped
each (player 1's still ran); a test script counting the hero among
GetFirstInObject of j01t_bfarmer gave 1 of 16 objects before the addresses
were added, 0 of 15 after.

**Each player's camera online** (`native/coop_camera.odin`, v123). Each
peer shows its own player's view; nothing about the two views has to match.
What play reads from a camera does: player 2's stick moves the hero against
player 2's camera, so both peers keep that camera from lockstep input only,
and the hero's control update and dodge run with it on the game's camera.
It is player 1's camera at its offset from the look point, turned to a yaw
of its own round player 2's hero (the second pad's right stick turns it;
while the hero moves and the stick rests it eases back behind the hero, as
the free camera does) and pulled in by the game's collision; its pitch is
player 1's.

Drawing is not free of side effects: it allocates (the heap's blocks then
sit at different places on the two peers), moves fades, particles and ropes
on, and fills caches, all by what the view sees. A first version had the
joiner simply draw from player 2's camera, and needed the view globals,
helpers' result buffers, the lights' cached colour at `+0x250` and
Emitter_Update's quad buffer left out of the desync hash; then a heap
allocation pattern diverged at frame 2520 and holes could not keep up. Now
both peers draw the frame's view twice, the same way:

- A view is the camera's tick (`0x5df230`, thiscall(phase), the object at
  `[[APP+0xa0]+0x124]`) phase 1, which runs inside the update
  (`0x40cc96`) and draws the first half of the scene (vt+0x24 phase 1:
  `0x178`, `0x188`, `0x18c`), phase 2 after the update (`0x4a4917`, the
  rest: `0x188`, `0x190`, `0x5c`, `0x17c`), the GUI's root clip rect
  (`0x5da240`) and CGuiManager's draw (`0x51e090`), which draws the
  world's labels and overlays as well as the GUI.
- Pass A runs where the game runs it, from the game's camera. Pass B runs
  after pass A's GUI draw (the GUI hook calls phases 1 and 2, the root and
  the GUI draw again), with player 2's pose put on the game's camera.
  Without a GUI draw that frame, phase 2's hook runs pass B.
- The host shows pass A and the joiner pass B. The other pass runs under
  `win32.null_render`: DrawPrimitive and its three siblings, Clear,
  StretchRect and the bloom pass check their arguments and return as usual
  but draw nothing. The device has no readback the guest could see
  (CreateQuery, GetRenderTargetData and GetFrontBufferData are absent), so a
  null pass leaves the game as a drawn one does.
- The frame's time (`0x75ecd0`, f32, set by MainLoop, read by the draws
  and pushed as CGuiManager's argument) is halved for each pass and put
  back after pass B, so what draws move on moves on once per frame.
- Object_BoxZGap's depth from the camera sets an object's level of detail,
  which decides how its animation runs; `native/zgap.odin` lends it the
  game's pose during pass B (`coop_cam_lend`), so animation follows player
  1's camera as in a solo game.

The hash has no holes again. Tested headless (nettest, frame-exact input
scripts, load, walk and bandit fight with player 2 attacking and turning player 2's
camera): 77 hashes equal through frame 4600, the two screens differ, each
complete. A solo run is unchanged (the hooks pass straight through when
not online). Online the scene costs its draw CPU twice.

**Player 2's camera clip** (v126). Two things put player 2's view inside
walls. First, the offset was taken from the camera's shown pose, but out
of combat that is the free camera's (`camera.odin`), which pulls its pose
in by collision and puts the clip's flags (`+0xe8`, `+0xec`) back, so the
flags read "unclipped" while the pose was pulled in, and the offset was
recaptured short (0.34 against a rest distance of 4 at `+0x94`). The
offset now comes from the game's own pose (`cam_game_pose`: the guest's
pose the free camera replaced while it shows its own, else the camera's).
Second, in a fight the exploration behaviour's update (`0x420f60`) stops:
combat's camera (`CBehaviorCombatCamera`, vtable 0x6e3230, update slot 2
`0x418580`) has the view, so the exploration behaviour, which the clip had
run on, was stale and player 2's camera went unclipped all fight. The clip
(`0x420730`) reads only the target (`+0x38`), the camera interface
(`+0x3c`), the look point (`+0x48`) and its flags, and its ray test
(`0x420330`) is against the whole area, so it now runs on a block of the
port's own (0xa00500, 0xf0 bytes, zeroed each frame) holding player 2's
look point, whichever behaviour has the view. While combat's camera has
it, the offset is held. Tested headless: net hashes equal through 4600
and through a wall walk to 3000; in the fight and walking backwards into
a wall the view stays out of geometry.

**Player 2's fight framing** (v127). Combat's camera frames player 1's
fight: `CBehaviorCombatCamera` (0x110 bytes, ctor `0x417260`, made in the
player creature's behaviour switch near `0x4e8e47`) holds two object ids at
`+0x38`/`+0x3c` (resolved by `0x461950`), and its body `0x417de0` takes a
framing box from its helper at `+0xc4` (`0x417620`: point A at `+0`, point
B at `+0x24`), centres on A + (B - A) / 2, fits the distance to the FOV,
places the camera behind the player along its facing and eases it with
`0x41e990` springs. None of it can serve player 2: player 2's hero never
enters combat stance (`+0x588` stays 0) and never has a target (`+0x58c` is
the invalid id) in player 1's fight. So the port frames natively. Each AI
update of a foe the co-op scaling knows (`coop_foes.odin`) offers it to
`coop_cam_foe`, which keeps the nearest live one within 12 m of player 2's
hero, double-buffered by frame so the camera reads a whole frame's choice.
While player 1 is in combat stance and a foe is chosen, player 2's camera
eases (rate 3/s) its look point halfway to the foe and lengthens its offset
by half their distance over the offset's length (scale capped at 2), and
with the stick at rest for the recentre wait its yaw eases (rate 2/s) to
look past the hero at the foe. Out of the fight both ease back to the plain
offset. Tested headless (nettest10, the joiner closing on a bandit and
attacking): net hashes equal through 4600; the yaw follows the foe within a
few hundredths of a radian once settled, scale about 1.3, hero centred with
the foe beyond.

**Player 2's ears** (v134). The joiner shows player 2's camera but heard
the game's. CExoSound's update (`0x66f940`, from MainLoop `0x4a4b85`, with
the camera interface) puts the listener about 1.9 m ahead of the game's
camera (position through `0x669560`, stored at `+0x268` and sent only when
it changes; orientation through the routine ending `0x66955b`), and picks
the reverb environment from the area's environment triggers by that point.
Running it again from player 2's camera would change guest state the two
peers must share, so the guest's listener stays the game's and only the
mixer moves. Each frame (scene tick phase 2) the joiner hands
`win32.ds_view` the rigid motion from the game's camera to player 2's: the
rotation `q2 * conj(qgame)` as a matrix, and the two positions. Each mixed
chunk carries the guest's listener by it (`ds_ear`: position
`rot * (pos - from) + to`, front and top rotated) and pans and attenuates
3D sources against that. Gains move no play cursor, so the games stay the
same; the reverb environment stays the game's (until v137). The host's mixer is
unchanged. Tested headless: on the joiner the carried listener sat at the
same 1.9 m ahead of player 2's camera with player 2's heading, the host
logged none, and the area transition test kept 58 of 58 hashes equal.

**Player 2's reverb** (v137). With the I3DL2 reverb running (docs/hle.md
§12), the joiner heard player 1's sound environment. Each frame the joiner
picks the environment the game's update would pick at player 2's hero
(`p2_reverb` in `coop_camera.odin`): the same sound shapes, the same point
1.8 m over its feet, the same area table and reverb table. The result goes to
`win32.ds_view.reverb`, and every buffer with the effect sends to the bus for
those parameters instead of its own. Outside any environment, or with
environments off, it uses the default preset, as a buffer that was never set
does. The guest calls only read state, so the peers stay the same: the
lockstep area test kept 58 of 58 hashes equal, and the joiner picked Two
Rivers' FOREST environment (lRoom -830, decay 1.49 s).

**Conversations and cutscenes online** (v138). These needed no new code.
Player 1 picks and player 2 watches. Under lockstep the game reads only
`pad_in[0]`, which is the host's pad on both peers, and `pump` drops the
joiner's keyboard and mouse (docs/hle.md §11). The joiner's presses reach only
player 2's hero, and that hero is out during dialogue, as in couch co-op. The
joiner draws the game's conversation cameras because pass A is the game's
frame. Bink movies play on the virtual clock, and every net test starts
through the startup movies. The test is `nettest19`: from the School Gate
quick save, the host walks forward (`Pad.-lefty`, a negative axis in
`JE_INPUT_SCRIPT`) into the bandit conversation trigger. The conversation
plays on both peers with the same speaker shots and lines. Player 2 is away
for it and back after it, and then joins the bandit fight. All 67 of 67
hashes were equal through frame 4020. In a second run only the joiner pressed
A. This conversation advances by itself, so that run checked only the hashes,
which stayed equal (50 of 50).
A conversation with choices was tested with Student Si Pat (Auto 32, Two
Rivers). The host walks to him with the left stick, steered closed loop on
`peek`ed positions of the player and of Si Pat (ctl `exec` would run a script
on one peer only and desyncs), and A starts the talk. At his first menu
("Could I ask you some questions?" / "Goodbye.") the joiner pressed d-pad down
and A. Neither peer's menu moved, and the talk went on. The host's A then took
the first reply, and both peers showed Si Pat's answer and his next menu. All
43 of 43 hashes were equal.

**Player 2's stance, target and blows** (v128). In player 1's fight player
2's hero now fights as the player does. Each control update
(`coop_fight` in `coop_foes.odin`, before the camera) puts it in combat
stance while player 1 is (vt+0x114 (on), flag at `+0x588`) and targets the
nearest live foe of the last whole frame of AI updates within 12 m
(`0x46ff70` on `+0x58c`); out of the fight it clears both. The target
upkeep `0x4709c0`, which makes a non-player creature drop a target that is
not fighting it back and pick its own, is hooked to leave player 2's hero
alone. The camera framing (v127) now reads that target. Even so its blows
never landed, for two reasons. First, contacts (game_map.md "Blows and
contacts") are added unarmed and armed only by the attacker's "HitOn" anim
event, whose handler the area set-up registers on each creature's model
(`0x4cf410` from `0x4cf500`); player 2's hero is spawned after that, and
its model is rebuilt again when it first enters the fight, so nothing armed
its slots. Second, its model had no moves of its style until a d-pad style
switch: a style switch reaches the anims only in combat stance (`0x4bd646`)
and does nothing for the style in use (`0x4bd594`). So `coop_hero`, on each
new model while in combat stance, calls `0x4cf410` on the hero, marks
another of its styles as in use (`+0x584`) and switches back to the one it
had. Tested headless (nettest15, the joiner attacking with no style
switch): HitOn fires for player 2's hero, foes lose health to its blows
(one killed after a d-pad switch to slot 0's style; Heavenly Wave
does no damage, being a support style), and net hashes stay equal through
4600.

**Player 2's attack feel** (v129). Player 2's hero now gets what the
player's swings get. Combat pace and hit stop (`pace.odin`) keep one swing
per hero: the m-anim speed-up applies to player 2's hero too, and a foe hit
reaction while a hero's swing is live, on the foe that hero targets, slows
the clock (under lockstep `host_now` is the virtual clock, so the slow is
the same on both peers). Attack magnetism (`magnet.odin`) keeps one slide
per hero, player 2's on the foe `coop_fight` gave it, matched in the move
collision by the mover's position. Player 2's pushed attacks no longer pile
up: an attack entry on the AI stack is `{type = style move index, sub 5,
param 1}`, and the update's sub 5 case (`0x43e22e`) waits while the anim
component is busy (`0x43fa50`), turns to the target (`0x438210`), then the
executor (`0x43e280`, sub 5 at `0x43e6d8`) gates on `0x437de0` and plays
the move through `0x44b3b0` on `[[0x76c924]+0xac]+0xc`. Presses during a
combo stacked up to the stack's 10 (the update drops the oldest past that,
`0x4390f0`) and replayed late. `coop_act` now drops the stack's attack
entries before each push and once a press has waited `BUFFER_SEC` (0.35 s
of `host_now`), as the player's buffer does. Player 2's target is kept
while alive and within 12 m; the pick weighs each foe's squared distance by
the angle off player 2's aim (the second pad's stick against player 2's
camera, else the hero's facing) with target.odin's factor, and another foe
takes over only under half the target's weighted value. Tested headless
(nettest15, A every 15 frames, the joiner standing still): the chain plays
at a steady 25 frames, no stale presses replay, the foe's 50 health fell to
18 and to 43 in two runs (35 before; runs vary with timing), and hashes
stay equal; opening swings from more
than 2 m still miss with the joiner not walking in, as magnetism's reach is
1.5 m at no mastery. `+0x664` is not a factor: it indexes the scripted
style-move list (`[[0x76c924]+0xac]+0x14`; get `0x451ad0`, remove
`0x451bf0`, add `0x451ce0`), whose moves alone get the contact pass's 1.0
slack (`0x447410`).

**Player 2's HUD** (`native/coop_hud.odin`). Pass B's GUI draw shows player
2's bars and style cross. CGuiManager's draw walks its panels (count at
`[mgr+0x30]`, array at `[mgr+0x38]`) and calls each panel's vt+0x40, vt+0x2c
(dt) and vt+0x30. The panels read the player through GetPlayer `0x424700`
(thiscall on `[[APP]+0xa0]`). Two of them keep state between frames: the
bars (lti_fltingcombat, vtable `0x6ffe10`, ctor `0x57da90`, update
`0x57e0f0` through `0x57d780`, health at `+0xb20`, focus at `+0x11a4`) flash
a value that dropped, and the style cross (lti_floatstyle, vtable
`0x6fa7d0`, ctor `0x5425c0`) holds the slot and name label it was last told.
So pass B swaps in a twin of each, made once by operator new `0x6b27aa` and
the panel's ctor under the game panel's parent (`+0x28`), with the game
panel's shown flags (`+0x48`) copied in each pass. The game's own panels
keep player 1's. A load makes the game's panels again, and with them new
twins. The old twin is deleted through its vtable slot 0 (`0x57dfd0` /
`0x543420`, with 1). Its base delete `0x51e490` looks itself up in its
parent's children (`0x51cc70`) to unlink, and that parent may be freed by the
load. The twin was never one of those children, so its `+0x28` is zeroed
first. Its member parts belong to the twin itself (`0x51d3d0`). Verified over
two loads: each new twin reused the old twin's address, and all 58 lockstep
hashes were equal (v136).

GetPlayer is hooked to return a stand-in while pass B's GUI draws. Player
2's hero is a plain CCreature (0x7e8 bytes, as `0x45ed90` makes one); the
player is a CPlayerCreature (0x12f0 bytes, `0x45edeb`), whose tail holds the
control (`+0x7ec`), the ten style quick slots (`+0x810`, style id or -1),
the henchmen and a flag the bars read (`+0x1230`). Handing the panels the
hero crashed them: the slot refresh `0x541ba0` read `+0x810` past the
hero's end, looked the value up with `0x4eb690` (which returns -1 for a
style the creature lacks) and asserted at exobase.h line 1835. The
stand-in is one CPlayerCreature-sized buffer, rebuilt each pass: the
hero's 0x7e8 bytes, player 1's tail, player 1's vtable and player 2's
styles in the quick slots (entries with the sign bit skipped). What the
panels write to it is dropped.
The stand-in covers all of pass B's GUI draw, not only the twins. A census
of GetPlayer's callers there, over a conversation and a fight on both peers,
found only these: the style cross (`0x540cb0` through `0x543030`), the bars
(`0x57d780`, `0x57d890`, `0x57e0f0`), the area map (`0x515140`, reached
through CPanelMain), which so centres on player 2, and the henchman panel
(`0x549760`), which is hidden while player 2 is in. All of them should show
player 2, so the stand-in is not narrowed to the twins' draws; narrowing it
would put player 1 on the joiner's map.
Checked with the peers about 20 m apart in j01_town (the host walked player
1 from Si Pat to the scroll stand): the host's map centres on player 1, the
joiner's on player 2, with player 2's follower star under the joiner's arrow.

**Player 2's style switching** (`native/coop_style.odin`). The game's d-pad
style switch lives on the style cross panel: the input dispatcher
`0x448fc0` maps actions 0x14..0x18 to the panel's vt+0x60, +0x58, (keyboard),
+0x54, +0x5c, which pick quick slot 3, 0, 1, 2 for d-pad down, left, right,
up. Each calls SelectSlot (vt+0x74, `0x542440`): out of combat (player
`+0x588` zero) it only highlights the slot; in combat it waits 0.5 s between
switches (`[panel+0x1838]`), takes the slot's style from player `+0x810`,
asks player vt+0x138 (style, 1), gives up under state 0x54, and `0x540c20`
then calls vt+0x128 (style, 0, 1, `0x4bd4f0`) unless state 0x1d or 0x36.
All of it acts on the game's player, so player 2's d-pad does the same on
player 2's hero from player 2's control update: a newly pressed direction,
in player 1's fight, switches the hero to that slot's style, the slots
being those its HUD shows. The HUD twin follows through the style change
call above. A press in a frame where player 2's control update does not
run (cutscene, conversation, player 2 dead) is lost, as the game's is.

The cross learns of a style change through its vt+0x6c (`0x543030`,
thiscall(style id, 1)), which SetCurrentStyle `0x4bd720` calls for the
player only. It picks the slot and shows the style's name through
`0x540f70`, which fades the label in and out over 5 s. A twin never told
showed the label's box empty. Pass B now calls `0x543030` on the twin
whenever the hero's style in use (`+0x584`, an index into the style list at
`+0x46c`) gives a new id. Tested headless (nettest, 75 hashes equal to
4500): the joiner shows player 2's full bars, styles and "Thousand Cuts",
the host player 1's.

**D-pad menus** (`native/dpad.odin`). GetGUIInput `0x667420` rebuilds each
port's pad through CXbInput `0x6678e0` with a2 1 (gameplay reads pass 0),
then, for each of 44 pad inputs, looks up a GUI slot in the table at
CXbInput+0xd6b8 (`[[0x76c924]+0xdc]`, filled by the stores near `0x40d83c`)
and its mode at +0xd768. The inputs are `0x665c80`'s: 0..3 the d-pad bits
(up 1, down 2, left 4, right 8, mode 1), 0x10..0x13 the stick i16s left X,
left Y, right X, right Y (slots 15, 27, 16, 28, mode 2). The d-pad entries
are -1, so menus ignore it. On a2 1 calls the CXbInput hook writes a held
d-pad direction into the left stick, ±32767 on that axis (Y up positive),
in the pad at `this` and in the previous call's copy at `this+0x1c`, which
the GUI compares against; the GUI's own stick repeat then moves the
selection. Tested on the main menu (one row per tap, up and down) and the
audio sliders (left and right).

## §11 Settings menu

The port's tunables are rows of the game's Video Settings panel
(CPanelCustomVideo), below its nine, and the pad and combat settings (TURN through P2_HERO)
rows of its Control panel (CPanelOptionsCont), below its five
(`native/settings.odin`, v59, split in v60). `Setting_Id` lists the Video
settings first; `CONTROL_FIRST` starts the Control ones. Each
setting has an ini key in `JadeEmpire.ini` section `[Port]`, a label, a
one-line description, its values and a default. At startup, before boot,
`settings_load` reads the ini, then `JE_<key>` from the environment, which
wins; an online joiner then takes the host's value of every setting outside
`SETTINGS_LOOK` but `P2_HERO` (`settings_sync`, hle.md §11), and
`settings_boot` puts every value in force.

| Key | Row | Values | Default | Applies |
|---|---|---|---|---|
| FPS | Frame Rate | 30, 60, 90, 120, 144, 165, 240, 0 (unlimited) | 30 | 30 keeps the game's `ClampFPS`, read once at boot, so moving to or from 30 needs a restart; other rates change live |
| MENU_FPS | Menu Frame Rate | 30, 60, 120, 0 (same as game) | 60 | live |
| SCALE | Render Scale | 0 (auto), 1–4 | 0 | restart |
| SMAA | SMAA | 0, 1 | 1 | live |
| SHARPEN | Sharpening | 0 (off), 1–3 (low, medium, high) | 1 | live (docs/rendering.md §14) |
| VIBRANCE | Vibrance | 0 (off), 1–3 | 0 | live (docs/rendering.md §14) |
| SSAO | Ambient Occlusion | 0 (off), 1–3 (low, medium, high) | 2 | live (docs/rendering.md §15) |
| DRAW | Draw Distance | 100 (original), 150, 200, 300 (percent of the area's distances) | 200 | live (docs/rendering.md §16) |
| SOFT | Soft Particles | 0, 1 | 1 | live (docs/rendering.md §10) |
| BLOOM | Bloom | 0, 1 | 1 | live (docs/rendering.md §11) |
| SHADOW | Shadow Maps | 0, 1 | 1 | live (docs/rendering.md §12) |
| ANISO | Anisotropic Filtering | 1 (off), 2, 4, 8, 16 | 16 | live |
| FULLSCREEN | Fullscreen | 0, 1 | 0 | live; Alt+Enter changes it too |
| INTRO | Intro Movies | 0, 1 | 0 | restart (0 overrides `[Render] NoLogos=1`) |
| REVERB | Reverb | 0 (off), 1 (low, -6 dB), 2 (original), 3 (high, +6 dB) | 2 | live; the wet level; 0 stops the sends, so no bus rings (docs/hle.md §12) |
| BLEND | Animation Blending | 0, 1 | 1 | live (§10) |
| BLEND_MS | Blend Time | 60–250 ms | 120 | live |
| TURN | Turn to Run | 0, 1 | 1 | live (§10) |
| STICK_DZ | Stick Deadzone | -1 (original), 0–30 % | 12 | live (docs/hle.md §5) |
| FLICK | Target Flick | 0, 1 | 1 | live (§10) |
| CAMERA | Free Camera | 0, 1 | 1 | live (§10) |
| AIM | Aimed Targeting | 0, 1 | 1 | live (§10) |
| BUFFER | Input Buffer | 0, 1 | 1 | live (§10) |
| AI | Enemy AI | 0 Original, 1 Skilled (rank tiers capped at 3), 2 Master (rank tiers) | 2 | live (§10) |
| PARRY | Parry | 0, 1 | 1 | live (§10) |
| PACE | Combat Pace | 0 Original, 1 Quick, 2 Fast | 1 | live (§10) |
| HIT_STOP | Hit Stop | 0, 1 | 1 | live (§10) |
| MAGNET | Attack Magnetism | 0, 1 | 1 | live (§10) |
| COOP | Co-op | 0, 1 | 0 | live (§10) |
| P2_HERO | Player 2's Hero | 0 Blossom, 1 Ming, 2 Shen, 3 Jen Zi, 4 Ling, 5 Prodigy, 6 Tan | 0 | live alone; online at the next join (§10) |

- Text. The labels and descriptions are appended to `dialog.tlk` as it is
  loaded (`win32/tlk.odin`, `tlk_extra`): the string table grows by one
  entry per string, the data offsets move up by the inserted bytes, and
  `tlk_base` is the first new strref. Setting i has its label at
  `tlk_base + 2i` and its description at `+ 2i + 1`. The help bar holds one
  line, about 70 characters.
- Rows. The ctor hook `0x54e890` copies the game's nine strrefs to
  `0xa00000` and the port's labels after them (§9), so the game builds 27
  rows, then writes each port row's value text. The value widget of a row
  is `0x54d810` (thiscall(row)); the text is set through `0x529280` on
  widget+0x28c with a CExoString built on scratch stack below `esp`.
- Left and right (`0x54db10`, `0x54dee0`, thiscall(control, dir)) run the
  game's body, then, on a port row, step the pending value along its list,
  stopping at the ends. The selected row is the label list's selection
  (i16 +0x51e, item `0x521bd0`, row `0x54d4a0`).
- Selection (`0x54e2a0`) sets the help bar to the row's description
  (`0x560520` on the manager's help area); the Accept, Cancel and Default
  buttons (this+0x1144, +0x1408, +0x16cc) keep the game's text.
- Default (`0x54d880`) sets every pending value to its default. Cancel drops
  the pending values; the next open starts from the values in force.
- Accept (`0x54d570`) puts each changed value in force, writes every key to
  `[Port]` through `ini_write` (`win32/ini.odin`), then runs the game's own
  apply.
- Control panel. The ctor hook `0x573a10` copies the game's five 16-byte
  rows to `0xa00100` and its five description strrefs to `0xa00280`, then
  the port's: label strref with default, min and max 0 (only the strref is
  read for them), and the description strref; the game shows descriptions
  in its two-line box, so no help bar change. The game gives rows past five
  an empty value; the hook sets the text on the value list (this+0x2c4)
  item's widget (vcall +0x40), text at +0x1b8. Left and right (`0x570390`,
  `0x5704c0`, thiscall(?, -1 or 1, or `0x75b528` for an arrow click)) step
  a port row when the label list (this+0x810) has focus (this+0x2c) and
  its selection (i16 this+0xd2e) is 5 to 7; the game's body blanks the
  value first. Default (`0x570650`) and Accept (`0x570050`) act on argument
  1 or `0x75b528`, like the game's; Accept writes every key, as on Video.
- The hooks are §10 behavior hooks: outside the bit-exact contract, the
  generator rerun needed when one is added.

Check run (v59): 33.5 M calls, no mismatches. Playtest: values step, the
help bar shows each description, Accept writes `[Port]`, Cancel keeps the
ini unchanged, Default resets Frame Rate from 90 to 30.

Check run (v60): 33.5 M calls, no mismatches. Playtest: the Control panel
scrolls to its eight rows with values and descriptions, steps them, Accept
writes `STICK_DZ` and `FLICK`, a reopen shows them, Default resets them;
the Video panel ends at Blend Time, row 19.

Playtest (v139): the Reverb row sits after Intro Movies, steps Off, Low,
Original and High with its description in the help bar, and Animation Blending and Blend Time
still follow it.

**Main menu online rows** (v147, `native/menu_online.odin`). The title
menu's Singleplayer and Online submenus (v150) and their Host, Join and
Leave Online Game rows are five more §10 behavior hooks (row list
`0x56acd0`, activate `0x56a570`, focus `0x56a020`, B `0x569f60`, frame
`0x569d50`); what they do is docs/hle.md §11. Two `[Port]` keys go with
them and have no settings row: `NET_PORT`, the port a menu host listens on
(default 47000), and `NET_JOIN`, the last address joined, written by the
Join row. `[Port]` is left out of the ini hash online peers compare, so
neither stops a join.
