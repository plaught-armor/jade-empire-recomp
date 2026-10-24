// Foe personalities, on top of the AI tiers (ai.odin). A tier says how much
// a foe can do; its personality says what it spends that on. Five archetypes
// weigh four traits: attack (punishes, presses, breaks guards, idles less),
// guard (blocks, longer blocks, parries), evasion (dodges) and cunning (reads
// baits, waits for a committed block). Each archetype's traits sum to four,
// a mean of one, so a mix moves skill between traits without adding any.
// A foe's mix blends a primary and a secondary archetype picked by its
// template (foes of one kind share a temperament) with a small third share
// and a shift between the two picked by its object id (no two are the same).
// Three things move the mix in a fight, and it is evened out again after:
// - mood: below HEALTH_KNEE health a foe leans toward the berserker, or, if
//   it guards more than it attacks, toward the trickster's desperate dodging;
// - the player's habits: attacks thrown fast draw the turtle, a block held
//   much of the time the brawler, power attacks the trickster, as far as the
//   foe's cunning lets it read them;
// - roles: of the foes on the player, the PRESS_N nearest press, and the
//   others hang back, their attack odds moved to moving, so they do not all
//   rush in at once.
// All of it is hashes and game events, so lockstep peers agree.
// WHY: docs/recompiler.md §10
package native

import "core:hash"
import "core:math"
import "core:time"
import "../win32"
import "../x86"

Trait :: enum {
	Attack,
	Guard,
	Evade,
	Cunning,
}
Traits :: [Trait]f32

Archetype :: enum {
	Brawler, // presses and breaks guards
	Duelist, // blocks, parries, reads
	Trickster, // dodges and baits
	Turtle, // waits behind its guard
	Berserker, // all attack
}
@(private = "file")
ARCHETYPES := [Archetype]Traits {
	.Brawler   = {.Attack = 1.5, .Guard = 0.7, .Evade = 0.7, .Cunning = 1.1},
	.Duelist   = {.Attack = 1.0, .Guard = 1.2, .Evade = 0.8, .Cunning = 1.0},
	.Trickster = {.Attack = 0.8, .Guard = 0.6, .Evade = 1.5, .Cunning = 1.1},
	.Turtle    = {.Attack = 0.6, .Guard = 1.6, .Evade = 0.8, .Cunning = 1.0},
	.Berserker = {.Attack = 2.0, .Guard = 0.6, .Evade = 0.6, .Cunning = 0.8},
}

PRIMARY :: 0.6 // share of the template's first archetype; the second gets the rest less THIRD
THIRD :: 0.1 // share of the archetype the object id picks
SHIFT :: 0.1 // most the object id moves between the first two
MOOD_MAX :: 0.5 // share of the mood archetype at no health
ADAPT_MAX :: 0.5 // share of the counter archetypes at full cunning and habit
HABIT_SEC :: 8 // seconds the player's habits are counted over
SPAM_RATE :: 1.2 // attacks a second that make a full habit
BLOCK_SHARE :: 0.5 // share of time blocking that makes a full habit
PRESS_N :: 2 // foes that press the player; one more while player 2 is in
WAIT_ATTACK :: 0.25 // a waiting foe's attack odds, the rest moved to moving
ROLE_SEC :: 0.5 // a foe not updated for this long has left the fight
PROB_ATTACK :: 0
PROB_MOVE :: 3

@(private = "file")
Mind :: struct {
	id:      u32, // the creature at this address, for reuse after a load
	base:    Traits,
	dist:    f32, // to the player, squared
	seen:    time.Duration,
	waiting: bool,
}
@(private = "file")
minds: map[u32]Mind

// The player's habits: counts of attacks and power attacks and the time
// blocking, each fading over HABIT_SEC.
@(private = "file")
Habits :: struct {
	swings, powers, blocked: f32,
	at:                      time.Duration,
}
@(private = "file")
habits: Habits

// The tier t of the foe cre, as its personality spends it. A tier with no
// skill (the original) is left as it is.
persona_tier :: proc(cre: u32, t: Tier) -> Tier {
	if t.react <= 0 {return t}
	m := mind(cre)
	tr := m.base
	// Mood.
	hp, top := lf(cre + CREATURE_HEALTH), lf(cre + CREATURE_HEALTH_MAX)
	if top > 0 && hp < top * HEALTH_KNEE {
		mood: Archetype = m.base[.Attack] >= m.base[.Guard] ? .Berserker : .Trickster
		tr = mix(tr, ARCHETYPES[mood], MOOD_MAX * (1 - max(hp, 0) / (top * HEALTH_KNEE)))
	}
	// The player's habits, read as far as the foe's cunning goes.
	spam, turtle, power := habit_levels()
	if sum := spam + turtle + power; sum > 0 {
		counter: Traits
		for tt in Trait {
			counter[tt] = (spam * ARCHETYPES[.Turtle][tt] + turtle * ARCHETYPES[.Brawler][tt] + power * ARCHETYPES[.Trickster][tt]) / sum
		}
		read := clamp(m.base[.Cunning] / ARCHETYPES[.Trickster][.Cunning], 0, 1)
		tr = mix(tr, counter, ADAPT_MAX * read * max(spam, turtle, power))
	}
	tr = even(tr)

	a, g, e, k := tr[.Attack], tr[.Guard], tr[.Evade], tr[.Cunning]
	out := t
	out.react = min(0.95, t.react * (g + e) / 2)
	if d := t.dodge * e + (1 - t.dodge) * g; d > 0 {out.dodge = t.dodge * e / d}
	out.punish = min(0.95, t.punish * a)
	out.anti_block = min(0.95, t.anti_block * (a + k) / 2)
	out.idle = clamp(1 - (1 - t.idle) * a, 0.05, 1)
	out.parry = min(0.95, t.parry * (g + k) / 2)
	out.block_frames = min(150, t.block_frames * g)
	out.wary = min(1, t.wary * k)
	out.commit = t.commit * f64(k)
	if m.waiting {
		out.punish *= 0.5
		out.anti_block = 0
		out.idle = t.idle
	}
	return out
}

// One AI update of the foe cre on the player p: its distance for the roles,
// and the player's habits, once a frame; blocking is whether p is.
persona_seen :: proc(cre, p: u32, blocking: bool) {
	now := win32.host_now()
	if now != habits.at {
		dt := f32(time.duration_seconds(now - habits.at))
		if habits.at == 0 {dt = 0}
		fade := x86.exp(-dt / HABIT_SEC)
		habits.swings *= fade
		habits.powers *= fade
		habits.blocked = habits.blocked * fade + (blocking ? dt : 0)
		habits.at = now
	}
	m := mind(cre)
	dx, dy := lf(cre + CREATURE_POS) - lf(p + CREATURE_POS), lf(cre + CREATURE_POS + 4) - lf(p + CREATURE_POS + 4)
	m.dist, m.seen = dx * dx + dy * dy, now
	nearer := 0
	for c, o in minds {
		if c == cre || time.duration_seconds(now - o.seen) > ROLE_SEC {continue}
		if o.dist < m.dist || o.dist == m.dist && c < cre {nearer += 1}
	}
	m.waiting = nearer >= PRESS_N + (coop_p2_in() ? 1 : 0)
}

// A player attack, power or not.
persona_swing :: proc(power: bool) {
	habits.swings += 1
	if power {habits.powers += 1}
}

// The action odds out of the foe cre: a foe hanging back moves most of its
// attack odds to moving.
persona_probs :: proc(cre, out: u32) {
	m, ok := minds[cre]
	if !ok || !m.waiting || time.duration_seconds(win32.host_now() - m.seen) > ROLE_SEC {return}
	attack := lf(out + PROB_ATTACK * 4)
	sf(out + PROB_ATTACK * 4, attack * WAIT_ATTACK)
	sf(out + PROB_MOVE * 4, lf(out + PROB_MOVE * 4) + attack * (1 - WAIT_ATTACK))
}

// The foe cre's mind, made on first sight from its template and id.
@(private = "file")
mind :: proc(cre: u32) -> ^Mind {
	id := ld(cre + CREATURE_ID)
	_, m, _, _ := map_entry(&minds, cre)
	if m.id == id && m.seen != 0 {return m}
	kind := hash.fnv32a(x86.mem[cre + CREATURE_RESREF:][:16])
	own_b := transmute([4]u8)id
	own := hash.fnv32a(own_b[:])
	first := Archetype(kind % len(Archetype))
	second := Archetype((u32(first) + 1 + kind / len(Archetype) % (len(Archetype) - 1)) % len(Archetype))
	third := Archetype(own % len(Archetype))
	shift := SHIFT * (f32(own >> 8 & 0xff) / 127.5 - 1)
	w: [Archetype]f32
	w[first] += PRIMARY + shift
	w[second] += 1 - PRIMARY - THIRD - shift
	w[third] += THIRD
	m^ = {id = id, seen = win32.host_now()}
	for a in Archetype {for t in Trait {m.base[t] += w[a] * ARCHETYPES[a][t]}}
	return m
}

// The player's habits, 0 to 1 each: fast attacks, blocking, power attacks.
@(private = "file")
habit_levels :: proc() -> (spam, turtle, power: f32) {
	spam = min(1, habits.swings / HABIT_SEC / SPAM_RATE)
	turtle = min(1, habits.blocked / HABIT_SEC / BLOCK_SHARE)
	power = habits.swings > 0 ? habits.powers / habits.swings * spam : 0
	return
}

@(private = "file")
mix :: proc(a, b: Traits, w: f32) -> Traits {
	out: Traits
	for t in Trait {out[t] = a[t] + (b[t] - a[t]) * w}
	return out
}

// Scales traits back to a mean of one.
@(private = "file")
even :: proc(tr: Traits) -> Traits {
	sum: f32
	for v in tr {sum += v}
	out := tr
	if sum > 0 {for &v in out {v *= len(Trait) / sum}}
	return out
}
