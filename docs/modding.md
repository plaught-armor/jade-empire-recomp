# Modding and automation reference

What the port and its tools know about Jade Empire's data, script VM and
engine behaviour, recorded so mods and test automation build on facts rather
than guesses. Addresses are guest addresses in `JadeEmpire.exe` (GOG, or
the unpacked Steam exe: the same code). xoreos (<https://github.com/xoreos/xoreos>) is a useful
starting point but incomplete for Jade Empire and wrong in places: every
claim below was checked against the binary or the running game, and where
xoreos disagreed that is noted.

Tools named here live in `tools/` and run with `python3 -I`.

## §1 Resources

**Lookup order.** A file in `override/` with the same `resref.ext` replaces
the archive copy. `override/` is indexed **once at startup**: a file added
while the game runs is not seen until a restart, but a file that was present
at startup is re-read from disk each time the engine opens it (the script
slots of §3 depend on this).

**Archives.**

- `chitin.key` (KEY V1) indexes only `data/artcreatures.bif` (models, textures),
  `data/audio.bif` and `data/designer.bif` (7865 compiled scripts). It holds
  **no 2DA tables**.
- `data/*.rim` (RIM V1.0, `tools/rim`; every Odin tool under `tools/` builds with
  `tools/build.sh` into `port/build/<tool>`) hold everything else. Area RIMs come
  in pairs: `j01_town.rim`-style module data (scripts, creatures, dialogs,
  triggers) and `a010-a.rim`-style geometry and textures.
- 2DA tables: `data/miniglobal-a.rim` holds 350 global tables (appearance,
  animations, styles, items…); `data/globalunload-a.rim` holds each combat
  style's `…AS` (attack animations) and `…MV` (moves) tables.

**Resource type ids** differ from KotOR's; named from each type's file magic:
2002 mdl, 2010 ncs, 2017 2da, 2026 cre, 2029 dlg, 2031 trg, 2043 pla,
2053 pwk, 3000 lyt, 3001 vis, 3012 qst, 3013 sto, 3015 hex, 3016 mdx,
3017 tpc, 3022 fsm, 3023 scn. 3011 (5516 entries) is unidentified; its
resrefs are numbers, like the loose `.mab` files in `override/`.

**Textures.** Archive textures are type 3017; the loose `override/*.txb`
files have the same layout. A 128-byte header: u32 data size, f32 (alpha
test), u16 width, u16 height, u8 format, u8 mip count, two unknown u8 and
an unknown f32, then zeros; the mips follow, largest first, and after them
some files carry their TXI text (`clamp 3`, ...). Formats: 10 DXT1, 12 DXT5,
9 one byte per pixel (mostly masks), 4 and 2 rare. 705 of the 805 override
`.txb` files replace an archive texture of the same name, 653 of them at 2x
to 8x its size (Special Edition repaints, mostly item icons, UI and level
textures). The engine opens every override texture at startup.

**HD textures.** The port lays `textures_hd/` over `override/`
(`win32/tex_hd.odin`; the HD Textures row on the Video panel, `[Port] HDTEX`
or `JE_HDTEX=0` turns it off, after a restart): its files are listed as
override entries and win over an override file of the same name.
`tools/dump_tex` dumps every texture (type 3017 TPCs in `chitin.key`'s
BIFs and in `data/**/*.rim`, then `override/` `.txb` files, same layout,
over the same names: 7597) and `tools/upscale_tex.py` writes them: x4, two new mips, then the
original's mip chain unchanged. Colour textures go through
4x-PBRify_UpscalerV4, back-projected once: the bicubic x4 of the residual
between the original and the model's box /4 shrink is added back, which
keeps the original's colours and structure (box-shrunk PSNR about 22 dB raw,
31 dB after) and keeps the model's detail. Where the raw model output
shrinks back under 28 dB it changed what the texture shows (noisy rock
becomes painterly), and the texture gets a plain bicubic x4 instead; so do
masks and fx sprites, into which a photo model draws texture. Fine-tuning
the model on the game's own textures (DXT1 of a box /4 shrink back to the
original, plus a box-shrunk consistency loss) raised the PSNR numbers but
looked worse: etched, crunchy grit, and at full-size consistency a
screen-door grid. The stock model is used. Alpha is a mask and gets a bicubic x4
clipped to the original alpha's range: through the model it rang below
the original (`l010_bark02`'s authored 240 edge frame fell to 159-213),
which drew lines along every UV wrap of the bark up close.

Formats besides DXT1 and DXT5 are raw and in Xbox swizzled (Morton) order:
x and y bits interleaved from bit 0, x first, the longer side's spare bits
on top. Format 9 is 8-bit grey (masks, ghost opacity, caustics) and gets a
bicubic x4. Normal maps (TXI `isbumpmap`) are 32-bit BGRA despite format
byte 12 (the size field gives them away). A photo model would invent bumps,
so they get a bicubic x4 of the vectors, direction and length interpolated
apart (lengths under 1 are authored and darken the DOT3 lighting). A
flipbook (TXI `numx` x `numy`: water, effects, crowds, UI strips) is stored
as one texture per frame, each with its own mip chain, padded to 128 bytes,
and is upscaled frame by frame. Skipped, so the game keeps the original:
lightmaps and 3D textures (TXI `islightmap`, `m_bis3dtexture`), format 2
and 4 (lightmaps; 32-bit cube maps with each face padded to 128 bytes; one
loading screen), and textures whose size is not the chain their header and
TXI describe (the 32-bit `ui_leftu`/`ui_rightu` strips).

**Generated resources.** The port can also lay files it writes itself over
`override/` (`win32/res_gen.odin`, `res_gen_set(name, bytes)` before boot):
they are listed as override entries, and each open of one gets an unlinked
temporary file holding the bytes as they are at that moment, so a file can
change between opens like a real override file (§3). Co-op uses it for
player 2's creature template `jec_p2.cre` and its scripts `jec_p2_spawn.ncs`
and `jec_p2_setup.ncs` (`native/coop_hero.odin`). A creature template is
cached per resref after its first load, so the hero is chosen before boot.

**2DA.** Archive copies are binary `2DA V2.b`; patched copies in `override/`
are text `2DA V2.0`. `tools/twoda` reads both (`dump FILE [COLUMN…]`) and
resolves a table as the engine does (`game_table`: override first, then the
two RIMs). Binary layout: magic `2DA V2.b\n`; column names, each
tab-terminated, ended by a NUL; u32 row count; row labels, each
tab-terminated; u16 cell offsets, rows × columns; u16 string-pool size; the
pool of NUL-terminated strings. The reader asserts every offset lies inside
the pool and the pool ends the file, and all 443 shipped tables pass.

## §2 NWScript

**Compiled scripts** (`.ncs`) are KotOR-style bytecode. `tools/ncs`
assembles a small expression language into `.ncs` and disassembles. Type
codes on the VM stack: Int 3, Float 4, String 5, Object 6. The Jade Empire VM
is **int-only on return**: the control channel reports the return cell's
type and value, so queries return ints (`FloatToInt(x * 1000.0)` for floats).
Returning an Object yields type 0 and no value. An object's id is read by
decoding `ObjectToString(o)`, eight lower-case hex digits, inside the script:
the sum over k of `FindSubString("0123456789abcdef", GetSubString(s, k, 1))`
× 16^(7−k), masked to 32 bits (`jeplay.id_expr`). Example ids: player
0x295a0000, Two Rivers lieutenant 0x115a000e. A String returns type 0 as
well. `jeplay query` reads one with the same trick, one character per
query: `GetStringLength(s)`, then each character's index in printable ASCII
(`jeplay.query_str`, 16 characters per frame, at most 256). A character
outside printable ASCII reads as `?`.

**Script sources.** `override/` ships some `.nss` sources beside their
`.ncs`, including the shared includes: `j00_i_rewards.nss` (plot rewards),
`j00_i_reward_rt.nss` (random treasure), `j00_i_placeable.nss` (containers).
Read these before disassembling; area scripts in the RIMs have no source.

**Engine functions.** `re/nwscript_functions.tsv` lists id, name, return and
parameter types and trailing defaults; the table came from xoreos and every id
was checked against calls in shipped `override/*.ncs`. `tools/cmdtable`
recovers the action id → handler address table from the binary
(`re/nwscript_handlers.tsv`). Ids with no handler exist in the table: a script
calling one fails at run time.

**Known function behaviour** that differs from the names:

- `GetIsEnemy(a, b)` returns the reputation value (0x483420), not a bool: at or
  below 10 is hostile.
- `GetCurrentAction(foe)` reads 0 during combat, and `Cutscene_GetObjectAnim`
  reads 0 outside cutscene animations. Neither shows what a foe is doing, so
  use the `anims` control command (§5). `Cutscene_GetObjectAnim` (handler
  0x499520) compares the animations the object's model is playing against a
  per-model list kept at 0x76ac60 (0x406960, 0x406880). The cutscene manager
  at `[0x76c924]+0xeba0` fills that list, and a model with no entry gets an
  empty one. It returns the matching entry's id, or 0 when nothing matches.
  This is the engine's behaviour, not a port bug: an idle or fighting
  creature reads 0.
- `SetFacing` (0x493e40) has no visible effect on the player.
- `GetItemCount(o, item)` returns -1 when `o` holds none of `item` (an
  `items.2da` row) and the count otherwise (1 for one plot item). Scripts test
  it with `> 0`.
- `GetIsOpen` on a placeable whose model was unloaded crashes the original
  engine (see "Destroyed placeables" in §4).
- The engine's debug logger (0x654070) is stripped: `PrintString` and friends
  print nothing.

## §3 Control channel and script slots

The port opens a control channel (`port/src/win32/control.odin`); `tools/jectl`
is the client. Commands run between frames on the game thread: `wait N`,
`key NAME`, `down/up NAME`, `btn L|R down|up`, `pad`, `axis leftx|lefty V`,
`click`, `peek ADDR N`, `poke`, `objs` (object list to the game log), `area`,
`exec RESREF`, `usepoint TAG`, `anims ID|TAG`, `shot PATH`, `set KEY VALUE` (a
[Port] setting by its key, in force until exit), `quit`.

**`exec RESREF`** runs a compiled script as the player and replies
`ok R TYPE VALUE`: R is RunScript's result (0 failed), TYPE and VALUE the VM's
return cell. Guest code is called with the CPU state saved and restored.

**Script slots.** Because `override/` is indexed once (§1), `tools/jeplay`
creates 64 slots `override/zz_c00.ncs … zz_c63.ncs` (`jeplay init`, then
restart) and assembles each command into the next slot in turn. A deferred
command (`AssignCommand`, `DelayCommand`, `ActionDoCommand`) keeps only its
script's name; the engine reads the file again when it fires, so a slot is
not rewritten until 63 later commands have run.

**Latency.** The port reads `<dir>/in` once per presented frame and runs every
whole line it finds, so a client that waits for each answer before sending
the next pays a frame (~33 ms) per command. `jectl.send_batch` writes several
lines at once and `jeplay.queries` runs several expressions in one frame; a
fight round reads the player's and the foe's state in two frames instead of
about fifteen, and watching a foe costs one `frame` + `anims` round trip per
frame.

**Input device mode.** Once gamepad input arrives (stick axes, pad buttons),
the engine stops acting on keyboard shortcuts: F5 quick save, J journal,
Escape and M do nothing, while WASD movement still works and pad Start still
opens the menu. Moving the mouse switches it back. Observed in Chapter 2
after stick walking and the flying minigame; F5 never reached SaveGame
(0x429de0, probed) until two `move` commands were sent. `jeplay.menu_key`
moves the pointer before each shortcut. Whether combat keys (Space, Tab) are
gated the same way is not yet checked.

## §4 Engine behaviour for automation

**The player acts only in cutscenes and conversations.** Actions that move the
player (`ActionMoveToObject`, walk-to-use, the player's own
`ActionStartConversation`) are gated: outside cutscenes they do nothing. A
conversation is started from the NPC's side (`jeplay ask`). A click posts a
use event only for the highlighted object, and the player never walks to it,
so `jeplay use` stands the player at the object's use point first.

**Highlight.** The selector at 0x461970 (called from 0x4ea530, which stores
the winner in the use-marker panel through 0x4e62b0) gathers up to 32
objects within 6 m of the player. It scores each by the angle between the
view direction and the object's bearing, a, and its distance, d:
`|a| * 0.5` when d < 0.5 m, else `(|a| + 1°) * d`. The angle is a raw
difference of two atan2 results and is not wrapped. The lowest score wins,
but only if a line-of-sight test (0x410d30) passes; otherwise the next
candidate in the ranking is tried. Next Target (Tab) and Prev. Target (Q)
add ±1 to an offset kept at player + 0x1238, and the offset survives into
later selections. Facing an object is therefore not always enough to
highlight it, for example when a guard stands beside a door. `jeplay use`
faces the target, then presses Tab, at most 32 times, until the target is
highlighted.

**Use point.** The engine's reach test measures from the walk-to point of the
target model nearest the player (a placeable's `.pwk`), rotated into the
world, else the object's position. The `usepoint TAG` command returns it with
the player's personal space. `ActionJumpToObject` on a placeable lands short
or nowhere; module waypoints `wp_<tag>` are cutscene marks, often on the
object itself.

**Action queues.** Groups 0xffff and 0xfffe; failed actions are retried by
0x4d1b20; queues are purged by 0x4ddb70; `ClearAllActions` is 0x4daa30. A save
stores queues: an `AssignCommand(npc, ActionMoveToObject(…))` left on the
then-inactive dragon in the Spirit Cave stalled its conversation after the
next load. `jeplay save` therefore refuses unless idle and clears the queues
of the player and of every object a test command named (the ledger).

**Triggers** fire when the player's position crosses into the trigger
polygon on a frame; a jump that lands inside without crossing may not fire
it, which is one reason playtests walk (§6).

**Area transitions** are triggers whose template sets `IsAreaTrans`
(`LinkedToArea`, `LinkedToTag`; `CTrigger::GetIsAreaTransition` 0x45eb40 reads
template + 0xa8). Two separate tests run:

- *Approach.* The player update (call at 0x4ea678) calls trigger vtable slot
  0xb4 (0x4fb800) while the player is near the trigger. It sets trigger + 0x194
  and opens panel 0x42 AREATRANS, a label with the destination name (template
  + 0xe0); slot 0xb8 (0x4fb960) closes it. The label is only a hint: no key or
  button acts on it.
- *Enter.* Crossing into the polygon posts event 0xc to the trigger's event
  handler (slot 0x9c, 0x4fd870), which calls 0x4fb5b0. That requires a
  creature entering; it then either opens panel 0x2c (a string test on the
  global at 0x76c9b8, not yet understood: it held `worldmap` during a normal
  load) or loads the area (0x425a40).

The label appears well before the polygon edge: standing inside the polygon's
bounding box with the label up is not inside the polygon. Keep walking toward
the trigger's position until the area loads. NWScript `ShowAreaTransGui` (208,
0x496990) opens the same label from script.

**Combat.**

- A hostile that the engine has not put in combat (an ambush group not yet
  triggered) neither fights back nor takes hits.
- The engine's combat target is often unset while a group is still coming;
  `jeplay fight` falls back to the nearest hostile within 30 m.
- A blocking foe takes no damage from light attacks; a strong attack breaks
  the block.
- In a hostile area the player stays in combat stance: the stick plays the
  `cwalk*` strafe animations at ~0.63 speed (~0.07 m per 8 frames).
- Death opens panel 0x40 (with help bar 0x6a); `Return` reloads the last save.

**Conversations.** `GetIsInConversation` covers dialogs; cutscenes only set
`GetInCutsceneMode`. With no replies on screen a click skips the spoken line.
Fades and `PlayMovieBlocking` open panel 0x41 until done.

**Container rewards.** Chests, barrels, bones and graves (`j01_treas_*`,
OnUse `j00_a_chest_1`) carry no inventory. `RewardDispenseContainerReward`
(`j00_i_placeable.nss`) maps the area tag to a `REWARDAREA_*` constant
(`j00_i_rewards.nss`; `j02_ruins` and `j02_ruinslower` both use
`REWARDAREA_CH2_RUINS` = 23) and reads the **last two characters of the
container's tag** as a row of that area's reward table. Each container pays
out only once. The row's `item` column is an `items.2da` row, plus silver, XP,
alignment and a plot-flag bit (`rewardvar`/`rewardmask`). For the ruins the
table is `ar_ruins.2da`; for example `j01_treas_chest6_08` gives row 8
`find_dragonpowder` (item 210, flag `J02_PF_RUINS` 0x02) and
`j01_treas_grave3_16` gives row 16 `rat_demon_gem_chest` (item 382). To find
where a plot item comes from, look for its row in the `ar_*.2da` tables, then
find the container whose tag ends in that row number. How the
engine turns the constant into a table (`scriptlist.2da` row 23 holds 111) is
not traced yet.

**Destroyed placeables.** Destructible and trap placeables (trap chests,
barrels) hit in combat are destroyed late: vtable slot 0xb0 (0x4a8880) frees
the model at object + 0x3cc and zeroes it, called from the deferred-destroy
routine 0x461040. The object stays in the area list, and
`GetIsObjectValid` still returns 1. `GetIsOpen` (command 443, 0x483e90) then
reads `[obj+0x3cc]+0xa0` through 0x47a450 and faults at guest address 0xa4.
This crash is in the original engine, not the port. Scripts and tools must
not call `GetIsOpen` on placeables that can be destroyed.

**Saving cleanly.** A save is only as clean as the state it captures: the
"door3" lesson was a save made with a test command's action still queued.
Use `jeplay save`, never a raw F5, for saves meant to be kept.

## §5 GUI panels, animation state and combat data

**GUI panels.** Open panels by id: `[[[0x76C924]+0xB4]+0x8C]`, 0x6D entries
(the lookup 0x55d9f0 rejects 0x6d). Each panel holds a pointer to its class
name (`CGuiPanel.<NAME>`) at panel + 0x1C. Ids seen: 0x16/0x17 conversation
(0x17 = `lti_convorep`, the reply bar), 0x1e `AREAMINIMAP`, 0x21
`LTI_CURSELHENCH` (follower portrait), 0x27 `LTI_FLTINGCOMBAT`, 0x44
`PLAYERSTATUS` (these four make up the idle field HUD), 0x18 and 0x43 notice popups, 0x41
loading screen / movie, 0x58 combat HUD, 0x5A flying minigame HUD, 0x40 death,
0x6a help bar, 0x07 `LTI_CONFIRMATION` (a two-button question, e.g. the
route choice after Two Rivers: "This route is plagued with enemy ships. What
do you want to do?", ButtonOk "Attack" starts the flying minigame, ButtonCancel
"Evade"), 0x55 `STATICPANEL` (shown with it). In that confirmation panel the
buttons are embedded controls whose rects sit at panel + 0x2c4 (ButtonOk,
21, 75, 125 × 31) and + 0x588 (ButtonCancel, 167, 75), relative to the panel's
own rect (seen once; not yet checked on other confirmations). Reply panel layout: +0xD4 its ListBoxReply, +0x5C4 reply count,
+0x5CC item pointer array; item +0x1B8 a CExoString (char *, length with NUL);
panels and items keep x, y, w, h as four i32 at +0x04, in a 640×480 virtual
screen. `jeplay talk` chooses replies by text.

**Animation state (what a creature is doing).**

- creature + 0x520 → its model object (vtable 0x6f4780).
- The model holds one animation interface per channel: +0x40 base, +0x90 head,
  +0x94 weapon.
- Interface vtable +0x34: thiscall () → layer count. +0x38: thiscall
  (i, char **name, f32 *time, u32 *unsaved, u32 *flags, f32 *speed), callee
  cleanup.
- Found through the "AnimState" save code: creature models save at
  FUN_00500180, other models at FUN_004fefa0; the creature load is
  FUN_004ba9f0 (restored state at creature + 0x54c, channel labels Base
  0x6efc80, Head 0x6efc5c, Weapon 0x6efc40). The save sets flag 0x4000 when
  0x20 is clear.
- The `anims ID|TAG` control command returns
  `ok | N name time speed flags … | N … | N …` per channel and refuses an
  object whose model is not a creature model. Example: idle player
  `facenrm 1.208 1.000 4048 pause 2.091 1.000 60 …`; walking `cwalkl …`.

The model animation path: 0x60dd70 → 0x60dce0 → 0x60cbe0 → 0x6090a0 → 0x608810.

**Combat styles and attack names.** `GetCurrentStyle(creature)` returns a row
of `stylesuperlist`. Its `styledata` column names a row of `styledata`, whose
`animsound2da` column names the style's AS table (`twoda style GAMEDIR N`
prints it). AS columns include `Label`, `Anim` (the model animation name),
`AnimSpeed`, `MinRange`/`MaxRange` (metres), damage per type, `Unblockable`,
`AIMoveType`, `RefractTime`, `KnockdownAvailable`. Anim names are generic
across styles: `m1`/`m1b`/`m1c` and `m2`/`m2b`/`m2c` the light combos, `m3`
the slam (unblockable in most styles), `m4` the area clear, `blkr1` the
block. The `MV` table maps moves to AS rows (`animnumber`). Evades play
`cddgfr1` (front flip), `cddgbk1` (back flip), `cddgrt`/`cddglf` (rolls).
An evade is a double tap of a movement direction, the `Evade Method=0`
binding in `JadeEmpire.ini` `[InputOptions]`: stick pushed 2 frames, released
2 frames, pushed again plays `cddgrun` out of combat. Space tapped with the
stick held only walks, and a key tapped for one frame is not seen at all.
`jeplay fight` reads a foe's base-channel animation every frame it waits and
looks it up in the foe's AS table to block or evade the attack it telegraphs.
Live names match the AS `Anim` column exactly (no `stuntmodel` prefix seen);
`<anim>tran` plays after an attack (some AS rows name a `…tran` anim, e.g.
Storm Dragon `Clear_P3` = `m4btran`). Hit reactions seen: `kbackc1/2`,
`kdbckup`, `kdbckkb`, `dmgpbck2`, `burn`.

The AS table is not the whole story. In the pirate camp warehouse fight
(j02, style 98 NPC_Sword) six hits, 180 damage, landed through a held block
while the nearest foe, 1.0 m ahead, played `m1tran`, an anim absent from
style 98's AS table; Attack_C's `m1ctran` landed through block too. Of 48
hits logged over four fights, 14 (359 damage) came while the player held
block and 5 came right after a sideways evade from a Slam that had already
started (`cddgrt` playing): a roll at right angles does not always clear it.

So `fight` learns. Every answer it gives to a telegraphed attack (`block`,
`side` evade, `back` evade straight away) counts a try for the key
`style:anim`; a hit within `ANSWER_WINDOW` frames of the answer is charged
to it. A hit with no recent answer is blamed on the nearest foe whose base
channel shows an anim that is not a hit reaction, block, evade, face or
idle/walk anim, answered `block` if the player was blocking. A blamed anim
is an attack from then on even outside the AS table. Against each attack the
answer with the least damage per try wins; untried answers cost nothing, so
answers are tried in the order block, side, back as each lets hits through
(block is skipped against unblockable rows). The table persists across runs
in `fightlearn.json` in the ctl directory, so it also records which anims
hit through which defences, data for later combat-feel work.

Foes change style mid-fight: `GetCurrentStyle` on the Two Rivers lieutenant
returned 13 (Storm Dragon), 23 (Leaping Tiger) and 98 (NPC_Sword) in
different rounds of one fight. The handler (0x482c60) resolves its object
argument (0x461950), takes the creature (`vt+0x18`) and returns its style
(`vt+0x11c`), so the value is per creature; a bot must re-read it with each
animation.

Example styles: player Monk start = 23 Leaping Tiger; Two Rivers lieutenant
= 13 Storm Dragon; gimp soldiers 64 C_Gimp_Spear and 98 NPC_Sword.

## §6 Pathfinding grid and stick walking

**CGrid** (pathfind.cpp) sits at area + 0x1DC, built at load by 0x475db0 from
the area's `.hex` resource. Cells are pointy-top hexes: column j along world
y (spacing 1.5 × cell), row r along world x (spacing 2 × half_w), odd columns
shifted half a row in +x; index j × h + r. A cell's byte is its source byte
+ 1, kept below 0xfc; source bytes 0xfc and up are stored as is and block.
Centre per 0x475f80, corners per 0x476040. `tools/hexgrid` parses it and
routes on it (A* with a wall penalty, then string pulling).

**Walking.** Playtests walk with real stick input, never jumps: jumps skip
trigger crossings and hide collision bugs. The stick is camera-relative and
the camera follows, so `jeplay walk` re-estimates the stick-to-world yaw from
each step's displacement (steps under 0.04 m are ignored; positions read to
the millimetre). A walk counts as stuck when STUCK_STEPS steps bring it no
0.05 m closer to its waypoint (a slide along a wall moves every step yet gets
nowhere). It then blocks what stopped it and replans, up to REPLANS times,
then exits as a bug. When the leg crosses a soft 0xfe band (see
`hexgrid.soft_on_leg`), the whole connected band is blocked: a real wall is a long
band, and blocking one disc of it only moves the route to the next crossing
along it (the Tien's Landing teahouse ground floor, x ≈ 174–175.5). Otherwise
a disc 1 m ahead is blocked, for a body or prop the grid lacks.

The walk reads the live grid, which is not the area's HEXGRID resource
alone: a placeable stamps its hex patch into the grid as it closes and an
all-open patch as it opens (`CArtPlaceable::SetHexGridPatch`, 0x4aa790,
writing through 0x476f00). A corridor that routed before a cutscene can be
cut after it (two cases in chapter 2, after the Dirge rat demon and after a
ruins fight). "no route" then names the first blocked cell on the cheapest
way through, found by routing again with blocked cells allowed at a high
cost; the placeable there is what to look at, and whether it should have
opened is a script question, not a walker one.

**Combat timing levers (research, 2026-10-20).** Notes for the combat-feel
work: attack speed, earlier recovery cancel and hit-stop.

- Attack animations start in the creature anim component's play, 0x43fec0,
  thiscall on the component (`[this]` is the creature) with stack arguments
  (CExoString *name, f32 speed, u32 flags, 0, f32 blend). It calls 0x405b30 on
  creature + 0x528, which calls PlayAnimation 0x60d2f0. Attacks pass flags
  0x41, `…tran` recoveries 0x1, `ready` 0x40. Player attacks run at speed 1.0,
  NPC attacks at 0.75 in the j02 fight.
- The move queue state machine 0x4424d0 supplies the speed (call sites
  0x442d11 and 0x442e3b): the queue entry's speed (64-byte entries at
  `[esi+0x2c4] << 6`, speed at +0x10, flags at +0x1c; it comes from the AS
  table's `AnimSpeed` column) times a local scale. The scale is 1.0, or
  `1 / creature+0x570` for entries 0x43f700 accepts, times
  `vt+0x13c()->+0x64` unless 0x43f5b0 accepts the entry.
- creature + 0x570 (f32, with an f64 copy at + 0x190) is a per-creature time
  scale. Focus mode (0x40b9a3) and `SetGameSpeed` (0x49b460) multiply it on
  every creature except the player. Poking it on the player changes nothing
  visible: animation time still advances by the same amount per frame.
- Scaling the speed argument of 0x43fec0 for the player's anims with flags
  bit 0 (an experiment hook, since removed) works: at 1.6× the m1 → `ready`
  cycle took 5 control samples instead of 7 and the j02 foe died after 37
  samples instead of 45. Damage lands on animation events, so it follows the
  animation speed; no separate timer has to be scaled. Scaling `…tran` (also
  flags bit 0) shortens the recovery, which is the simplest form of an
  earlier cancel.
- The busy flags that make the press handler drop a press (creature flag set
  + 0x678, checked through 0x4b81f0: flag 1 or 0x32, or flag 2 with a move)
  were not traced to their writers; the AS `RefractTime` column is the likely
  source of the recovery window.
- Animation layers (object + 0x268 array, + 0x26c count, layer struct 0x38
  bytes, constructor 0x60b8a0) hold the animation at + 0xc and the playback
  speed at + 0x10 (1.0 at construction), next to the blend fields blend.odin
  uses. Hit-stop can set the speed of the attacker's and the victim's playing
  layers near 0 for a few frames and restore it. The hit point to trigger it
  from is the hit loop 0x447410 (its blocked branch is described under
  `states` in control.odin).
- Combat AI (docs/recompiler.md §10, Enemy AI): the AI object is
  `[creature+0x620]`, its action stack `[ai+0x80]`. Creature state 0x11 is
  blocking, 0x2c hit stagger, 6 hit reaction, 7 pushback (0x4b81f0). The
  template odds are in combataitemplate.2da (Level_1..5 set aggressiveness
  6..10). The game has no parry or perfect-block window (no AS or 2DA column
  for it); the port adds one (recompiler.md §10, Parry) through the hit
  reaction 0x4442c0. Foes dodge through DoEvade 0x4c3070. The player's block
  plays `blkl1` (flags 0x40) and `blkl2` for a blow taken on it.
- Foe class: each creature template (`.cre`, CRE V3.2 GFF in the module
  RIMs) has `Stats.Rank`, a row of `rank.2da` (Boss, FocusMode, Evasion
  0 never evades, BossEffects, Intelligence 1 smart to 3 dumb, SlamChance
  percent odds of a power attack on a blocking target, UseAdvancedEvasion,
  AAABlockChance percent odds of blocking out of a hit reaction;
  recompiler.md §10, Rank columns). Templates carry no Body, Spirit or Mind:
  only `HealthBase`, `ChiBase`, `FocusBase` (0 in all but one) and `Rank`. At runtime the row is
  `[[creature+0x1c]+0xfc]` (GetRank 0x4369d0), and 0x436b50 copies the eight
  columns into the AI at +0x158..+0x174. Of 1077 templates: rank 1 (729,
  townsfolk, animals, most mooks), 9 Default_Random (65, soldiers, ghosts,
  bandits), 5 (37, students, ghosts), 12 (11), all Intelligence 3; 6
  Boss(medium) (48, arena fighters, golems, thugs, Intelligence 2); 7
  NPC_NotBoss smart (47, Lotus Assassins, demons, pirates); 2 Boss(smart)
  (103, named bosses: Gao, Fang, Chai Ka, arena champions, companions'
  enemy forms); 8 Henchmen (29, the followers); 10 Death_Hand (5); 3 the
  Emperor; 4 one demon.
- Foe heals: only ranks with the Boss column set roll the template's ProbHeal
  (combataitemplate.2da; Normal 0.15, No_heal 0), below 80% health, and the
  shipped heal spends no chi. The port lets non-boss foes of tier 3 and up
  heal too when they carry chi (template `ChiBase`), at one chi per health
  point (recompiler.md §10, Heals).
