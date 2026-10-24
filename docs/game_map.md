# Gameplay map

What the port touches in the game's gameplay code: the functions it hooks,
calls or patches, the structure fields it reads and writes, and the port file
that owns each. Addresses are in `unpacked/JadeEmpire.exe`. The how and why of
each change is in `docs/recompiler.md` (§9 guest patches, §10 behavior hooks,
§11 settings menu); rendering is mapped in `docs/rendering.md`, the platform
layer in `docs/hle.md`. Function names match `re/names.txt` and
`re/funcnames.txt`; `inf` there marks a name inferred from use.

Hook means a native proc registered over the function in
`port/src/native/native.odin`; call means the port calls the guest function
through `win32.guest_call`; patch means bytes rewritten by `PATCHES` in
`tools/x86rec/image.odin`.

## Frame of a player move

```
SDL pad ─ win32/pad.odin (radial deadzone, virtual Xbox pad)
  └ CXbInput_ReadPad 0x6678e0  [hook: stick.odin, flick.odin, dpad.odin, camera.odin cam_pad]
      ├ GUI: CXbInput_GetGUIInput 0x667420 (a2 = 1)        menus, d-pad folded into left stick
      └ gameplay (a2 = 0)
          ├ CPlayerControl_Update 0x463570                 [player+0x7ec]
          │   └ CMoveDataCreature_SetDir 0x45c720          [hook: turn.odin Move_Dir]
          │       └ GetCombatMovementDirection 0x45c190
          │   CMoveDataCreature_Apply 0x45c980             [hook: turn.odin Move_Anim]
          │   CMoveDataCreature_Update 0x45e300 ─ CMoveDataCreature_Turn 0x45e070
          │       └ CMoveDataCreature_Collide 0x45d6b0         [hook: magnet.odin]
          ├ CPlayerCreature_HandleActions 0x4f3b30 (actions*)
          │   └ CCreature_DoEvade 0x4c3070                 [patch: dodge.odin bounds]
          └ CCombatInput_Tick 0x44a8d0                     [hook: buffer.odin]
              └ CCombatInput_Press 0x44cb00 / _Release 0x44c3c0  [hook: buffer.odin]
CPlayerCreature_Update 0x4f20d0
  └ Combat_UpdatePlayerTarget 0x434430 ─ gate 0x4340c0
      └ CGameObject_GetPosition 0x4123d0, per candidate     [hook: target.odin, return 0x4345f9]
CBehaviorCamera_Update 0x420f60 (vtable 0x6e37d0 slot 2)   [hook: camera.odin]
  └ CBehaviorCamera_Clip 0x420730                          [call: camera.odin]
foes: CCombatAI_Update 0x43df70 ─ Think 0x43dde0 ─ FillProbs 0x43c680  [hook: ai.odin]
anims: CAnimComponent_Start 0x43fec0 [hook: ai.odin parry, pace.odin]; Model_PlayAnimation 0x60d2f0,
       Model_ApplyLayer 0x60e8f0 [hook: blend.odin]
```

## Globals

| Address | What | Used by |
|---|---|---|
| 0x76c924 | `g_AppManager` (APP) | everything |
| APP+0x20 | f32 frame seconds (APP_DT) | turn, camera, ai, buffer |
| APP+0x38 | u32 app state, 0 or 5 while the world runs | flick |
| APP+0xa0 | the module (APP_MODULE) | turn, camera |
| APP+0xa0 → +0x124 | the module's camera (MODULE_CAMERA); camera pos at +0x7c | turn, stick_log |
| APP+0xa0 → +0x0, +0x4 | party creature** and count | flick |
| APP+0xdc | CXbInput; GUI slot table at +0xd6b8, modes at +0xd768 | dpad |
| APP+0x7c0 | evade input mode, the player dodges only on 1 or 2 | (read by 0x4f3b30) |
| 0x75b394 | the invalid object id | flick, target |
| 0x75ecdc | nonzero while a module runs | flick |
| 0x75ecd0 | f32 frame seconds as MainLoop sets them for the draws (CGuiManager's draw argument) | coop_camera: halved for each of the two online passes |

## Input

| Address | Function | Port |
|---|---|---|
| 0x6678e0 | `CXbInput_ReadPad` (thiscall(a1, a2)): builds one port's Xbox pad; a2 1 for GUI reads | hook `Xb_Input_006678e0`: deadzone (stick.odin), right-stick flick and triggers (flick.odin), d-pad into GUI stick (dpad.odin), right stick taken for the free camera (camera.odin) |
| 0x668481 .. 0x668574 | the per-axis ±6535 deadzone compares in 0x6678e0 | patch to 0; radial deadzone in win32/pad.odin |
| 0x6661d0 | `CXbInput_AxisDeadzone` | hook `Axis_Deadzone_006661d0` (stick.odin) |
| 0x667420 | `CXbInput_GetGUIInput` | read by dpad.odin |
| 0x665c80 | the 44 pad inputs (0..3 d-pad bits, 0x10..0x13 stick i16s) | dpad.odin |

Virtual Xbox pad (the struct 0x6678e0 fills): `+0x4` u16 buttons (d-pad up 1,
down 2, left 4, right 8), `+0xe` LT, `+0xf` RT (u8), `+0x10` LX, `+0x12` LY
(up positive), `+0x14` RX, `+0x16` RY (i16), `+0x1c` the previous call's copy.
Per-port block size 0x33a8; axis deadzones at +0x3810, first axis +0x10.

Player action slots (the `actions*` argument of 0x4f3b30): 41 slots of 28
bytes; slot 10 (+0x118) is the stick's X and slot 17 (+0x1dc) its Y.

## Player movement

| Address | Function | Port |
|---|---|---|
| 0x424700 | `Module_GetPlayer` (thiscall on the module) | call (turn.odin GET_PLAYER); return 0x45c9b0 recognised as the move-apply caller; hook (coop_hud.odin): the stand-in during pass B's GUI |
| 0x463570 | `CPlayerControl_Update`: control at `[player+0x7ec]` (vtable 0x6e86e8, stick +0x10/+0x14); turns the stick by the facing; 0x464762 negates it on some camera angles | read (turn.odin) |
| 0x45bfd0 | `CMoveDataCreature_ctor` (vtable 0x6e7ef0) | — |
| 0x45c720 | `CMoveDataCreature_SetDir` (thiscall(dir)); also vtable +8 | hook `Move_Dir_0045c720` (turn.odin): turn-to-run, stick left at (0, len) |
| 0x45c190 | `CMoveDataCreature_GetCombatMovementDirection`: 0 ahead, 1 back, 2/3 sides, 4..7 diagonals | — |
| 0x45c980 | `CMoveDataCreature_Apply` (move animation) | hook `Move_Anim_0045c980` (turn.odin): stick (1,1) blocks wall-slide strafes |
| 0x45e070 | `CMoveDataCreature_Turn`: +0x6c toward +0x78, stalls on wide angles | — |
| 0x45e300 | `CMoveDataCreature_Update`: model heading = want turned by the stick (+0x94) | — |
| 0x45d6b0 | `CMoveDataCreature_Collide` (thiscall(out, mover, want, ok), ret 0x10): mover `+0x3c` position toward want, walkmesh and wall slide, ground z | hook `Collide_0045d6b0` (magnet.odin): swing slide |
| 0x4ff500 | model orientation, `[creature+0x520]` vf 0x38, quaternion at gob +0x84 | — |

CMoveDataCreature: `+0x60` move direction, `+0x6c` current facing, `+0x78`
desired facing (f32 x, y, z), `+0x90` creature, `+0x94` stick (x across, y
ahead).

## Camera

| Address | Function | Port |
|---|---|---|
| 0x420f60 | `CBehaviorCamera_Update` (thiscall(dt), ret 4), exploration camera vtable 0x6e37d0 slot 2 | hook `Cam_Update_00420f60` (camera.odin): free camera out of combat |
| 0x420730 | `CBehaviorCamera_Clip` (thiscall(out*, want*), ret 8): collision pull-in | call (camera.odin) |
| 0x420330 | `CBehaviorCamera_ClipRay`: the clip's ray test, against the whole area (0x4246d0, 0x467de0); reads only `+0xdc` of the behaviour | - |
| 0x418580 | `CBehaviorCombatCamera_Update`, combat camera vtable 0x6e3230 slot 2 (body 0x417de0); in a fight 0x420f60 stops | - |
| 0x417de0 | `CBehaviorCombatCamera_Frame`: combat camera body; centre of the framing box, distance from FOV, base behind GetPlayer along facing, springs 0x41e990 | - |
| 0x417260 | `CBehaviorCombatCamera_Ctor`: 0x110 bytes; `+0x38`/`+0x3c` framed object ids, `+0xc4` framing helper (0x412b60) | - |
| 0x417620 | `CombatFrame_Box`: framing helper's box, point A `+0`, point B `+0x24`, heights `+0x14`/`+0x20` | - |
| 0x461950 | `CObjectStorage_LookupId`: object id to pointer (via 0x4610b0) | - |
| 0x5df230 | `Camera_Tick` (thiscall(phase), ret 4) on the module's camera, vtable 0x70aa88 slot 3: phase 0 before the update, 1 in it (0x40cc96, draws the scene's first half), 2 after it (0x4a4917, the rest) | hook `Scene_Tick_005df230` (coop_camera.odin): online, both views drawn |
| 0x51e090 | `CGuiManager_Draw` (thiscall(dt), ret 4): GUI plus world labels and overlays | hook (coop_camera.odin): pass B after it |
| 0x5da240 | `Gui_SetRootClip`: the full viewport as the GUI's root clip rect | hook (widegui.odin); called for pass B |
| 0x5aacf0 | level of detail from an object's depth `+0x18` (Object_BoxZGap 0x5aa990) | zgap.odin lends it the game's pose in pass B |
| 0x5e5420 | object light update (vtable slot 0x220), fades by 0x75ecd0, caches colour and position at `+0x250` | - |
| 0x5e6ae0 | depth-sort comparator, against the view direction 0x75ed70 and position 0x79e16c | - |
| 0x63a860 | `Emitter_Update`: particles' camera-facing quads into the buffer at `[0x7ee10c]` (`[0x75f41c]` vertices) | - |

0x5ebfa0 is the scalar deleting destructor of vtable 0x70b33c (0x5ebfc0 its
body), not a view setup.

CBehaviorCamera: `+0x38` target object, `+0x3c` camera interface (camera +
4), `+0x48` target position, `+0xe8`/`+0xec` clip flags and hold (saved round
the port's clip call). Camera: `+0x7c` position, `+0x88` quaternion w, x, y, z
(looks down -z).

## Combat input and targeting

| Address | Function | Port |
|---|---|---|
| 0x44cb00 | `CCombatInput_Press` (thiscall(buttons, creature), ret 8; creature 0 = player) | hook (buffer.odin): keeps a dropped press |
| 0x44c3c0 | `CCombatInput_Release` | hook (buffer.odin) |
| 0x44a8d0 | `CCombatInput_Tick` (called from 0x4336d5) | hook (buffer.odin): replays the buffered press |
| 0x44c420, 0x443d80 | pick a move, queue it (`CAnimComponent_Queue`) | — |
| 0x4f20d0 | `CPlayerCreature_Update`: calls the target update every frame in combat | — |
| 0x434430 | `Combat_UpdatePlayerTarget`; gate `0x4340c0`; keeps the candidate least squared distance from the position 0x4123d0 returns | — |
| 0x4123d0 | `CGameObject_GetPosition` | hook `Obj_Pos_004123d0` (target.odin): from return 0x4345f9 hands back a stick-weighted position at 0xa00300 |
| 0x46ff70 | set target | — |

Input block: `+0x94` owner, owner `+0xc` the combat controller, controller
`+0x0` held buttons. Creature: `+0x58c` target id, `+0x590` u16 lock-on mode.

## Dodge

| Address | Function | Port |
|---|---|---|
| 0x4f3b30 | `CPlayerCreature_HandleActions` (thiscall on the player, (actions*)); DoEvade at 0x4f4a9e, 0x4f4b3c | — |
| 0x4f3600 | `CPlayerCreature_EvadeAction`, called at 0x4f4c01; DoEvade at 0x4f39b0, 0x4f3ac1 | — |
| 0x4c3070 | `CCreature_DoEvade` (thiscall(f32 x, f32 y, flag), ret 0xc) | patch 0x4c3418, 0x4c354f (flips), 0x4c369d, 0x4c36ee (rolls) to the bounds at 0x00a00310 (dodge.odin); foes call it from ai.odin |

Inside DoEvade: the stick is turned by the player's facing, then dotted with
the creature's facing (flip forward `cddgfr1`, back `cddgbk1`) and its right
(roll `cddglf`, `cddgrt`); a direction past no bound falls back to anim entry
0xf4. `cddgrun` is the out-of-combat dodge. The original bounds are the
doubles 0x6e53c8 (cos 45) and 0x6e53c0 (-cos 45), also read at 0x447c79,
0x447c9d.

## Combat AI

| Address | Function | Port |
|---|---|---|
| 0x43df70 | `CCombatAI_Update` (thiscall on the action stack, (creature), ret 4) | hook `Ai_Update_0043df70` (ai.odin): tiers |
| 0x43dde0 | `CCombatAI_Think`, when the stack is empty | — |
| 0x43c680 | `CCombatAI_FillProbs`: six template odds | hook `Ai_Probs_0043c680` (ai.odin) |
| 0x43b0a0 | `CCombatAI_PatternIdle` | hook `Ai_Pattern_Idle_0043b0a0` (ai.odin) |
| 0x43c870 | `CCombatAI_Block`: pushes type 0x4a, 45..150 frames | — |
| 0x43a2a0 | `CCombatAI_Attack` (thiscall(type), 1 quick, 2 power, -1 pick) | call (ai.odin) |
| 0x439030 | `CCombatAI_Push` (thiscall(type, sub, f32, vec3), ret 0x18) | call (ai.odin) |
| 0x43e22e | update's sub 5 case (attack entry {style move index, 5, 1}): waits on busy anim 0x43fa50, faces 0x438210, runs the executor | ai.odin drop_attacks |
| 0x438210 | `CombatAI_FaceTarget`: turns to the target (0x4c2720), 0 while turning | — |
| 0x437de0 | executor's sub 5 gate (type) | — |
| 0x44b3b0 | `Combat_PlayStyleMove` (thiscall on `[[0x76c924]+0xac]+0xc` (index, creature)) | — |
| 0x4390f0 | `CCombatAI_RemoveAt`: the update drops index 0 past 10 entries | — |
| 0x451ad0, 0x451bf0, 0x451ce0 | scripted style-move list (`[[0x76c924]+0xac]+0x14`, creature `+0x664` its index): get, remove, add | — |
| 0x437620 | `CCombatAI_Roll` (rand/32767 < p) | — |
| 0x43da20, 0x43ad00, 0x43e280 | pick, heal case, executor (type 3 heal; sub 5 at 0x43e6d8 plays an attack) | ai.odin heal cost |
| 0x4369d0 | `CCreature_GetRank` | read [[cre+0x1c]+0xfc] (ai.odin RANK_TIER) |
| 0x4b81f0 | `CCreature_HasState` (thiscall(id), ret 4) | call (ai.odin) |
| 0x4ced10 | `CCreature_SetUpNewStyles` (entries with `+0xbc` set) | call (coop_hero.odin) |
| 0x4ceba0 | `CCreature_ApplyStyleUpgrades` (thiscall(entry, ^new, 2da, 0), ret 0x10) | hook (coop_hero.odin) |
| 0x4cacf0 | `CCreature_ApplyStyleAdvance` (thiscall(entry, styleadvance row)) | read |

Creature: `+0x8` id, `+0x44` position, `+0x50` facing, `+0x1c` stats
(`+0xfc` rank row), `+0x358` anim component, `+0x470`/`+0x478` health and
max, `+0x464` styles known, `+0x46c` style entries (`+0` style id, byte `+5`
1 + upgrades bought, u64 `+0x10` upgrades, `+0x28` damage and `+0x64` speed
multipliers, `+0xbc` new), `+0x488` chi, `+0x584` style in use (index),
`+0x588` combat stance, `+0x58c` target id, `+0x5bc` heal frames, `+0x620`
combat AI, `+0x7ec` player control, `+0x1220` combo step. Combat AI: `+0x4`
self, `+0xc` target, `+0x38` ProbHeal, `+0x68` heals off, `+0x7c`
aggression, `+0x80` action stack (count, capacity, 24-byte entries), `+0x158`
boss, `+0x160` Evasion, `+0x16c` SlamChance, `+0x174` AAABlockChance. State
0x11 is blocking; 1 staggered; 0x2c a 2 s hold that long moves, dodges and hits set, during which the update runs no action.

## Animation

| Address | Function | Port |
|---|---|---|
| 0x43fec0 | `CAnimComponent_Start` | hook `Anim_Start_0043fec0` (ai.odin): parry window, foe parry, recovery speed; calls pace.odin (player swing speed, hit stop) |
| 0x4442c0 | `CAnimComponent_HitReact` (thiscall on `[cre+0x358]`, (move, kind, 0, 0), ret 0x10) | call (ai.odin parry, kind 1) |
| 0x60d2f0 | `Model_PlayAnimation` (name, ?, flags, start, blend, out) | hook (blend.odin) |
| 0x60e8f0 | `Model_ApplyLayer` (cdecl: model, anim, flag, prev, time, weight) | hook (blend.odin) |
| 0x60f760 | `Model_UpdateLayers` | — |
| 0x60b8a0 | layer ctor (0x38 bytes) | — |

Object anim layers: `+0x268` layer pointers, `+0x26c` count. Layer: `+0xc`
animation, `+0x20` weight, `+0x24` transition time, `+0x30` state (1 in, 2
full, 3 out, 4 dead), `+0x34` seconds into the transition.

## Blows and contacts

A blow lands through contact slots in the combat-cd object at
`[[APP]+0xac]+0x10`: 15 for the player at `+0`, 40 for everyone else at
`+0x1e0`, 0x20 bytes each (`+0` attacker id, `+4` victim id, `+8` move,
`+0x18`/`+0x1c` armed). A slot is added unarmed; only the attacker's
"HitOn" anim event arms it, and a contact pass tests it only while armed.

| Address | Function | Port |
|---|---|---|
| 0x445950 | combat-cd init; `0x444ec0` slot init | — |
| 0x445a10 | hit reach query: which creatures a starting move can reach | — |
| 0x444ff0 | contact add (attacker, victim, move): leaves the slot unarmed | — |
| 0x445200 | contact clear | — |
| 0x447410 | contact pass: armed slots only (`+0x18 == 1`); per slot `0x444e10` gives the attacker's limb mask, `0x453e50` tests it, slack 1.0 when the attacker's `+0x664` is not -1; a hit clears the armed flags (`0x44765a`); `0x4478b0` and `0x446f70` are the other passes | — |
| 0x453e50 | cd tree test (thiscall attacker's tree `cre+0x37c` (victim's tree, limb mask, slack)): bit i tests leaf i, the top nibble recurses into children | — |
| 0x4d8b20 | can-hit check (attacker, victim) | — |
| 0x445f70 | hit apply (attacker, victim, move, style, ...): damage from the style's move (`0x436800`); a support style (Heavenly Wave, 0xe) does none | — |
| 0x4424d0 | anim hit event dispatch | — |
| 0x4cf410 | creature anim event registration (thiscall creature): drops the old handles (`0x4b67c0`), then registers "HitOn" `0x4bbd90`, "HitOff" `0x4bbe30`, "Cast" `0x4cf250`, "slam" `0x4c9430` on the model (vt+0xcc), handles at `+0x35c..+0x368`; called by the area set-up `0x4cf500` (at `0x4d0516`) and, when `+0x588`, by `0x42ca00` and `CCreature_Transform` `0x4d0ca0` | coop_hero.odin calls it for player 2's hero, once per model in combat stance |
| 0x4bbd90 | "HitOn" (cdecl, creature at esp+0xc): unless state 0x37, arms the player's 15 slots or the 40 slots whose attacker is the creature | — |
| 0x4bbe30 | "HitOff": disarms them | — |
| 0x4cf500 | creature area set-up (vtable `0x6f0484`/`0x6f2df4`, from `CPlayerCreature_Update` `0x4f238d`): builds the cd tree (`0x4cf8ac`), registers anim events | — |

Targets: `0x46ff70` set (thiscall on `cre+0x58c` (id, 0), ret 8), `0x46f240`
read (the invalid id unless the mode at `+0x590` is 1), `0x4709c0` upkeep
in combat stance (a non-player keeps a target only while it fights back,
else picks one with `0x470470`): coop_foes.odin sets player 2's hero's and
hooks the upkeep (`Target_Upkeep_004709c0`) to keep it. `0x440730` returns
an anim component to ready.

## Party (for co-op)

| Address | Function |
|---|---|
| 0x48de40 | `nws_ActivateHenchman` |
| 0x4845c0 | `nws_GetHenchmanCombatMode` |
| 0x48e420 | `nws_SetHenchmanFollowPlayerInCombat` |
| 0x4903f0 | `nws_PolymorphPlayerToHenchman` |
| 0x463570 | `CPlayerControl_Update` (thiscall(dt), ret 4); hook `Player_Control_00463570` (coop.odin) reruns it for player 2 |
| 0x464aa0 | `CPlayerControl_Frame` (vtable slot 8, every frame from CAppBase_Update 0x40ca50; calls 0x463570 only when `[0x76c924]+0x38` is 0 or 5); hook `Control_Frame_00464aa0` (coop.odin) hides the henchman for player 2 |
| 0x455f40 | faction table `IsEnemy` (thiscall on `[0x76c928]+4`, (faction, faction) -> u8; faction at `+8` in object vtable `+0x7c` part), as GetIsEnemy 0x483420 calls it | coop_foes.odin: foes of the player scale while player 2 is in |
| 0x4c63b0 | `CCreature_GetHealthBase`: `+0x7b4` if flag `+0x7b0`, else template `[+0x1c]+0xd8` | coop_foes.odin sets the override to 2x |
| 0x4f4e80 | `CPlayerCreature_SetHenchmanMode` (thiscall(slot, mode)): slot mode `+0x2c`, a HenchmenAIData.2da row, 1 support |
| 0x4946c0 | `nws_SetObjectActive`: vtable `+0xac` activate, `+0xb0(0)` deactivate, `+0x90`/`+0x94` state |
| 0x4cb340 | CCreature save: writes `+0x4cc` (own appearance) among the rest; calls CGameObject save `0x4d8840` (resref `+0xc`, CResRef 16 bytes upper case, label "ResRef") | coop_hero.odin: a save keeps player 2's hero |
| 0x408ac0 | `CCreature_GetAppearanceType`: `+0x4cc` if >= 0, else template `[+0x1c]+0xe8` | coop_hero.odin |
| 0x460630 | world object count (world `[[0x76c924]+0xa0]`, area bits, type, flag); type 2 counts at `+0x38` (flag set) and `+0x3c` (made in play) | coop_hero_find scans ids 0x10008000+i |
| 0x42cf20 | `CCampaign_LaunchMiniGame`, from CAppBase `0x40d9b0` after the module load: minigame object (0x2ac30 bytes, ctor `0x6831f0`) at module `+0x120`; `0x42a150` frees it | flying minigame = its own module; co-op needs nothing |
| 0x485e50 | `nws_GetNearestObject_etc` (actions 0xe3 GetNearestObject, 0xe4 ToLocation): nth nearest via `0x4ad720`, called at `0x486027` | coop_search.odin |
| 0x4ad720 | area nth nearest (thiscall area (^out id, ^pos, type, flags, nth), ret 0x14; nth from 0), forwards to world `0x4614b0` | coop_search.odin skips player 2 for scripts |
| 0x4863b0 | `nws_GetFirstObjectInShape_etc`: walks `0x4ad810`/`0x4ad850`, skips inactive objects (vtable `+0x94` 0) | coop_search.odin |
| 0x4ad810 | area first object in shape (thiscall area (shape, ^box), ret 8) -> object | coop_search.odin |
| 0x4ad850 | area next object in shape (same args) -> object | coop_search.odin |
| 0x483530 | `nws_GetEnteringObject`: trigger `+0x188` | |
| 0x484e20 | `nws_GetFirstInObject_etc` (actions 262 first, 263 next): area shape walk `0x4ad810`/`0x4ad850`, skips inactive (flag 0), point in trigger polygon `0x4fe440` (`+0x198`) | coop_search.odin |
| 0x4fd870 | `CTrigger_EventHandler` (thiscall(kind, ?, event {tag, data})): kind 1 script event, data u16 +0 type (0xc enter, 0xd exit), objects +0x28 count / +0x30 array; enter stores id at `+0x188`, area transition, trap, OnEnter | coop_search.odin drops player 2's enter/exit |
| 0x4f1200 | `CPlayerCreature_ApplyHenchmanMode` (thiscall(slot), ret 4): gated on the henchman's `+0x588`; applies the mode row to her (AI, state), puts the SupportEffect on the player (`0x4f1783`..`0x4f17d2`), then her casting reaction `0x4c2720` (needs her `+0x358`) | coop_hench.odin applies the buff alone while she is out |
| 0x4cf500 | CCreature update (per frame; for the player from CPlayerCreature_Update `0x4f238d`); calls `0x4f1200` for the selected henchman at `0x4d0796` | |
| 0x4c6770 | CCreature vtable `+0x114`: plain store of the in-combat flag `+0x588` (CPlayerCreature's is `0x4f2f70`, its combat start) | |
| 0x4e8220 | CPlayerCreature henchman of a slot (thiscall(slot)): object by the id at slot `+0x40` | |
| 0x4ebfd0 | loads a slot's SupportEffect `+0x34` / SupportEffectParam `+0x38` | |
| 0x4ef6f0 | `CPlayerCreature_EndHenchmanMode` (thiscall(slot, ?)): removes the player's effects the henchman created (`0x4e0bc0`); from SetHenchmanMode, combat end `0x4f356c`, henchman deactivation `0x4f1140` | |
| 0x424c30 | module new effect (thiscall(type, param)) -> effect, none for type <= 0 | |
| 0x4c4eb0 | `CCreature_ApplyEffect` (thiscall(effect, 0, 0)) | |
| 0x50b1c0 | support effect apply (effect list handler, ret 8): sub-effects 9..12 on the target, creator (`0x4611b0` at `0x50b38a`) reacts; removal `0x50b470` (lookup at `0x50b4f1`) | coop_hench.odin: inactive creator looks up as none |
| 0x4611b0 | object storage object by id (thiscall(id), ret 4) | |
| 0x4be030 | `CCreature_SetState` (thiscall(state, add, param, f32 seconds), ret 0x10; add 0 removes) |

Creature effects: list at `+0x1a0` (vtable `+0x80` `0x4c6340`), count u32
`+0x1b0`, array `+0x1b8`; effect creator id `+0x18`.

Player: `+0x7ec` control (CPlayerControl, vtable 0x6e86e8, 0xa0 bytes: `+0x10`
stick f32 ahead and across, `+0x80` driven creature id), `+0xa28` henchman
slots (0x8c bytes, id at `+0x40`), `+0x1144` selected slot (0xff none),
`+0x810` style quick slots (10, style id or -1). A CCreature is 0x7e8 bytes
(made at `0x45ed90`, ctor `0x4c5e20`), a CPlayerCreature 0x12f0 (`0x45edeb`);
vt+0x28 returns the player part, null for a plain creature.

HUD panels (CGuiManager_Draw walks count `[mgr+0x30]`, array `[mgr+0x38]`:
vt+0x40, vt+0x2c(dt), vt+0x30; the floatstyle panel is also at
`[[APP]+0xb4]+0x6c`):

| Address | What | Port |
|---|---|---|
| 0x57da90 | lti_fltingcombat ctor (bars, vtable 0x6ffe10, 0x1940 bytes) | coop_hud.odin twin |
| 0x57e0f0 | its update; `0x57d780` sets maxima from player vt+0xe0/vt+0xe4, `+0x488`, `+0x1230`; health `+0xb20`, focus `+0x11a4` | — |
| 0x5425c0 | lti_floatstyle ctor (style cross, vtable 0x6fa7d0, 0x18f0 bytes) | coop_hud.odin twin |
| 0x541990 | its vt+0x2c; refreshes slots 0..9 through `0x541ba0` (reads player `+0x810`) when `[+0x182c]` | — |
| 0x541f90 | its vt+0x54, d-pad right: slot 1; vt+0x58 `0x542570` (body `0x542050`) left: slot 0; vt+0x5c `0x542100` up: slot 2; vt+0x60 `0x5421d0` down: slot 3 (dispatched by `0x448fc0` actions 0x17/0x15/0x18/0x14) | coop_style.odin mirrors for player 2 |
| 0x542440 | its vt+0x74 SelectSlot (thiscall(slot u8, flag)): out of combat highlight only; in combat 0.5 s wait `[+0x1838]`, vt+0x138 check, not state 0x54, then `0x540c20` | coop_style.odin mirrors for player 2 |
| 0x540c20 | sets player `+0x838` to the slot's style, then vt+0x128 unless state 0x1d/0x36 | — |
| 0x4bd4f0 | creature vt+0x128 switch style (thiscall(style id, 0, 1)); sound for the player | coop_style.odin calls it on player 2's hero |
| 0x543030 | its vt+0x6c style changed (thiscall(style id, 1)); current `[+0x1844]` | coop_hud.odin calls it on the twin |
| 0x540f70 | its name label (thiscall(style id), -1 clears; fades in, out after 5 s) | — |
| 0x4bd720 | `CCreature_SetCurrentStyle` (thiscall(style id)); tells the floatstyle panel for the player only | — |
| 0x4eb690 | `CCreature_FindStyle` (thiscall(style id)): index in `+0x46c`, -1 if absent | — |
Globals the control update keeps for the player: `0x76c650` jump latch,
`0x75b390` target turn.

Object ids: type `0xf8000000` (>>27; creature 2 = 0x10000000), area
`0x7f80000` (>>19), 0x40000 flag, `0x1c000` field, index low bits; creatures
made in play from 0x10008000. Ids persist across save and load.

## The port's data page

Guest memory at 0xa00000, a page nothing in the game uses, holds tables and
constants the patched code reads.

| Address | Size | What | Owner |
|---|---|---|---|
| 0xa00000 | 27 × u32 | Video panel row labels (strrefs) | settings.odin (§11) |
| 0xa00100 | 17 × 16 | Control panel rows {strref, default, min, max} | settings.odin |
| 0xa00280 | 17 × u32 | Control panel row descriptions | settings.odin |
| 0xa00300 | 12 | aimed-target position, f32 x, y, z | target.odin |
| 0xa00310 | 4 × f64 | dodge bounds: +cos 30, -cos 30, +sin 30, -sin 30 | dodge.odin |
| 0xa00400 | 0xa0 | player 2's copy of the player's control | coop.odin |
| 0xa00500 | 0xf0 | behaviour block player 2's camera clip runs on | coop_camera.odin |
