// Enemy AI tiers, a deliberate change rather than a bit-exact replacement.
// The game's combat AI thinks about once a second: it rolls a weighted action
// (attack, block, heal, move, switch style, idle) from fixed template odds and
// never looks at what the player is doing, so a foe walks into every combo and
// idles between its attacks. A tier above Original adds reactions, rolled once
// per player event, for foes whose target is the player:
// - a fresh player swing at this foe may be blocked or dodged (DoEvade); a
//   power attack, which no block stops, only dodged;
// - the player's recovery after a swing may be punished with a quick attack;
// - a player holding block may be met with a power attack, which breaks it;
// and idle odds and pattern idles shrink, the odds moving to attack.
// Master foes read baits: a reaction answered by a hit on the foe within
// BAIT_SEC makes that reaction suspect, which cuts its odds until it fades
// (a burned block turns into dodges and back), and a power attack waits for a
// block held COMMIT_SEC, so a flicked block does not draw it.
// No reaction fires while the foe is blocking or staggered, since its action
// would run late. Blocks the game picks itself are cut to the tier's length,
// so a foe does not turtle through a whole combo. Chances scale with the
// foe's aggressiveness, and each follows its rank.2da row: a foe whose
// Evasion is 0 never dodges (a dodge turns into a block, or nothing against
// a power attack), blocks scale with AAABlockChance and power attacks on a
// block with SlamChance, the odds the shipped AI rolls for the same moves.
// A foe's tier, 0 (the original) to 6, comes from its rank.2da row
// (RANK_TIER): the original never watches the player, so even fodder gets
// tier 1, soldiers and ghosts 2, arena fighters 3, assassins 4, named bosses
// 5, and the Death's Hand and the Emperor 6. The setting caps it: JE_AI=0
// keeps the original AI for all, 1 caps at tier 3, 2 (the default) none.
// Foes parry too: a player blow taken on a foe's block may stagger the
// player, at the tier's odds. Higher tiers recover faster from hits, block
// reactions and knockdowns (their anims play faster) while their health is
// at least HEALTH_KNEE of its max; a worn-down foe recovers as shipped.
// The game lets only bosses heal, and their heals cost no chi; from tier
// HEAL_TIER up any foe may, at its template's odds, if it carries chi, and
// it pays one chi per health point restored.
// Parry, the player's side and its own setting: a block raised within
// PARRY_SEC of a foe's blow landing on it staggers the foe that swung last,
// through the game's hit reaction. JE_PARRY=0 turns it off.
// WHY: docs/recompiler.md §10
package native

import "core:math/rand"
import "core:time"
import "../win32"
import "../x86"

guest_ai_update: x86.Func
guest_ai_probs: x86.Func
guest_ai_pattern_idle: x86.Func
guest_anim_start: x86.Func

ai_tier: i32 = 2 // the cap on a foe's tier
parry_on := true

// CCreature
CREATURE_AI :: 0x620
CREATURE_HEALTH :: 0x470 // f32
CREATURE_HEALTH_MAX :: 0x478 // f32
CREATURE_ID :: 0x8
CREATURE_ANIM :: 0x358 // the anim component, which owns the move queue
// The creature's combat AI.
AI_SELF :: 0x4
AI_TARGET :: 0xc // creature*
AI_AGGRESSION :: 0x7c // i32, 0..9
AI_PROB_HEAL :: 0x38 // f32, the combat AI template's ProbHeal
AI_BOSS :: 0x158 // rank.2da column boss; the game rolls heals only when set
// rank.2da columns the shipped AI rolls on (copied by 0x436b50).
AI_EVASION :: 0x160 // 0: the game never evades (0x43c8f5)
AI_SLAM :: 0x16c // percent odds of a power attack on a blocking target (0x437710)
AI_COMBO_BLOCK :: 0x174 // percent odds of blocking out of a hit reaction (0x43e985)
AI_HEAL_OFF :: 0x68 // nonzero while heals are disabled
PROB_HEAL :: 2 // heal's index in the action odds
CREATURE_CHI :: 0x488 // f32
CREATURE_HEAL_FRAMES :: 0x5bc // frames left of a heal; the game ends the heal at 0
CREATURE_STATS :: 0x1c
STATS_RANK :: 0xfc // the rank.2da row (GetRank 0x4369d0)
// The anim component: [this] is its creature.
ANIM_FLAGS_ACTION :: 0x41 // a move that starts: attacks, hits, blocks
ANIM_FLAGS_RECOVER :: 0x1 // an attack's recovery
// Creature states (0x4b81f0). The AI runs its current action only while the
// creature is in none of BUSY.
STATE_BLOCKING :: 0x11
STATE_HOLD :: 0x2c // set by a long move, a dodge or a hit for 2 s; the AI waits it out
STATES_BUSY :: [?]u32{STATE_BLOCKING, 0x1, STATE_HOLD} // blocking, ?, hold
// thiscall(state, add, param, f32 seconds), ret 0x10: adds the state for
// seconds, or with add 0 removes it.
CREATURE_SET_STATE :: 0x004be030

AI_ATTACK :: 0x0043a2a0 // thiscall(type), ret 4: 1 quick, 2 power, -1 its pick
AI_QUEUE :: 0x80 // the action stack*: count, capacity, entries of 24 bytes
QUEUE_PUSH :: 0x00439030 // thiscall(type, sub, f32 param, vec3), ret 0x18
QUEUE_ENTRY :: 24
ACTION_BLOCK :: 0x4a // type and sub of a block, its param in frames
SUB_BLOCK :: 1
CREATURE_HAS_STATE :: 0x004b81f0 // thiscall(id), ret 4
ATTACK_QUICK :: 1
ATTACK_POWER :: 2
CREATURE_EVADE :: 0x004c3070 // CCreature::DoEvade, thiscall(f32 x, f32 y, flag), ret 0xc
HIT_REACT :: 0x004442c0 // thiscall on the anim component (move, kind, 0, 0), ret 0x10
HIT_STAGGER :: 1 // the kind of a plain hit: a dmgfr* stagger

Tier :: struct {
	react, dodge, punish, anti_block, idle: f32, // dodge: a reaction's share that dodges
	parry:                                  f32, // odds a blow taken on the foe's block staggers the player
	recover:                                f32, // speed of the foe's hit and knockdown anims at full health
	block_frames:                           f32, // cap on a block's length; the game's run 45 to 150
	wary:                                   f32, // how much suspicion cuts a reaction's odds
	commit:                                 f64, // seconds a block is held before a power attack answers it
}
@(private = "file")
TIERS := [7]Tier {
	{react = 0, dodge = 0, punish = 0, anti_block = 0, idle = 1, block_frames = 150, recover = 1},
	{react = 0.15, dodge = 0.15, punish = 0.15, anti_block = 0.1, idle = 0.85, parry = 0.05, block_frames = 120, recover = 1.05},
	{react = 0.25, dodge = 0.25, punish = 0.25, anti_block = 0.15, idle = 0.7, parry = 0.1, block_frames = 105, recover = 1.1},
	{react = 0.35, dodge = 0.3, punish = 0.35, anti_block = 0.25, idle = 0.6, parry = 0.15, block_frames = 90, recover = 1.2},
	{react = 0.5, dodge = 0.35, punish = 0.5, anti_block = 0.35, idle = 0.45, parry = 0.25, block_frames = 70, wary = 0.4, commit = 0.3, recover = 1.3},
	{react = 0.65, dodge = 0.45, punish = 0.65, anti_block = 0.5, idle = 0.3, parry = 0.35, block_frames = 45, wary = 0.8, commit = 0.5, recover = 1.4},
	{react = 0.8, dodge = 0.55, punish = 0.8, anti_block = 0.6, idle = 0.2, parry = 0.45, block_frames = 30, wary = 1, commit = 0.6, recover = 1.5},
}
// Tier of each rank.2da row: 1 Default_BlockOnCombo and 12 Default_low_block
// (townsfolk, fodder) 1; 9 Default_Random (soldiers, bandits) and 5
// NPCwithBossEffects (students, ghosts) 2; 6 and 13 the medium blockers
// (arena fighters, golems) 3; 7 and 11 smart non-bosses (Lotus Assassins,
// demons) 4; 2 and 4 smart bosses and 8 Henchmen 5; 3 the Emperor and 10
// Death_Hand 6.
@(private = "file")
RANK_TIER := [14]int{1, 1, 5, 6, 5, 2, 3, 4, 5, 2, 6, 4, 1, 3}
// The setting's cap on a foe's tier.
@(private = "file")
TIER_CAP := [3]int{0, 3, 6}

ANTI_BLOCK_SEC :: 1.5
PARRY_SEC :: 0.2
SWING_SEC :: 1.0 // how long ago the parried foe may have started its swing
BAIT_SEC :: 1.0
HEALTH_KNEE :: 0.5 // share of max health a foe needs to recover faster
HEAL_TIER :: 3 // lowest tier that heals with chi without the boss flag
HEAL_CHI :: 5 // chi a foe needs to start a heal, the game's smallest heal
BURN :: 0.5 // suspicion added by a bait, out of 1
WARY_SEC :: 20 // seconds for full suspicion to fade

// The player's last attack, counted so each foe answers it once.
@(private = "file")
Player_Event :: struct {
	swing, recover: u32,
	power:          bool,
	swung:          time.Duration,
}
@(private = "file")
player_ev: Player_Event

// The player's block, for the parry window, and the foe that swung last.
@(private = "file")
Parry :: struct {
	blocking: bool,
	raised:   time.Duration,
	foe:      u32,
	swung:    time.Duration,
}
@(private = "file")
parry: Parry

@(private = "file")
Reaction :: enum {
	Block,
	Dodge,
	Punish,
	Anti_Block,
}

@(private = "file")
Foe :: struct {
	swing, recover: u32,
	anti_block:     time.Duration,
	seen:           time.Duration, // last update, for the suspicion's fade
	wary:           [Reaction]f32,
	last:           Maybe(Reaction), // the reaction a hit within BAIT_SEC burns
	acted:          time.Duration,
}
@(private = "file")
foes: map[u32]Foe

// AI update, thiscall on the AI's action queue with the creature as argument.
Ai_Update_0043df70 :: proc() {
	c := &x86.cpu
	q, cre := c.ecx, ld(c.esp + 0x4)
	magnet_seen(cre)
	coop_foe_seen(cre)
	if ai := ld(cre + CREATURE_AI); ai != 0 && coop_driven(cre) {
		coop_act(cre, ai)
	} else if ai != 0 {
		if tier := foe_tier(ai); tier > 0 {
			if p := world_player(); p != 0 && ld(ai + AI_TARGET) == p {persona_seen(cre, p, has_state(p, STATE_BLOCKING))}
			t := persona_tier(cre, TIERS[tier])
			ai_react(cre, ai, t)
			block_cap(q, t)
			if tier >= HEAL_TIER && ld(ai + AI_BOSS) == 0 {heal_chi(cre)}
		}
	}
	c.ecx = q
	guest_ai_update()
}

COOP_BLOCK_FRAMES :: 10 // a held block is renewed before it runs out

// Player 2's buttons on the henchman it drives, as the actions her AI
// would push: A a quick attack, X a power attack, B a dodge along the stick,
// RT held a block. Her own AI picks none (Ai_Probs) but runs what is pushed.
@(private = "file")
coop_act :: proc(cre, ai: u32) {
	@(static) last: bit_set[win32.Pad_Btn]
	held := coop_held
	down := held - last
	last = held
	// The hold the henchman's moves and hits keep on her would stop her AI
	// running what is pushed.
	if .RT in down || .A in down || .X in down {
		x86.cpu.ecx = cre
		win32.guest_call(CREATURE_SET_STATE, STATE_HOLD, 0, 0xffffffff, transmute(u32)f32(2))
	}
	if .RT in held {
		ai_block(ai, COOP_BLOCK_FRAMES)
	} else if .B in down {
		x, y := coop_evade_dir(cre)
		x86.cpu.ecx = cre
		win32.guest_call(CREATURE_EVADE, transmute(u32)x, transmute(u32)y, 0)
	} else if .A in down || .X in down {
		drop_attacks(ai)
		x86.cpu.ecx = ai
		win32.guest_call(AI_ATTACK, .A in down ? ATTACK_QUICK : ATTACK_POWER)
		coop_pressed = win32.host_now()
	} else if coop_pressed != 0 && time.duration_seconds(win32.host_now() - coop_pressed) > BUFFER_SEC {
		drop_attacks(ai)
		coop_pressed = 0
	}
}

SUB_STYLE_MOVE :: 5 // sub of an attack entry: plays the style move its type indexes

// When player 2's last attack was pushed, 0 once it played or ran out. An
// attack the hero is too busy for waits on the action stack; one press stays
// there at most BUFFER_SEC, as the player's does (buffer.odin), and a new one
// replaces it, so presses during a combo never pile up to replay late.
@(private = "file")
coop_pressed: time.Duration

// Drops the attack entries from the AI's action stack, keeping the others in
// their order.
@(private = "file")
drop_attacks :: proc(ai: u32) {
	q := ld(ai + AI_QUEUE)
	n, base := ld(q), ld(q + 8)
	k := u32(0)
	for i in u32(0) ..< n {
		e := base + i * QUEUE_ENTRY
		if ld(e + 4) == SUB_STYLE_MOVE {continue}
		if k != i {
			for w := u32(0); w < QUEUE_ENTRY; w += 4 {st(base + k * QUEUE_ENTRY + w, ld(e + w))}
		}
		k += 1
	}
	st(q, k)
}

// Action odds: thiscall on the AI with an out array of six f32, after the
// game's own state adjustments. Idle mass moves to attack.
Ai_Probs_0043c680 :: proc() {
	c := &x86.cpu
	ai, out := c.ecx, ld(c.esp + 0x4)
	guest_ai_probs()
	if coop_driven(ld(ai + AI_SELF)) {
		for i in u32(0) ..< 5 {sf(out + i * 4, 0)}
		sf(out + 5 * 4, 1)
		return
	}
	tier := foe_tier(ai)
	if tier >= HEAL_TIER {heal_odds(ai, out)}

	if ld(ai + AI_TARGET) != world_player() {return}
	t := foe_skill(ai)
	if t.idle < 1 {
		idle := lf(out + 5 * 4)
		sf(out + 5 * 4, idle * t.idle)
		sf(out, lf(out) + idle * (1 - t.idle))
	}
	persona_probs(ld(ai + AI_SELF), out)
}

// The game zeroes heal odds for any foe without the rank's boss flag. A tier
// HEAL_TIER foe holding at least HEAL_CHI chi gets its template's ProbHeal
// back, taken from the other actions in proportion. The heal itself is the
// game's: it fires below 80% health; heal_chi makes it cost chi.
@(private = "file")
heal_odds :: proc(ai, out: u32) {
	h := lf(ai + AI_PROB_HEAL)
	if ld(ai + AI_BOSS) != 0 || ld(ai + AI_HEAL_OFF) != 0 || h <= 0 || lf(out + PROB_HEAL * 4) > 0 {return}
	if lf(ld(ai + AI_SELF) + CREATURE_CHI) < HEAL_CHI {return}
	for i in u32(0) ..< 6 {sf(out + i * 4, lf(out + i * 4) * (1 - h))}
	sf(out + PROB_HEAL * 4, h)
}

// Health of each foe whose heal is running, as of the last AI update.
@(private = "file")
healing: map[u32]f32

// The game's heal costs no chi. A heal running on a foe that heal_odds lets
// heal takes one chi per health point it restored since the last update; when
// the chi runs out the health it could not pay for is taken back and the heal
// ends.
@(private = "file")
heal_chi :: proc(cre: u32) {
	hp := lf(cre + CREATURE_HEALTH)
	last, running := healing[cre]
	if ld(cre + CREATURE_HEAL_FRAMES) != 0 {
		healing[cre] = hp
	} else if running {
		delete_key(&healing, cre)
	}
	if !running || hp <= last {return}
	chi := lf(cre + CREATURE_CHI)
	if hp - last >= chi {
		sf(cre + CREATURE_HEALTH, last + chi)
		sf(cre + CREATURE_CHI, 0)
		st(cre + CREATURE_HEAL_FRAMES, 0)
		delete_key(&healing, cre)
		return
	}
	sf(cre + CREATURE_CHI, chi - (hp - last))
}

// Pattern idle: thiscall on the AI, (frames), ret 4; the wait between a
// pattern's attack runs.
Ai_Pattern_Idle_0043b0a0 :: proc() {
	c := &x86.cpu
	t := foe_skill(c.ecx)
	if t.idle < 1 && ld(c.ecx + AI_TARGET) == world_player() {
		frames := ld(c.esp + 0x4)
		st(c.esp + 0x4, u32(f32(frames) * t.idle))
	}
	guest_ai_pattern_idle()
}

// Anim component play: thiscall (name, speed, flags, ...). The player's
// attack starts ('m' and a digit) and recoveries are the events foes answer.
Anim_Start_0043fec0 :: proc() {
	c := &x86.cpu
	this := c.ecx
	cre, name, flags := ld(this), ld(c.esp + 0x4), ld(c.esp + 0xc)
	p := world_player()
	if cre != 0 && cre != p && is_reaction(name) {recover(cre, c.esp + 0x8)}
	if cre != 0 && p != 0 {
		m, d := x86.mem[name], x86.mem[name + 1]
		attack := m == 'm' && d >= '0' && d <= '9'
		if cre == p {
			if attack {
				switch flags {
				case ANIM_FLAGS_ACTION:
					player_ev.swing += 1
					player_ev.power = d == '3'
					player_ev.swung = win32.host_now()
					persona_swing(player_ev.power)
				case ANIM_FLAGS_RECOVER:
					player_ev.recover += 1
				}
			}
			player_block(name, flags)
		} else if attack && flags == ANIM_FLAGS_ACTION && ai_targets(cre, p) {
			parry.foe, parry.swung = cre, win32.host_now()
		} else if flags == ANIM_FLAGS_ACTION && is_hit(name) {
			if f, ok := &foes[cre]; ok {burn(f)}
		} else if flags == ANIM_FLAGS_ACTION && x86.mem[name] == 'b' && x86.mem[name + 1] == 'l' && x86.mem[name + 2] == 'k' {
			foe_parry(cre, p)
		}
		pace_anim(cre, p, name, flags, c.esp + 0x8)
		magnet_anim(cre, p, name, flags)
	}
	// The parries' hit reactions are guest calls that leave ecx clobbered.
	c.ecx = this
	guest_anim_start()
}

// One frame's reactions of a foe to the player's last events.
@(private = "file")
ai_react :: proc(cre, ai: u32, t: Tier) {
	p := world_player()
	if p == 0 || ld(ai + AI_TARGET) != p {return}
	now := win32.host_now()
	f, seen := &foes[cre]
	if !seen {
		foes[cre] = {swing = player_ev.swing, recover = player_ev.recover, seen = now}
		return
	}
	fade := f32(time.duration_seconds(now - f.seen) / WARY_SEC)
	for &w in f.wary {w = max(0, w - fade)}
	f.seen = now
	// A reaction pushed while busy would run late, out of its moment.
	busy := false
	for st in STATES_BUSY {if has_state(cre, st) {busy = true}}
	k := 0.5 + f32(clamp(i32(ld(ai + AI_AGGRESSION)), 0, 9)) / 18
	if f.swing != player_ev.swing {
		f.swing = player_ev.swing
		if !busy && ld(p + CREATURE_TARGET) == ld(cre + CREATURE_ID) && roll(t.react * k) {
			// A burned block shifts the share to dodges, a burned dodge back.
			dodge := clamp(t.dodge + t.wary * (f.wary[.Block] - f.wary[.Dodge]) * 0.5, 0, 1)
			if ld(ai + AI_EVASION) == 0 {dodge = 0}
			if dodge > 0 && (player_ev.power || roll(dodge)) {
				ai_evade(cre)
				acted(f, .Dodge, now)
			} else if !player_ev.power && roll(pct(ld(ai + AI_COMBO_BLOCK))) {
				ai_block(ai, t.block_frames)
				acted(f, .Block, now)
			}
		}
	}
	if f.recover != player_ev.recover {
		f.recover = player_ev.recover
		if !busy && roll(t.punish * k * (1 - t.wary * f.wary[.Punish])) {
			ai_call(AI_ATTACK, ai, ATTACK_QUICK)
			acted(f, .Punish, now)
		}
	}
	held := parry.blocking && time.duration_seconds(now - parry.raised) >= t.commit
	if time.duration_seconds(now - f.anti_block) > ANTI_BLOCK_SEC && !busy && held && has_state(p, STATE_BLOCKING) {
		f.anti_block = now
		if roll(t.anti_block * k * (1 - t.wary * f.wary[.Anti_Block]) * pct(ld(ai + AI_SLAM))) {
			ai_call(AI_ATTACK, ai, ATTACK_POWER)
			acted(f, .Anti_Block, now)
		}
	}
}

// A rank.2da percent column as odds.
@(private = "file")
pct :: proc(v: u32) -> f32 {
	return f32(min(v, 100)) / 100
}

// The foe's tier from its rank, a tier up while player 2 is in
// (coop_foes.odin), capped by the setting.
@(private = "file")
foe_tier :: proc(ai: u32) -> int {
	stats := ld(ld(ai + AI_SELF) + CREATURE_STATS)
	if stats == 0 {return 0}
	row := ld(stats + STATS_RANK)
	if row >= len(RANK_TIER) {return 0}
	return min(RANK_TIER[row] + (coop_p2_in() ? COOP_TIER : 0), TIER_CAP[ai_tier])
}

// The foe's tier as its personality spends it (persona.odin).
@(private = "file")
foe_skill :: proc(ai: u32) -> Tier {
	return persona_tier(ld(ai + AI_SELF), TIERS[foe_tier(ai)])
}

@(private = "file")
acted :: proc(f: ^Foe, r: Reaction, now: time.Duration) {
	f.last, f.acted = r, now
}

// A hit on the foe soon after its reaction: the reaction was baited.
@(private = "file")
burn :: proc(f: ^Foe) {
	r, ok := f.last.?
	if !ok || time.duration_seconds(win32.host_now() - f.acted) > BAIT_SEC {return}
	f.wary[r] = min(1, f.wary[r] + BURN)
	f.last = nil
}

// The anims a blow plays on its victim: dmg* staggers and pushbacks, kb* and
// kd* knockbacks.
is_hit :: proc(name: u32) -> bool {
	m, a, b := x86.mem[name], x86.mem[name + 1], x86.mem[name + 2]
	return m == 'd' && a == 'm' && b == 'g' || m == 'k' && (a == 'b' || a == 'd')
}

// The anims of taking a blow: hits and knockdowns (and their get-ups),
// block reactions blk?2 and step-backs blk?3, stuns.
@(private = "file")
is_reaction :: proc(name: u32) -> bool {
	m, a, b, d := x86.mem[name], x86.mem[name + 1], x86.mem[name + 2], x86.mem[name + 4]
	return is_hit(name) || m == 'b' && a == 'l' && b == 'k' && (d == '2' || d == '3') || m == 's' && a == 't' && b == 'u'
}

// Speeds a reaction anim up by the foe's tier while its health is at least
// HEALTH_KNEE of its max.
@(private = "file")
recover :: proc(cre, speed: u32) {
	ai := ld(cre + CREATURE_AI)
	if ai == 0 {return}
	t := TIERS[foe_tier(ai)]
	if t.recover <= 1 || lf(cre + CREATURE_HEALTH) < lf(cre + CREATURE_HEALTH_MAX) * HEALTH_KNEE {return}
	sf(speed, lf(speed) * t.recover)
}

// A block about to start is cut to the tier's length: the game's own run
// up to five seconds, which leaves a foe turtling under a mashed combo.
@(private = "file")
block_cap :: proc(q: u32, t: Tier) {
	n := ld(q)
	if n == 0 {return}
	e := ld(q + 8) + (n - 1) * QUEUE_ENTRY
	if ld(e + 4) != SUB_BLOCK {return}
	sf(e + 8, min(lf(e + 8), t.block_frames))
}

// The game's own block action (0x43c870) rolls its own odds and sizes the
// block from health, so it mostly refuses; the reaction pushes the entry it
// would, at the tier's length, unless a block is already current.
@(private = "file")
ai_block :: proc(ai: u32, frames: f32) {
	q := ld(ai + AI_QUEUE)
	if n := ld(q); n > 0 && ld(ld(q + 8) + (n - 1) * QUEUE_ENTRY + 4) == SUB_BLOCK {return}
	x86.cpu.ecx = q
	win32.guest_call(QUEUE_PUSH, ACTION_BLOCK, SUB_BLOCK, transmute(u32)frames, 0, 0, 0)
}

// A dodge to a random side.
@(private = "file")
ai_evade :: proc(cre: u32) {
	side: f32 = roll(0.5) ? 1 : -1
	x86.cpu.ecx = cre
	win32.guest_call(CREATURE_EVADE, transmute(u32)side, 0, 0)
}

// The player's block anims: blk* with flags 0x40 is the block raised (and
// replayed while held), with flags 0x41 a blow taken on it.
@(private = "file")
player_block :: proc(name, flags: u32) {
	if x86.mem[name] != 'b' || x86.mem[name + 1] != 'l' || x86.mem[name + 2] != 'k' {
		parry.blocking = false
		return
	}
	now := win32.host_now()
	switch flags {
	case 0x40:
		if !parry.blocking {parry.raised = now}
		parry.blocking = true
	case ANIM_FLAGS_ACTION:
		if parry_on && parry.blocking && parry.foe != 0 &&
		   time.duration_seconds(now - parry.raised) <= PARRY_SEC &&
		   time.duration_seconds(now - parry.swung) <= SWING_SEC {
			x86.cpu.ecx = ld(parry.foe + CREATURE_ANIM)
			win32.guest_call(HIT_REACT, 0, HIT_STAGGER, 0, 0)
			parry.foe = 0
		}
		parry.blocking = true
	}
}

// A player blow taken on a foe's block (blk* with flags 0x41): the foe may
// turn it, staggering the player through the same hit reaction.
@(private = "file")
foe_parry :: proc(cre, p: u32) {
	ai := ld(cre + CREATURE_AI)
	if ai == 0 || ld(ai + AI_TARGET) != p || ld(p + CREATURE_TARGET) != ld(cre + CREATURE_ID) {return}
	if time.duration_seconds(win32.host_now() - player_ev.swung) > SWING_SEC {return}
	k := 0.5 + f32(clamp(i32(ld(ai + AI_AGGRESSION)), 0, 9)) / 18
	if !roll(foe_skill(ai).parry * k) {return}
	x86.cpu.ecx = ld(p + CREATURE_ANIM)
	win32.guest_call(HIT_REACT, 0, HIT_STAGGER, 0, 0)
}

@(private = "file")
ai_targets :: proc(cre, p: u32) -> bool {
	ai := ld(cre + CREATURE_AI)
	return ai != 0 && ld(ai + AI_TARGET) == p
}

// Whether creature cre has state id. Calls guest code; ecx is lost.
has_state :: proc(cre, id: u32) -> bool {
	x86.cpu.ecx = cre
	return win32.guest_call(CREATURE_HAS_STATE, id) != 0
}

// The reactions' dice: seeded from the host clock, or with 0 under lockstep,
// where every peer must roll the same.
@(private = "file")
dice: rand.Default_Random_State
@(private = "file")
dice_set: bool

// At the start of lockstep play: the dice rolled again from 0.
ai_dice_reset :: proc() {dice_set = false}

@(private = "file")
roll :: proc(chance: f32) -> bool {
	if !dice_set {
		dice = rand.create(win32.lockstep ? 0 : u64(time.time_to_unix_nano(time.now())))
		dice_set = true
	}
	return rand.float32(rand.default_random_generator(&dice)) < chance
}

@(private = "file")
ai_call :: proc(fn, ai, arg: u32) {
	x86.cpu.ecx = ai
	win32.guest_call(fn, arg)
}
