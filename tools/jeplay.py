#!/usr/bin/env python3
"""Play-automation driver over the control channel. WHY: docs/modding.md §4

Usage: jeplay.py <ctl dir> <game dir> <command> [args] [--reply TEXT]...
  --reply TEXT      in every conversation the command meets (a use, travel or
                    talk), a reply containing TEXT is taken first
  init              create the script slots in override/ (then restart the game)
  query 'EXPR'      run `return EXPR` (an Int or String engine call) and print it
  do 'STMT; ...'    run engine call statements as the player
  goto TAG          jump the player to the object tagged TAG
  talk [N] [TEXT...] advance conversations and cutscenes until over (at most N
                    steps); a reply containing one of the TEXTs is taken first
  use TAG          use the nearest object tagged TAG (door, chest, shrine) as a click does,
                    standing at the engine's use point for it
  face TAG          turn the player toward the nearest object tagged TAG with the mouse
  ask TAG           have the object tagged TAG start its conversation with the player
  fight [N]         fight until combat ends (at most N rounds); heals when low
  walk X Y          walk the player to world (X, Y) with the stick along a grid route
  travel X Y        walk to (X, Y), fighting, talking and closing popups on the way
  walkto TAG        walk the player to the use point of the nearest object tagged TAG
  cross TAG         walk into the area transition trigger tagged TAG until the area loads
  pos               print the player's world x y
  recover           chi heal to full health while chi lasts (travel does this
                    after each fight)
  anims [TAG]       print the animations the player (or the object tagged TAG) plays
  panels            print the ids of the open GUI panels
  popups            close open notice popups with the attack button
  settle            wait until a movie or area load is over
  minigame [N]      play a flying minigame: fire held, sweeping side to side
  save              quick save (F5) a clean state: refuses unless idle, then clears
                    the action queues of the player and of every object a do or
                    ask named, so no test command is written into the save

Each command is assembled into the next of SLOTS script slots,
override/zz_c00.ncs .. zz_c63.ncs, in turn, and run there. The slots must exist
when the game starts (override/ is indexed once at startup). A deferred command
(AssignCommand, DelayCommand, ActionDoCommand) keeps only its script's name and
the engine reads that file again when the command fires, so a slot is not
rewritten until SLOTS - 1 later commands have run. WHY: docs/modding.md §3
State comes from the engine (GetIsInCombat, GetHealth, GetIsInConversation),
never from screen pixels.
"""
import ast
import json
import math
from collections import namedtuple
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hexgrid  # noqa: E402
import jectl  # noqa: E402
import ncs  # noqa: E402
import twoda  # noqa: E402

SLOT_NAME = "zz_c%02d"  # script resref of slot i
SLOTS = 64             # slots used in turn; see the module doc
SLOT_NEXT = "slot"     # file in the ctl dir: index of the slot the next command uses
SLOT_INIT = "return GetIsObjectValid(GetPlayer())"  # placeholder content of a new slot
FRAMES_ATTACK = 6      # frames a click is held, then released for as long
HEAL_FRACTION = 0.4    # chi heal below this share of maximum health
FRAMES_STRONG = 30     # frames a strong attack's wind-up and swing take before the next input
LIGHT_COMBO = 3        # light attacks per round
RECOVER_HEALS = 4      # chi heals one recover tries at most
FRAMES_HEAL = 60       # Left Shift held this long channels one chi heal (1 chi per health)
CHI_MIN = 10           # chi below which a heal is not tried; the player blocks instead
FRAMES_BLOCK = 45      # frames Space is held for one blocking round
FRAMES_GUARD = 20      # frames Space is held against a telegraphed blockable attack
FRAMES_EVADE = 24      # frames an evade (the stick pushed twice) takes
FRAMES_FLICK = 4       # frames the stick is pushed to start an evade
# Player base-channel animations in which block can rise but has not: Space
# held from before such a state does not block; a new press does.
UNGUARDED_ANIMS = ("ready", "cwalk", "crun", "run", "pause", "observe")
EVADE_METHOD = "Evade Method=2"  # JadeEmpire.ini [InputOptions]: block + direction evades
GUARD_ANIM = "blk"     # AS rows whose anim starts so are the style's block, not an attack
OPENING_ANIMS = ("dmg", "kback", "kd")  # hit reactions: the foe cannot attack or block
RECOVERY_SUFFIX = "tran"  # an attack's recovery anim (m2tran, m4tran): the foe is open
GUARD_CHAIN = 12       # blockable attacks one held block answers before it is dropped
LEARN_FILE = "fightlearn.json"  # file in the ctl dir: what each answer to each foe anim cost (see choose)
ANSWERS = ("block", "side", "back")  # answers to an attack, in the order tried while none has cost
ANSWER_WINDOW = 45     # frames after an answer in which a hit counts against it
NOT_ATTACKS = OPENING_ANIMS + (GUARD_ANIM, "cddg", "face") + UNGUARDED_ANIMS  # anims a hit is never blamed on
PATIENCE = 3           # rounds guarded waiting for an opening before attacking anyway
CALM_ROUNDS = 3        # rounds out of combat before the fight counts as over
FRAMES_TALK = 90       # frames between dialog advances
TALK_STEPS = 200       # dialog advances a talk command makes at most by default; story
                       # dialogs run past 60 lines (the Spirit Thief lesson in Tien's Landing)
FRAMES_NUDGE = 4       # frames a step key is held to move the camera after a jump
TALK_CLICK = (160, 377)  # the first reply line in the 640x480 dialog layout
# Guest layout of the conversation reply panel. WHY: docs/modding.md §5
APP = 0x76C924         # global: the client app
APP_GUI = 0xB4         # app -> GUI manager
GUI_PANELS = 0x8C      # GUI manager -> table of open panels by id (0x6d entries)
GUI_CURSEL = 0x64      # GUI manager -> the CGuiPanel.LTI_CURSELOBJ panel (the use marker)
CURSEL_OBJ = 0x120     # that panel -> id of the object a click uses, NO_OBJECT when none
NO_OBJECT = 0xFFFFFFFF
OBJECT_TYPE_CREATURE = 2  # GetObjectType of an NPC; Jade renumbered the NWN values (nwscript.nss)
FACE_TRIES = 4         # turns toward an object before giving up on highlighting it
TARGET_CANDIDATES = 32 # most objects the engine's selector (0x461970) ranks, so Tab presses that visit them all
# Mouse-look: the engine recentres the cursor every frame and turns the player
# by the DirectInput motion. WHY: docs/modding.md §4
MOUSE = 0x75B528       # global: the game's mouse state (this of 0x51cea0)
MOUSE_CENTER = 0x10    # -> the point the cursor is recentred on, two i32 (screen pixels)
TURN_GAIN = 0.309      # degrees the player turns clockwise per pixel of rightward motion, measured in j02_ruins
TURN_PX = 100          # pixels per move at most; a 200-pixel move turns only 47 degrees, not 62
TURN_TOL = 2.0         # degrees; a facing this close to the target counts as facing it
TURN_STEPS = 12        # mouse moves one face takes at most
FRAMES_TURN = 4        # frames for a move to turn the player
PANEL_REPLY = 0x17     # "lti_convorep", the bottom bar with the reply list
PANEL_XY = 0x04        # panel, list box and item: x, y, w, h as four i32
LISTBOX = 0xD4         # reply panel -> its ListBoxReply control
REPLY_COUNT = 0x5C4    # reply panel -> number of reply items
REPLY_ITEMS = 0x5CC    # reply panel -> array of item pointers
ITEM_TEXT = 0x1B8      # item -> CExoString {char *, length with the NUL}
REPLIES_MAX = 16
REPLY_INSET = 24       # pixels right of an item's left edge where it is clicked
TEXT_MAX = 1024
PANEL_MOVIE = 0x41     # CPanelLoadingScreen, open while a movie plays
GUI_SIZE = (640, 480)  # the GUI's virtual screen, the size of a full-screen panel
# Notice panels that block movement until the attack button closes them:
# "You received" and the tutorial text box, seen together after the toad.
POPUPS = (0x18, 0x43)
PANEL_PAUSED = 0x3d    # PAUSED notice; Return resumes the game
PANEL_DEATH = 0x40     # death panel: the walk is over
POPUPS_MAX = 8         # popups closed in one go at most
FRAMES_POPUP = 20      # frames after a close for the next popup to come up
PANEL_MINIGAME = 0x5A  # the flying minigame's HUD, open while it runs
SWEEP_STEPS = 12       # walk steps the minigame ship holds one direction
MINIGAME_STEPS = 6000  # walk steps a minigame takes at most by default
FRAMES_SETTLE_WAIT = 30  # frames between loading-panel checks
SETTLE_STEPS = 400     # checks before a movie or load counts as hung (~6.5 min)
TRAVEL_LEGS = 12       # interruptions one travel command handles at most
FIGHT_ROUNDS = 120     # rounds a fight takes at most when travel starts it
PANEL_COUNT = 0x6D     # panel ids; the lookup 0x55d9f0 rejects 0x6d
PANEL_NAME = 0x1C      # panel field: pointer to its "CGuiPanel.<NAME>" string
PANEL_NAME_MAX = 48    # bytes read for a panel name
LEDGER = "touched"     # file in the ctl dir: tags of objects test commands named
TAG_LITERAL = re.compile(r'GetObjectByTag\(\s*"([^"]*)"')
SAVE_FILE = os.path.join("Save", "Quick Save", "save.sac")
FRAMES_SETTLE = 30     # frames for cleared queues to take effect before saving
FRAMES_SAVE = 120      # frames a quick save takes to write
WAKE_POINTS = ((300, 200), (320, 240))  # 640x480 pointer moves that put input back in keyboard mode
REACH = 1.2            # metres between centres; farther targets are closed on with the stick (bodies stop about 1.0 apart; punches reach little past that)
CLOSE_STEPS = 12       # stick steps one close_in takes at most
TARGET = "GetPlayerCreatureCombatTarget()"
STR_MAX = 256         # characters query_str reads at most
# Characters query_str can tell apart: printable ASCII. Any other reads as "?".
STR_ALPHABET = "".join(chr(c) for c in range(0x20, 0x7F))
ANIM_CHANNELS = 3      # model animation channels the anims control command reports
PLAYER_GONE = "no object tagged PLAYER"  # control-channel error while the player object is absent (area swap)
MODEL_GONE = "has no creature model"  # end of the anims error for a creature out of the scene
ID_DIGITS = 8          # hex digits of an object id in ObjectToString's text
# The player's state one fight round reads, as (key, Int expression).
PLAYER_STATE = (
    ("dead", "GetIsDead(GetPlayer())"),
    ("talk", "GetIsInConversation(GetPlayer()) + GetInCutsceneMode()"),
    ("combat", "GetIsInCombat()"),
    ("hp", "GetHealth(GetPlayer())"),
    ("top", "GetMaxHealth(GetPlayer())"),
    ("chi", "GetChi(GetPlayer())"),
)
# A creature's state, as (key, Int expression with %s for the creature).
# mm: millimetres from the player.
CREATURE_STATE = (
    ("valid", "GetIsObjectValid(%s)"),
    ("dead", "GetIsDead(%s)"),
    ("hp", "GetHealth(%s)"),
    ("style", "GetCurrentStyle(%s)"),
    ("enemy", "GetIsEnemy(GetPlayer(), %s)"),
    ("mm", "FloatToInt(GetDistanceBetween(GetPlayer(), %s) * 1000.0)"),
    ("digits", "GetStringLength(ObjectToString(%s))"),
)
OBJECT_CREATURE = 2    # object type: the class field of an object id (bits 27..31)
FOE_SCAN = 12          # nearest creatures examined for a foe
TAG_SCAN = 16          # objects sharing one tag examined for the nearest
FOE_RANGE = 30         # metres; creatures farther are not counted as foes
THREAT_RANGE = 3.5     # metres; foes this near besides the one fought are watched too
HIT_FOES = 6           # foes note_hit locates: 2 positions each + 3 for the player within SLOTS // 4
HOSTILE_MAX = 10       # reputation toward the player at or below which a creature is hostile
# One Int for a scanned creature: -1 when invalid, else millimetres from the
# player * 4 + 2 when hostile + 1 when dead (NWScript comparisons give 0 or 1).
SCAN_PACKED = ("GetIsObjectValid(%s) * (FloatToInt(GetDistanceBetween(GetPlayer(), %s) * 1000.0) * 4"
               " + (GetIsEnemy(GetPlayer(), %s) <= " + str(HOSTILE_MAX) + ") * 2 + GetIsDead(%s) + 1) - 1")
PEEK_CHUNK = 4096      # bytes per peek (the control channel's limit)
STICK = 32000          # left stick deflection while walking (of 32767)
FRAMES_STEP = 8        # frames the stick is held per walking step
APP_SCENE = 0xA0       # app -> scene holder whose +0x124 is the game camera (SetCameraFacing 0x492e80)
SCENE_CAMERA = 0x124
CAMERA_POS = 0x7C      # camera -> world position, three floats
RUN_STEP = 0.19        # metres the player runs per frame the stick is held, measured in j02_ruins
STUCK_DIST = 0.05      # metres closer to the waypoint STUCK_STEPS steps must get
STUCK_STEPS = 8        # steps in a row without progress before replanning or giving up
REPLANS = 3            # replans one walk makes around unmapped obstacles before giving up
OBSTACLE_AHEAD = 1.0   # metres ahead of a stuck player where the unmapped obstacle is put
OBSTACLE_RADIUS = 0.9  # metres of grid blocked around it
BAND_CELLS_MAX = 4096  # 0xfe cells one hardened band blocks at most
ARRIVE = 0.6           # metres from a waypoint at which it counts as reached
WALK_STEPS = 800       # steps one walk takes at most
SNAP_RINGS = 6         # hex steps a blocked walk end may move to reach an open cell


class Game:
    def __init__(self, ctl, game):
        self.ctl = ctl
        self.game = game
        self.styles = {}  # combat style -> {anim: AS row} (see telegraph)
        self.last = None  # (player hp, player base channel) at the last swing (see note_hit)
        self.frame = 0    # frame number at the last swing
        self.answer = None  # (learn key, answer, frame) of the last answer given (see answered_with)
        self.learned = load_learned(ctl)  # "style:anim" -> {answer: [tries, damage]} (see choose)
        self.prefer = ()  # reply texts every talk takes first (--reply)
        missing = [p for p in slot_paths(game) if not os.path.exists(p)]
        if missing:
            raise SystemExit("%s missing: run init, then restart the game" % missing[0])

    def send(self, line):
        r = jectl.send(self.ctl, line)
        if not r.startswith("ok"):
            raise SystemExit("%s -> %s" % (line, r))
        return r

    def run(self, src):
        """Assemble src into the next slot and run it as the player; (type, value)."""
        code = ncs.assemble(src)
        i = self.next_slot()
        with open(slot_paths(self.game)[i], "wb") as f:
            f.write(code)
        w = self.send("exec " + SLOT_NAME % i).split()
        if len(w) != 4 or w[1] != "1":
            raise SystemExit("exec failed: %s" % " ".join(w))
        return int(w[2]), int(w[3])

    def next_slot(self):
        """Index of the slot to write now; advances the one stored in the ctl dir."""
        path = os.path.join(self.ctl, SLOT_NEXT)
        try:
            with open(path) as f:
                i = int(f.read())
        except FileNotFoundError:
            i = 0
        assert 0 <= i < SLOTS, i
        with open(path, "w") as f:
            f.write(str((i + 1) % SLOTS))
        return i

    def batch(self, lines, allow=None):
        """Send command lines to run in one frame (jectl.send_batch); answers.
        An error answer ending in allow is returned, any other raises."""
        r = jectl.send_batch(self.ctl, lines)
        for line, a in zip(lines, r):
            if not a.startswith("ok") and not (allow and a.startswith("err") and a.endswith(allow)):
                raise SystemExit("%s -> %s" % (line, a))
        return r

    def query(self, expr):
        return self.queries([expr])[0]

    def queries(self, exprs, extra=(), allow=None):
        """Run `return EXPR` for each Int expression, all in one frame; the
        values in order. Command lines in extra go in the same batch, before
        the scripts, and their answers follow the values (an answer may be an
        error ending in allow, see batch; such a value is None). Each expression takes
        the next slot, so a batch stays well under SLOTS (a slot a deferred
        command names must not be rewritten)."""
        assert 0 < len(exprs) <= SLOTS // 4, len(exprs)
        lines = list(extra)
        for e in exprs:
            i = self.next_slot()
            with open(slot_paths(self.game)[i], "wb") as f:
                f.write(ncs.assemble("return " + e))
            lines.append("exec " + SLOT_NAME % i)
        answers = self.batch(lines, allow)
        out = []
        for e, a in zip(exprs, answers[len(extra):]):
            if allow and a.startswith("err") and a.endswith(allow):
                out.append(None)
                continue
            w = a.split()
            if len(w) != 4 or w[1] != "1":
                raise SystemExit("exec failed for %s: %s" % (e, a))
            if int(w[2]) != ncs.TYPE["Int"]:
                raise SystemExit("%s: result type %s" % (e, w[2]))
            out.append(int(w[3]))
        return out + answers[:len(extra)]

    def query_str(self, expr):
        """The value of String expression expr. Script results are Int only
        (the VM keeps no other type), so this reads the length, then each
        character as its index in STR_ALPHABET, a batch of queries at a time.
        expr is evaluated once per character: it must not change meanwhile.
        WHY: docs/modding.md §2"""
        n = self.query("GetStringLength(%s)" % expr)
        assert 0 <= n <= STR_MAX, (expr, n)
        alphabet = '"%s"' % STR_ALPHABET.replace("\\", "\\\\").replace('"', '\\"')
        out = []
        for k in range(0, n, SLOTS // 4):
            idx = self.queries(["FindSubString(%s, GetSubString(%s, %d, 1))" % (alphabet, expr, i)
                                for i in range(k, min(n, k + SLOTS // 4))])
            out += [STR_ALPHABET[i] if 0 <= i < len(STR_ALPHABET) else "?" for i in idx]
        return "".join(out)

    def touch(self, src):
        """Record in the ledger every tag src names, as a command may have
        queued actions on that object. WHY: docs/modding.md §4"""
        tags = TAG_LITERAL.findall(src)
        if tags:
            with open(os.path.join(self.ctl, LEDGER), "a") as f:
                f.write("".join(t + "\n" for t in tags))

    def touched(self):
        """Tags in the ledger, each once, in first-seen order."""
        try:
            with open(os.path.join(self.ctl, LEDGER)) as f:
                return list(dict.fromkeys(t for t in f.read().split("\n") if t))
        except FileNotFoundError:
            return []

    def frames(self, n):
        self.send("wait %d" % n)

    def peek(self, addr, n):
        """n bytes of guest memory at addr."""
        r = self.send("peek %x %d" % (addr, n)).split()
        if len(r) != 2 or len(r[1]) != 2 * n:
            raise SystemExit("peek %#x %d -> %s" % (addr, n, " ".join(r)))
        return bytes.fromhex(r[1])

    def u32(self, addr):
        return struct.unpack("<I", self.peek(addr, 4))[0]

    def rect(self, addr):
        """(x, y, w, h) of a GUI control at addr."""
        return struct.unpack("<4i", self.peek(addr + PANEL_XY, 16))


def attack(g, button="L", cs=None):
    """One attack without moving the mouse (a move turns the camera): light
    with L, strong with R. With cs (creatures, see creature), cs are watched
    while the button is held and released; the attack one telegraphs is
    returned at once (the button released), else None."""
    g.send("btn %s down" % button)
    try:
        move = watch(g, cs, FRAMES_ATTACK)
    finally:
        g.send("btn %s up" % button)
    return move or watch(g, cs, FRAMES_ATTACK)


def hold(g, key, frames, cs):
    """Hold key for frames frames while watching cs (see watch); the attack
    one telegraphs, which ends the hold early, or None."""
    g.send("down " + key)
    try:
        return watch(g, cs, frames)
    finally:
        g.send("up " + key)


def id_expr(expr):
    """An Int expression for the id of the object expr names. A script
    returns only ints (the VM's return cell reads type 0 for an object), so
    ObjectToString's 8 lower-case hex digits are decoded in the script; the top
    digit's product wraps in the VM's 32-bit int, so mask the value with
    0xFFFFFFFF. WHY: docs/modding.md §2"""
    s = "ObjectToString(%s)" % expr
    digit = 'FindSubString("0123456789abcdef", GetSubString(%s, %d, 1))'
    return " + ".join("%s * %d" % (digit % (s, k), 16 ** (ID_DIGITS - 1 - k))
                      for k in range(ID_DIGITS))


def creature(g, expr):
    """The CREATURE_STATE values of the creature expr names, read in one
    frame, plus "expr" and "id" (its object id)."""
    v = g.queries([e.replace("%s", expr) for _, e in CREATURE_STATE] + [id_expr(expr)])
    c = dict(zip([k for k, _ in CREATURE_STATE], v), expr=expr, id=v[-1] & 0xFFFFFFFF)
    assert not c["valid"] or c["digits"] == ID_DIGITS, c
    return c


def foe(g, gone):
    """The creature to fight (see creature, plus "label": how it was found),
    or None. Creatures whose ids are in gone (see anims) are passed over.

    The combat target while it lives; otherwise the nearest live hostile
    creature within FOE_RANGE. Fights spread out, so the engine's target is
    often unset while a group is still coming. WHY: docs/modding.md §4
    """
    c = creature(g, TARGET)
    if c["valid"] and not c["dead"] and c["id"] not in gone:
        return dict(c, label="target")
    for n in range(FOE_SCAN):
        c = creature(g, "GetNearestObject(GetPlayer(), %d, %d)" % (OBJECT_CREATURE, n))
        if not c["valid"] or c["mm"] > FOE_RANGE * 1000:
            return None
        if not c["dead"] and c["enemy"] <= HOSTILE_MAX and c["id"] not in gone:
            return dict(c, label="nearest creature %d" % n)
    return None


def near_foes(g, c, gone):
    """The live hostile creatures other than c within THREAT_RANGE, nearest
    first, each a dict of "expr" and "id". A group attacks from several sides,
    so all of them are watched, not only the one fought. Two round trips: one
    packs each of the FOE_SCAN nearest creatures into one Int (see
    SCAN_PACKED), one reads the ids of the near hostiles; a frame per
    creature (see creature) left the player unguarded for a dozen frames
    each round. WHY: docs/modding.md §5"""
    exprs = ["GetNearestObject(GetPlayer(), %d, %d)" % (OBJECT_CREATURE, n) for n in range(FOE_SCAN)]
    packed = g.queries([SCAN_PACKED.replace("%s", e) for e in exprs])
    hits = []
    for e, v in zip(exprs, packed):
        if v < 0 or v // 4 > THREAT_RANGE * 1000:
            break
        if v & 3 == 2:
            hits.append(e)
    if not hits:
        return []
    ids = g.queries([id_expr(e) for e in hits[:SLOTS // 4]])
    return [dict(expr=e, id=i & 0xFFFFFFFF) for e, i in zip(hits, ids)
            if i & 0xFFFFFFFF != c["id"] and i & 0xFFFFFFFF not in gone]


def parse_anims(reply):
    """The anims command's reply as lists of (name, time, speed, flags) per
    model channel (base, head, weapon). WHY: docs/modding.md §5"""
    w = reply.split()
    chans, k = [], 1
    for _ in range(ANIM_CHANNELS):
        assert w[k] == "|", w
        n = int(w[k + 1])
        rows = w[k + 2:k + 2 + 4 * n]
        chans.append([(rows[i], float(rows[i + 1]), float(rows[i + 2]), int(rows[i + 3], 16))
                      for i in range(0, 4 * n, 4)])
        k += 2 + 4 * n
    return chans


def anims(g, ref):
    """The animations a creature plays now (see parse_anims), or None when it
    has no model: a foe that flees the fight leaves the scene while its object
    stays valid, alive and hostile. ref is a hex object id or a tag."""
    r = jectl.send(g.ctl, "anims %s" % ref)
    if r.startswith("err") and r.endswith(MODEL_GONE):
        return None
    if not r.startswith("ok"):
        raise SystemExit("anims %s -> %s" % (ref, r))
    return parse_anims(r)


def telegraph(g, style, base):
    """The attack a creature of combat style style is winding up or swinging,
    read from the animations of its model's base channel (anims) and the
    style's AS table: {"label", "anim", "unblockable", ...} or None. Rows
    sharing an anim count as unblockable when any is. WHY: docs/modding.md §5"""
    if style not in g.styles:
        moves = {}
        for r in twoda.style_attacks(g.game, style):
            a = r["anim"].lower()
            if a.startswith(GUARD_ANIM):
                continue
            u = int(r["unblockable"] or 0) or int(moves.get(a, {}).get("unblockable", 0))
            moves[a] = dict(r, unblockable=u)
        g.styles[style] = moves
    for name, _, _, _ in base:
        n = name.lower()
        if n in g.styles[style]:
            return g.styles[style][n]
        # An anim outside the AS table that has hit the player (style 98's
        # m1tran lands through a held block) is an attack too.
        # WHY: docs/modding.md §5
        if learn_key(style, n) in g.learned:
            return {"label": n, "anim": n, "unblockable": 0}
    return None


def swing(g, cs):
    """Read the base-channel animation of each creature in cs once, all in
    one round trip (answered in the next frame the port presents):
    (frame number, the first attack one telegraphs or None). The attack is
    its AS row plus "by", the creature. Creatures whose model is gone are
    passed over. WHY: docs/modding.md §5"""
    # A foe can change style mid-fight (the Two Rivers lieutenant uses
    # three), so the style is read with the animation. WHY: docs/modding.md §5
    n = len(cs)
    v = g.queries(["GetCurrentStyle(%s)" % c["expr"] for c in cs] + ["GetHealth(GetPlayer())"],
                  ["frame", "anims PLAYER", "states PLAYER"] + ["anims %08x" % c["id"] for c in cs],
                  MODEL_GONE)
    styles, hp, fr, me, st, replies = v[:n], v[n], v[n + 1], v[n + 2], v[n + 3], v[n + 4:]
    g.frame = int(fr.split()[1])
    note_hit(g, cs, hp, (parse_anims(me)[0], st.split()[2:]), styles, replies)
    for c, style, a in zip(cs, styles, replies):
        if a.startswith("err") and a.endswith(MODEL_GONE):
            continue
        move = telegraph(g, style, parse_anims(a)[0])
        if move is not None:
            return g.frame, dict(move, by=c, style=style)
    return int(fr.split()[1]), None


def note_hit(g, cs, hp, mine, styles, replies):
    """Print a line when the player's hp fell since the last swing: the
    player's base channel and state ids (the states command; 9 blocking)
    then and now, and per foe in cs its style, base channel, distance and
    bearing off the player's facing (0 ahead, +left). mine: (base channel,
    state ids). Records (hp, mine) in g.last. WHY: docs/modding.md §5"""
    last, g.last = g.last, (hp, mine)
    if last is None or hp >= last[0]:
        return
    cs = cs[:HIT_FOES]
    exprs = ["FloatToInt(GetFacing(GetPlayer()) * 1000.0)"] + [
        "FloatToInt(GetPosition(%s).%s * 1000.0)" % (o, a)
        for o in ["GetPlayer()"] + [c["expr"] for c in cs] for a in ("x", "y")]
    v = [x / 1000.0 for x in g.queries(exprs)]
    f, p = v[0], v[1:3]
    blame(g, last[0] - hp, last[1][0], [(math.dist(p, v[3 + 2 * k:5 + 2 * k]), style, a)
                                        for k, (style, a) in enumerate(zip(styles[:len(cs)], replies))])
    print("  hit: -%d hp to %d, player was %s [%s] now %s [%s]" % (
        last[0] - hp, hp, " ".join("%s@%.2f" % r[:2] for r in last[1][0]), " ".join(last[1][1]),
        " ".join("%s@%.2f" % r[:2] for r in mine[0]), " ".join(mine[1])))
    for k, (c, style, a) in enumerate(zip(cs, styles, replies)):
        q = v[3 + 2 * k:5 + 2 * k]
        rel = (math.degrees(math.atan2(q[1] - p[1], q[0] - p[0])) - f + 180.0) % 360.0 - 180.0
        base = "-" if a.startswith("err") else " ".join("%s@%.2f" % r[:2] for r in parse_anims(a)[0])
        print("    foe %x style %d at %.1f m bearing %+.0f: %s" % (
            c["id"], style, math.dist(p, q), rel, base))


def learn_key(style, anim):
    """Key of the learned table for anim played by a creature of style."""
    return "%d:%s" % (style, anim.lower())


def load_learned(ctl):
    """The learned table saved in ctl (see LEARN_FILE), empty when none is."""
    path = os.path.join(ctl, LEARN_FILE)
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return json.load(f)


def save_learned(g):
    with open(os.path.join(g.ctl, LEARN_FILE), "w") as f:
        json.dump(g.learned, f, indent=1, sort_keys=True)


def choose(g, move):
    """The answer (one of ANSWERS) to move that has cost least damage per
    try so far; untried answers cost nothing, so each is tried in turn once
    the ones before it have let a hit through. Block is never chosen against
    an unblockable attack. WHY: docs/modding.md §5"""
    stats = g.learned.get(learn_key(move["style"], move["anim"]), {})
    options = ANSWERS[1:] if move["unblockable"] else ANSWERS

    def cost(a):
        n, d = stats.get(a, (0, 0))
        return d / n if n else 0.0
    return min(options, key=cost)


def answered_with(g, move, answer):
    """Count one try of answer against move; a hit within ANSWER_WINDOW
    frames is charged to it (see blame)."""
    key = learn_key(move["style"], move["anim"])
    row = g.learned.setdefault(key, {}).setdefault(answer, [0, 0])
    row[0] += 1
    g.answer = (key, answer, g.frame)


def blame(g, dmg, mine, foes):
    """Charge a hit of dmg to the answer given within ANSWER_WINDOW frames,
    else to the anim of the nearest foe that is attacking (foes: (distance,
    style, anims reply)), answered by "block" when the player's base channel
    mine shows a block, else "none". A blamed anim is an attack from then on
    (see telegraph). WHY: docs/modding.md §5"""
    if g.answer is not None and g.frame - g.answer[2] <= ANSWER_WINDOW:
        key, answer = g.answer[:2]
        g.learned[key][answer][1] += dmg
    else:
        attacking = [(d, style, n) for d, style, a in foes if not a.startswith("err")
                     for n, _, _, _ in parse_anims(a)[0] if not n.lower().startswith(NOT_ATTACKS)]
        if not attacking:
            print("  learn: -%d hp, no attacking foe to blame" % dmg)
            return
        _, style, n = min(attacking)
        key = learn_key(style, n)
        answer = "block" if any(m.lower().startswith(GUARD_ANIM) for m, _, _, _ in mine) else "none"
        row = g.learned.setdefault(key, {}).setdefault(answer, [0, 0])
        row[0] += 1
        row[1] += dmg
    print("  learn: %s %s now %s" % (key, answer, g.learned[key]))


def answered(move):
    """The key watch's ignore takes for move: (attacker id, anim)."""
    return move["by"]["id"], move["anim"].lower()


def watch(g, cs, frames, ignore=None):
    """Let frames frames pass while reading the creatures in cs every frame
    (see swing); the attack one telegraphs as soon as one shows, else None.
    ignore: an answered() key, the attack already answered, passed over.
    cs None: just wait. WHY: docs/modding.md §5"""
    if cs is None:
        g.frames(frames)
        return None
    end = None
    for _ in range(frames + 1):
        now, move = swing(g, cs)
        end = now + frames if end is None else end
        if now >= end:
            return None
        if move is not None and answered(move) != ignore:
            return move
    return None


def defend(g, refs, cs, move):
    """Answer an attack one of the creatures in cs telegraphs: block a
    blockable one (see guard), evade an unblockable one, also one that
    follows a block. refs: see sense_refs. WHY: docs/modding.md §5"""
    if choose(g, move) == "block":
        move = guard(g, cs, 0, move)
    if move is not None:
        evade(g, refs, move, choose(g, move))


def raise_block(g):
    """Hold block (Space) and return the player's base channel (see
    parse_anims). Block is raised by a press, not by Space being down: held
    through a heal, an evade or a lull, the player stands ready unguarded
    while Space is down. So Space is pressed anew when the player stands
    ready. Also returns the player's state ids (9 is blocking).
    WHY: docs/modding.md §5"""
    g.send("down Space")
    mine = anims(g, "PLAYER")
    base = mine[0] if mine else []
    if any(n.lower().startswith(UNGUARDED_ANIMS) for n, _, _, _ in base):
        g.send("up Space")
        g.send("down Space")
    return base, g.send("states PLAYER").split()[2:]


def guard(g, cs, frames, move=None):
    """Hold block for frames frames watching cs, then on while they chain
    blockable attacks (move: one already showing), so the block is never
    dropped between them; a block raised after an attack starts can be too
    late. Block stays held after: the caller releases Space before it
    attacks, heals or evades (fight releases it on the way out). Returns the
    unblockable attack that ended the block, else None. WHY: docs/modding.md §5"""
    raise_block(g)
    move = move or watch(g, cs, frames)
    for _ in range(GUARD_CHAIN):
        if move is None or choose(g, move) != "block":
            return move
        answered_with(g, move, "block")
        mine, states = raise_block(g)
        print("  block: %s, player %s [%s] hp %d" % (
            describe(move), " ".join("%s@%.2f" % r[:2] for r in mine), " ".join(states),
            g.query("GetHealth(GetPlayer())")))
        nxt = watch(g, cs, FRAMES_GUARD, answered(move))
        # A heavy swing (style 98's Attack_C) lands after FRAMES_GUARD:
        # the block stays up while the same attack still plays.
        move = nxt or swing(g, cs)[1]
    return move


def evade(g, refs, move, answer):
    """Evade sideways from creature c: the stick pushed with block held (the
    "Both" Evade Method, see EVADE_METHOD; it starts in the frame, where the
    double tap took a dozen frames and slams landed mid-tap), at right
    angles to the line from c, where a back flip still took slams. Block
    stays held after. answer "back" evades straight away from c instead.
    move: the attack evaded, its "by" c. refs: see sense_refs.
    WHY: docs/modding.md §5"""
    c = move["by"]
    answered_with(g, move, answer)
    s = sense(g, refs, c["expr"])
    side = math.degrees(math.atan2(s.here[1] - s.there[1], s.here[0] - s.there[0]))
    side += 90.0 if answer == "side" else 0.0
    g.send("down Space")
    try:
        stick_toward(g, side, s)
        g.frames(FRAMES_FLICK)
        mine = anims(g, "PLAYER")
        print("  evade %s: heading %.0f bearing %.0f at %.1f m: %s" % (
            answer, side, s.bearing, math.dist(s.here, s.there),
            " ".join("%s@%.2f" % r[:2] for r in mine[0]) if mine else "-"))
    finally:
        stick(g, None)
    g.frames(FRAMES_EVADE - FRAMES_FLICK)


def close_in(g, refs, who):
    """Step the player with the left stick until who is in REACH, as a player
    closes on a foe; no jumps. Attacks then track the engine's lock-on target,
    so the player is not turned by script. WHY: docs/modding.md §4
    """
    s = sense(g, refs, who)
    try:
        for _ in range(CLOSE_STEPS):
            if s.loading or math.dist(s.here, s.there) <= REACH:
                break
            stride(g, refs, s, s.there)
            s = sense(g, refs, who)
    finally:
        stick(g, None)


def nearest_tagged(g, tag):
    """The object tagged tag nearest the player in the player's area, as
    (script expression, id in 8 hex digits as the control channel takes it). Tags repeat in an area
    (two chi shrines in j02_ruins), and the control channel's tag lookup takes
    the first. Exits when none is in the area. WHY: docs/modding.md §4
    """
    best = None
    for n in range(TAG_SCAN):
        o = "GetObjectByTag(%s, %d)" % (tag, n)
        valid, here, mm, oid = g.queries([
            "GetIsObjectValid(%s)" % o, "GetArea(%s) == GetArea(GetPlayer())" % o,
            "FloatToInt(GetDistanceBetween(GetPlayer(), %s) * 1000.0)" % o, id_expr(o)])
        if not valid:
            break
        if here and (best is None or mm < best[0]):
            best = (mm, o, "%08x" % (oid & 0xFFFFFFFF))
    if best is None:
        raise SystemExit("no object tagged %s in the player's area" % tag)
    return best[1:]


def use_point(g, tag):
    """World (x, y) the engine's reach test measures use of the object tag
    names (a tag, or an id from nearest_tagged) from: the usepoint control
    command's answer (a placeable's .pwk
    walk-to point rotated into the world, else the object's position).
    WHY: docs/modding.md §4
    """
    w = g.send("usepoint " + tag.strip('"')).split()
    if len(w) != 5:
        raise SystemExit("usepoint %s -> %s" % (tag, " ".join(w)))
    return float(w[1]), float(w[2])


def jump_to_use_point(g, tag):
    """Debug only: jump the player to the use point of the object tagged tag.
    Play-throughs walk (see use); a jump skips the triggers and collision on
    the way. ActionJumpToObject on a placeable lands short or nowhere.
    WHY: docs/modding.md §4
    """
    x, y = use_point(g, tag)
    g.run("AssignCommand(GetPlayer(), ActionJumpToLocation(Location(GetArea(GetPlayer()), Vector(%r, %r, GetPosition(GetPlayer()).z), 0.0)))" % (x, y))
    g.frames(FRAMES_ATTACK)


def goto(g, tag):
    """Debug only: jump the player to the object tagged tag, then step back
    and forth: the camera keeps its old place until the player walks."""
    jump_to_use_point(g, tag)
    for k in ("S", "W"):
        g.send("down " + k)
        g.frames(FRAMES_NUDGE)
        g.send("up " + k)


def face(g, obj):
    """Turn the player toward the object the script expression obj names with
    the mouse, as a player does. The engine rewrites the player's facing from
    the camera every frame, so SetFacing does not hold. WHY: docs/modding.md §4"""
    cx, cy = struct.unpack("<2i", g.peek(MOUSE + MOUSE_CENTER, 8))
    assert 0 <= cx - TURN_PX and cx + TURN_PX < GUI_SIZE[0] and 0 <= cy < GUI_SIZE[1], (cx, cy)
    exprs = ["FloatToInt(GetPosition(%s).%s * 1000.0)" % (o, a)
             for o in ("GetPlayer()", obj) for a in ("x", "y")]
    exprs.append("FloatToInt(GetFacing(GetPlayer()) * 1000.0)")
    for _ in range(TURN_STEPS):
        px, py, ox, oy, f = (v / 1000.0 for v in g.queries(exprs))
        d = (math.degrees(math.atan2(oy - py, ox - px)) - f + 180.0) % 360.0 - 180.0
        if abs(d) <= TURN_TOL:
            return
        g.send("move %d %d" % (cx + max(-TURN_PX, min(TURN_PX, round(-d / TURN_GAIN))), cy))
        g.frames(FRAMES_TURN)
    raise SystemExit("face: BUG still %.1f degrees off %s after %d moves" % (d, obj, TURN_STEPS))


def use(g, tag):
    """Use the nearest object tagged tag (a door, chest or shrine) as a player does:
    walk to its use point with the stick (handling what triggers start on the
    way), face it, click. A click posts a use event only for the highlighted
    object, and the engine never walks the player to it outside cutscenes.
    Returns "load" when an area load ended the walk. WHY: docs/modding.md §4
    """
    obj, oid = nearest_tagged(g, tag)
    # A creature's use point is its centre: stop at arm's length, not in its body.
    near = REACH if g.query("GetObjectType(%s) == %d" % (obj, OBJECT_TYPE_CREATURE)) else ARRIVE
    if travel(g, *use_point(g, oid), near) == "load":
        return "load"
    for _ in range(FACE_TRIES):
        face(g, obj)
        if highlighted(g) == int(oid, 16):
            break
    else:
        cycle_highlight(g, tag, int(oid, 16))
    attack(g)
    return None


def cycle_highlight(g, tag, oid):
    """Press Next Target (Tab) until the object id oid is highlighted, as a
    player does when facing picks a nearer object. The engine ranks the
    objects within 6 m by facing angle and distance, skips any out of line of
    sight, and keeps a Tab offset into that ranking (player + 0x1238), so
    facing alone can leave another object marked. WHY: docs/modding.md §4"""
    seen = []
    for _ in range(TARGET_CANDIDATES):
        menu_key(g, "Tab")
        g.frames(FRAMES_TURN)
        h = highlighted(g)
        if h == oid:
            return
        seen.append("%08x" % h)
    raise SystemExit("use %s: %08x not highlighted after facing and %d Tabs (saw %s)"
                     % (tag, oid, TARGET_CANDIDATES, " ".join(seen)))


def highlighted(g):
    """Id of the object a click would use now (the one the game marks), or
    NO_OBJECT. A click on anything else posts no use event, so use checks this
    before clicking. WHY: docs/modding.md §4"""
    return g.u32(g.u32(g.u32(g.u32(APP) + APP_GUI) + GUI_CURSEL) + CURSEL_OBJ)


def fight(g, rounds):
    """Fight until no live hostile is near and the engine is out of combat.
    Block (Space) is held while a round reads the state and released only to
    attack or heal (see fight_round): an unguarded frame lets a swing land,
    and a hit's stun lets the rest of the combo land too. Exits unless the
    game's Evade Method is "Both" (see evade). WHY: docs/modding.md §5"""
    with open(os.path.join(g.game, "JadeEmpire.ini"), newline="") as f:
        if EVADE_METHOD not in f.read().splitlines():
            raise SystemExit("fight needs %s in JadeEmpire.ini [InputOptions]" % EVADE_METHOD)
    try:
        fight_rounds(g, rounds)
    finally:
        save_learned(g)
        g.send("up Space")


def fight_rounds(g, rounds):
    """The rounds of fight."""
    calm, st, idle, idle_hp, refs, gone = 0, (False, 0), 0, -1, sense_refs(g), set()
    for i in range(rounds):
        s = dict(zip([k for k, _ in PLAYER_STATE], g.queries([e for _, e in PLAYER_STATE])))
        if s["dead"]:
            raise SystemExit("player died in round %d" % i)
        if s["talk"]:
            print("round %d: conversation or cutscene" % i)
            g.send("up Space")
            talk(g, TALK_STEPS)
            continue
        c = foe(g, gone)
        # A hostile that the engine has not put in combat (an ambush group not
        # yet triggered) neither fights back nor takes hits, so out of combat
        # it does not hold the fight open. WHY: docs/modding.md §4
        if c is not None and not s["combat"]:
            idle = idle + 1 if c["hp"] == idle_hp else 0
            idle_hp = c["hp"]
            c = None if idle >= CALM_ROUNDS else c
        if c is None:
            calm = 0 if s["combat"] else calm + 1
            if calm == CALM_ROUNDS:
                print("combat over after %d rounds" % i)
                return
            g.send("up Space")
            g.send("key Tab")
            g.frames(FRAMES_ATTACK)
            continue
        calm = 0
        g.send("down Space")
        chans = anims(g, "%08x" % c["id"])
        if chans is None:
            print("round %d: foe %s %x left the scene" % (i, c["label"], c["id"]))
            gone.add(c["id"])
            continue
        base = chans[0]
        cs = [c] + near_foes(g, c, gone)
        move = swing(g, cs)[1]
        mine, states = raise_block(g)
        print("round %d hp %d/%d chi %d anim %s [%s] foe %s style %d hp %d at %.1f m anim %s, %d near%s" % (
            i, s["hp"], s["top"], s["chi"], " ".join("%s@%.2f" % r[:2] for r in mine), " ".join(states),
            c["label"], c["style"], c["hp"], c["mm"] / 1000.0,
            " ".join("%s@%.2f" % r[:2] for r in base), len(cs) - 1, describe(move)))
        st = fight_round(g, refs, s, cs, move, base, st)
    raise SystemExit("still fighting after %d rounds" % rounds)


def describe(move):
    """' -> Label [UNBLOCKABLE] by ID' for a telegraphed attack, '' for None."""
    if move is None:
        return ""
    by = " by %x" % move["by"]["id"] if "by" in move else ""
    return " -> %s%s%s" % (move["label"], " UNBLOCKABLE" * move["unblockable"], by)


def opening(base):
    """How a foe whose base channel plays base can be attacked: "open" in a
    hit reaction or an attack's recovery, "guard" while it blocks, else
    "busy" (ready, walking, evading: it may start an attack at any frame).
    WHY: docs/modding.md §5"""
    for name, _, _, _ in base:
        n = name.lower()
        if n.startswith(OPENING_ANIMS) or n.endswith(RECOVERY_SUFFIX):
            return "open"
        if n.startswith(GUARD_ANIM):
            return "guard"
    return "busy"


def fight_round(g, refs, s, cs, move, base, st):
    """One round against creature c = cs[0], the rest of cs the other foes
    near (see near_foes), s the player's PLAYER_STATE, base c's base channel:
    defend against a telegraphed attack, heal or block when low, else attack
    when c is open (see opening) and guard while it is not. A player
    mid-swing cannot block or evade, so attacking a foe that may start an
    attack is left until PATIENCE guarded rounds pass. Every wait watches
    cs, so an attack one starts meanwhile is defended at once. st and the
    result: (blocked, waited); blocked True when light attacks did no damage,
    waited the rounds guarded since the last attack. WHY: docs/modding.md §4"""
    blocked, waited = st
    c = cs[0]
    if move is None and s["hp"] < HEAL_FRACTION * s["top"]:
        # Out of chi, a heal does nothing; a held block keeps most hits off.
        if s["chi"] >= CHI_MIN:
            g.send("up Space")
            move = hold(g, "Left_Shift", FRAMES_HEAL, cs)
            if move is None:
                return st
        else:
            move = guard(g, cs, FRAMES_BLOCK)
    state = opening(base)
    if move is None and state == "busy" and waited < PATIENCE:
        move = guard(g, cs, FRAMES_GUARD)
        if move is None:
            return blocked, waited + 1
    if move is None:
        waited = 0
        g.send("up Space")
        close_in(g, refs, c["expr"])
        # A blocking foe takes no damage from light attacks; a strong attack
        # (the style's Slam) breaks the block. So the round after light ones
        # failed is strong, but only one on one: the Slam commits the player
        # for about 1.5 s, and other foes hit meanwhile. WHY: docs/modding.md §5
        if (blocked or state == "guard") and len(cs) == 1:
            move = attack(g, "R", cs) or watch(g, cs, FRAMES_STRONG)
        else:
            for _ in range(LIGHT_COMBO):
                move = attack(g, "L", cs)
                if move is not None:
                    break
    if move is not None:
        print("  defend: %s" % describe(move))
        defend(g, refs, cs, move)
        return blocked, waited
    return not blocked and g.query("GetHealth(%s)" % c["expr"]) >= c["hp"], waited


def position(g):
    """World (x, y) of the player, read to the millimetre."""
    return tuple(g.query("FloatToInt(GetPosition(GetPlayer()).%s * 1000.0)" % a) / 1000.0
                 for a in ("x", "y"))


def grid(g):
    """The pathfinding grid of the player's area, read from guest memory."""
    obj = int(g.send("area").split()[1], 16)
    header = g.peek(obj + hexgrid.AREA_GRID, hexgrid.HEADER_SIZE)
    ptr, n = hexgrid.header_cells(header)
    cells = b"".join(g.peek(ptr + k, min(PEEK_CHUNK, n - k)) for k in range(0, n, PEEK_CHUNK))
    return hexgrid.parse(header, cells)


def plan(g, grid_, here, x, y):
    """Waypoints from here to (x, y) on grid_; exits when either end is blocked
    or no route joins them."""
    ends = []
    for name, p in (("start", here), ("goal", (x, y))):
        i = hexgrid.cell_at(grid_, *p)
        k = None if i is None else hexgrid.nearest_open(grid_, i, SNAP_RINGS)
        if k is None:
            raise SystemExit("walk: %s %.1f,%.1f is off the grid or walled in" % (name, *p))
        if k != i:
            print("walk: %s %.1f,%.1f is blocked, using %.1f,%.1f" % (name, *p, *hexgrid.center(grid_, k)))
        ends.append(k)
    a, b = ends
    snapped = b != hexgrid.cell_at(grid_, x, y)
    path = hexgrid.route(grid_, a, b)
    if path is None:
        cut = hexgrid.first_blocked(grid_, hexgrid.route(grid_, a, b, through=True))
        raise SystemExit("walk: no route from %r to %r; first blocked cell on the cheapest way at %.1f,%.1f"
                         " (byte %#x; a closed placeable patches the live grid, see docs/modding.md §6)"
                         % (here, (x, y), *hexgrid.center(grid_, cut), grid_.cells[cut]))
    pts = hexgrid.waypoints(grid_, path)
    if not snapped:
        pts[-1] = (x, y)
    # Both ends in one cell: the route is that cell alone. Walks index the
    # first leg from pts[1], so the start is kept as pts[0].
    if len(pts) == 1:
        pts.insert(0, here)
    assert len(pts) >= 2, pts
    print("walk: %d waypoints: %s" % (len(pts), " ".join("%.1f,%.1f" % p for p in pts)))
    return pts


def close_popups(g):
    """Dismiss open notice popups with the attack button, as the popup asks,
    and print which ones closed. Exits when one will not close."""
    for _ in range(POPUPS_MAX):
        up = [i for i in panels(g) if i in POPUPS]
        if not up:
            return
        print("popup: closing panel %#x" % up[0])
        attack(g)
        g.frames(FRAMES_POPUP)
    raise SystemExit("popup: BUG panels %s still open" % panels(g))


# One step's view of the world, read in one batch: why walking must stop
# ("conversation", "cutscene", "combat" or None), the player's (x, y), the
# camera-to-player heading (see stick_toward), the open panel ids, whether a
# load or movie is up, and the (x, y) of another object if one was asked for.
Sense = namedtuple("Sense", "why here bearing panels loading there")
SENSE_STATE = (("conversation", "GetIsInConversation(GetPlayer())"),
               ("cutscene", "GetInCutsceneMode()"),
               ("combat", "GetIsInCombat()"))


def sense_refs(g):
    """Guest addresses sense reads: the GUI panel table and the game camera.
    Both stay put within an area. WHY: docs/modding.md §6"""
    table = g.u32(g.u32(g.u32(APP) + APP_GUI) + GUI_PANELS)
    cam = g.u32(g.u32(g.u32(APP) + APP_SCENE) + SCENE_CAMERA)
    assert table and cam, (table, cam)
    return table, cam


def sense(g, refs, other=None):
    """Read a Sense in one frame (a frame per round trip lets a running
    player cover RUN_STEP metres unsteered each). other: an object
    expression whose position to read too."""
    table, cam = refs
    pos = ["FloatToInt(GetPosition(%s).%s * 1000.0)" % (o, a)
           for o in ("GetPlayer()", other) if o for a in ("x", "y")]
    peeks = ["peek %x %d" % (table, 4 * PANEL_COUNT), "peek %x 8" % (cam + CAMERA_POS)]
    v = g.queries([e for _, e in SENSE_STATE] + pos, extra=peeks, allow=PLAYER_GONE)
    n = len(SENSE_STATE)
    if None in v[:n + len(pos)]:
        # The player object is gone while an area swaps, before the loading
        # panel opens: treat it as the load it is.
        return Sense(None, None, None, [], True, None)
    there = (v[n + 2] / 1000.0, v[n + 3] / 1000.0) if other else None
    v = v[:n + 2] + v[len(SENSE_STATE) + len(pos):]
    why = next((name for (name, _), on in zip(SENSE_STATE, v[:n]) if on), None)
    here = (v[n] / 1000.0, v[n + 1] / 1000.0)
    ptrs = struct.unpack("<%dI" % PANEL_COUNT, bytes.fromhex(v[n + 2].split()[1]))
    cx, cy = struct.unpack("<2f", bytes.fromhex(v[n + 3].split()[1]))
    movie = ptrs[PANEL_MOVIE]
    loading_ = movie != 0 and g.rect(movie)[2:] == GUI_SIZE
    bearing = math.degrees(math.atan2(here[1] - cy, here[0] - cx))
    return Sense(why, here, bearing, [i for i, p in enumerate(ptrs) if p], loading_, there)


def stick(g, deg):
    """Hold the left stick toward deg (0 = right, 90 = up), or release it on None."""
    if deg is None:
        g.batch(["axis leftx 0", "axis lefty 0"])
        return
    g.batch(["axis leftx %d" % round(STICK * math.cos(math.radians(deg))),
             "axis lefty %d" % round(-STICK * math.sin(math.radians(deg)))])


def stick_toward(g, heading, s):
    """Hold the left stick so the player moves along world heading (degrees,
    0 = +x, 90 = +y). The stick moves the player relative to the camera:
    stick up along the camera-to-player heading s.bearing, stick right 90
    degrees clockwise of it. WHY: docs/modding.md §6"""
    stick(g, heading - s.bearing + 90.0)


def stride(g, refs, s, goal):
    """One walking step from s.here toward goal: the stick is held for
    FRAMES_STEP frames, fewer when goal is nearer than that covers, so the
    player stops near it. Returns the next Sense. The stick stays held."""
    d = math.dist(s.here, goal)
    stick_toward(g, math.degrees(math.atan2(goal[1] - s.here[1], goal[0] - s.here[0])), s)
    g.frames(max(1, min(FRAMES_STEP, int(d / RUN_STEP))))
    return sense(g, refs)


def walk(g, x, y, near=ARRIVE):
    """Walk the player to (x, y) with the left stick along a route on the
    area's pathfinding grid, as a player would; no jumps. The walk ends
    near metres (at least ARRIVE) from (x, y). Returns what
    stopped the walk early (a conversation, cutscene, combat or area load a
    trigger began), or None on arrival; exits when stuck, which is a bug to
    look at. WHY: docs/modding.md §6
    """
    grid_, refs = grid(g), sense_refs(g)
    s = sense(g, refs)
    pts, k, still, replans = plan(g, grid_, s.here, x, y), 1, 0, 0
    best = math.inf  # nearest the player has been to waypoint k
    try:
        for step in range(WALK_STEPS):
            # A transition trigger loads another area: the player object is
            # gone until the load ends, so the walk is over.
            if s.loading:
                print("walk: stopped by a load or movie")
                return "load"
            if PANEL_DEATH in s.panels:
                raise SystemExit("walk: player died at %.2f,%.2f" % s.here)
            if PANEL_PAUSED in s.panels:
                print("walk: game paused, resuming with Return")
                stick(g, None)
                g.send("key Return")
                g.frames(FRAMES_POPUP)
                s = sense(g, refs)
                continue
            if any(i in POPUPS for i in s.panels):
                stick(g, None)
                close_popups(g)
            if s.why:
                print("walk: stopped by %s at %.2f,%.2f" % (s.why, *s.here))
                return s.why
            for _ in range(len(pts)):
                if k == len(pts) - 1 or math.dist(s.here, pts[k]) > ARRIVE:
                    break
                k, best = k + 1, math.inf
            if k == len(pts) - 1 and math.dist(s.here, pts[k]) <= max(ARRIVE, near):
                print("walk: arrived at %.2f,%.2f after %d steps" % (*s.here, step))
                return None
            s = stride(g, refs, s, pts[k])
            if s.loading:
                continue  # s.here is None; the check at the loop top ends the walk
            # Progress is getting closer to the waypoint: a walk sliding along
            # a wall or circling it moves every step yet gets nowhere.
            d = math.dist(s.here, pts[k])
            still, best = (0, d) if d < best - STUCK_DIST else (still + 1, best)
            if still == STUCK_STEPS:
                if replans == REPLANS:
                    raise SystemExit("walk: BUG stuck at %.2f,%.2f heading for %.2f,%.2f"
                                     % (*s.here, *pts[k]))
                grid_ = learn_obstacle(grid_, s.here, pts[k])
                pts, k, still, replans, best = plan(g, grid_, s.here, x, y), 1, 0, replans + 1, math.inf
        raise SystemExit("walk: not there after %d steps, at %.2f,%.2f" % (WALK_STEPS, *s.here))
    finally:
        stick(g, None)


def learn_obstacle(grid_, here, goal):
    """grid_ with what stopped a stuck walk from here toward goal blocked:
    the whole 0xfe band when the leg crosses a soft one (the band was a real
    wall), else a disc OBSTACLE_AHEAD along the leg (something the grid lacks,
    a body or a prop). WHY: docs/modding.md §6"""
    band = hexgrid.soft_on_leg(grid_, here, goal)
    if band is not None:
        grid_, n = hexgrid.harden_band(grid_, band, BAND_CELLS_MAX)
        print("walk: no progress at %.2f,%.2f; band at %.1f,%.1f is a wall, blocking %d cells and replanning"
              % (*here, *hexgrid.center(grid_, band), n))
        return grid_
    d = max(math.dist(here, goal), 1e-3)
    f = min(OBSTACLE_AHEAD, d) / d
    ob = (here[0] + f * (goal[0] - here[0]), here[1] + f * (goal[1] - here[1]))
    print("walk: no progress at %.2f,%.2f; blocking %.1f,%.1f and replanning" % (*here, *ob))
    return hexgrid.block_disc(grid_, *ob, OBSTACLE_RADIUS)


def travel(g, x, y, near=ARRIVE):
    """Walk to within near metres of (x, y) (see walk) and deal with whatever a trigger starts on the way:
    fight a combat, play a conversation or cutscene through, wait out a load
    (which ends the trip: the area changed), close popups. Returns "load" when
    an area load ended it, or None on arrival."""
    for _ in range(TRAVEL_LEGS):
        why = walk(g, x, y, near)
        if why is None:
            return None
        if why == "load":
            settle(g, SETTLE_STEPS)
            return why
        if why == "combat":
            fight(g, FIGHT_ROUNDS)
            recover(g)
        else:
            talk(g, TALK_STEPS)
        close_popups(g)
    raise SystemExit("travel: still not at %.1f,%.1f after %d interruptions" % (x, y, TRAVEL_LEGS))


def cross(g, tag):
    """Take the area transition trigger tagged tag: travel to a point inside
    the trigger's outline. The trigger's position need not lie inside its
    outline (j02t_100_120's is 3 m outside), and the AREATRANS label shows on
    approach, well before the outline is entered, so neither the position nor
    where the label appears is enough. Exits unless an area load ended the trip.
    WHY: docs/modding.md §4"""
    x, y = inner_point(trigger_outline(g, tag))
    if travel(g, x, y) != "load":
        raise SystemExit("cross: at %s (%.2f,%.2f) with no area load" % (tag, x, y))


def trigger_outline(g, tag):
    """The outline of the trigger tagged tag as (x, y) pairs, from the polygon
    control command (the engine's own copy). WHY: docs/modding.md §4"""
    w = g.send("polygon " + tag).split()
    if w[:1] != ["ok"]:
        raise SystemExit("polygon %s -> %s" % (tag, " ".join(w)))
    n = int(w[1])
    v = [float(t) for t in w[2:]]
    assert len(v) == n * 3, "polygon %s: %d values for %d points" % (tag, len(v), n)
    return [(v[i * 3], v[i * 3 + 1]) for i in range(n)]


def inner_point(poly):
    """A point inside polygon poly: the vertex mean when it is inside (always,
    for a convex outline), else the first inside midpoint of a vertex pair."""
    n = len(poly)
    mean = (sum(p[0] for p in poly) / n, sum(p[1] for p in poly) / n)
    tries = [mean] + [((poly[i][0] + poly[j][0]) / 2, (poly[i][1] + poly[j][1]) / 2)
                      for i in range(n) for j in range(i + 2, n)]
    for p in tries:
        if inside(p, poly):
            return p
    raise SystemExit("cross: no inside point found for outline %s" % (poly,))


def inside(p, poly):
    """Whether point p lies inside polygon poly (even-odd ray test)."""
    x, y = p
    hit = False
    for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1]):
        if (y1 > y) != (y2 > y) and x < x1 + (y - y1) * (x2 - x1) / (y2 - y1):
            hit = not hit
    return hit


def recover(g):
    """After a fight, chi heal back to full health while chi lasts: neither
    health nor chi regenerates out of combat, so the next fight would start
    where this one ended. Warns when chi runs out first. WHY: docs/modding.md §6"""
    for _ in range(RECOVER_HEALS):
        hp, top, chi = g.queries([e for k, e in PLAYER_STATE if k in ("hp", "top", "chi")])
        if hp >= top:
            return
        if chi < CHI_MIN:
            print("recover: LOW hp %d/%d with chi %d; find a chi shrine" % (hp, top, chi))
            return
        wake_keys(g)
        hold(g, "Left_Shift", FRAMES_HEAL, None)
    print("recover: hp still below maximum after %d heals" % RECOVER_HEALS)


def settle(g, steps):
    """Wait out a movie or area load: until the loading panel closes and the
    player object exists again (it is gone for part of an area swap)."""
    for i in range(steps):
        if not loading(g) and g.queries(["GetIsObjectValid(GetPlayer())"], allow=PLAYER_GONE)[0]:
            print("settle: clear after %d waits, panels %s" % (i, " ".join("%#x" % p for p in panels(g))))
            return
        g.frames(FRAMES_SETTLE_WAIT)
    raise SystemExit("settle: loading panel still open after %d waits" % steps)


def minigame(g, steps):
    """Play a flying minigame: hold fire and sweep the ship from side to side
    until the minigame panel closes (won, or lost and back to a menu)."""
    if PANEL_MINIGAME not in panels(g):
        raise SystemExit("minigame: panel %#x not open" % PANEL_MINIGAME)
    g.send("btn L down")
    try:
        for i in range(steps):
            stick(g, 0.0 if i % (2 * SWEEP_STEPS) < SWEEP_STEPS else 180.0)
            g.frames(FRAMES_STEP)
            if PANEL_MINIGAME not in panels(g):
                print("minigame: over after %d steps, panels %s" % (i, panels(g)))
                return
        raise SystemExit("minigame: still running after %d steps" % steps)
    finally:
        g.send("btn L up")
        stick(g, None)


def replies(g):
    """The reply list on screen: [(text, x, y)] with click points, top first.

    Read from the reply panel's items, so a choice is made by its text
    rather than its position. WHY: docs/modding.md §5
    """
    table = g.u32(g.u32(g.u32(APP) + APP_GUI) + GUI_PANELS)
    panel = g.u32(table + 4 * PANEL_REPLY)
    if not panel:
        return []
    n = g.u32(panel + REPLY_COUNT)
    assert n <= REPLIES_MAX, "reply count %d" % n
    px, py, _, _ = g.rect(panel)
    lx, ly, _, lh = g.rect(panel + LISTBOX)
    items = g.u32(panel + REPLY_ITEMS)
    out = []
    for i in range(n):
        item = g.u32(items + 4 * i)
        ix, iy, _, ih = g.rect(item)
        if iy >= lh:
            print("reply %d below the visible list, skipped" % i)
            continue
        ptr, size = struct.unpack("<II", g.peek(item + ITEM_TEXT, 8))
        assert size <= TEXT_MAX, "reply %d text size %d" % (i, size)
        # An empty CExoString has no buffer: size 0 (seen while a line is set up).
        text = g.peek(ptr, size).split(b"\0")[0].decode("utf-8", "replace") if size else ""
        # A tall last item may run past the list's bottom; click its visible part.
        out.append((text, px + lx + ix + REPLY_INSET, py + ly + iy + min(ih, lh - iy) // 2))
    return out


def talk(g, steps, prefer=()):
    """Advance conversations and wait out cutscenes until both are over.

    GetIsInConversation(player) is 1 in a dialog; a cinematic without one
    only sets GetInCutsceneMode. A reply not chosen before in this run is
    taken first, after any containing a prefer or g.prefer text; when all have been, the
    last (a hub's exit). With no
    replies on screen a click skips the spoken line. WHY: docs/modding.md §4
    """
    chosen, prefer = set(), tuple(prefer) + g.prefer
    for i in range(steps):
        if g.query("GetIsInConversation(GetPlayer())"):
            rs = replies(g)
            fresh = [r for r in rs if r[0] not in chosen]
            wanted = [r for r in fresh if any(t in r[0] for t in prefer)]
            pick = (wanted or fresh or rs[-1:] or [None])[0]
            if pick:
                print("reply %d/%d: %s" % (rs.index(pick) + 1, len(rs), pick[0]))
                chosen.add(pick[0])
                g.send("click %d %d" % pick[1:])
            else:
                g.send("click %d %d" % TALK_CLICK)
        elif not g.query("GetInCutsceneMode()"):
            print("conversation over after %d steps" % i)
            return
        g.frames(FRAMES_TALK)
    raise SystemExit("conversation still open after %d steps" % steps)


def panels(g):
    """Ids of the GUI panels open now, from the GUI manager's table."""
    table = g.u32(g.u32(g.u32(APP) + APP_GUI) + GUI_PANELS)
    ptrs = struct.unpack("<%dI" % PANEL_COUNT, g.peek(table, 4 * PANEL_COUNT))
    return [i for i, p in enumerate(ptrs) if p]


def panel_name(g, pid):
    """Class name of open panel pid, e.g. "CGuiPanel.AREAMINIMAP", from the
    name pointer at panel + 0x1C; None if pid is not open (each read is a
    frame, so a panel listed a moment ago may have closed). WHY: docs/modding.md §5"""
    table = g.u32(g.u32(g.u32(APP) + APP_GUI) + GUI_PANELS)
    panel = g.u32(table + 4 * pid)
    if not panel:
        return None
    raw = g.peek(g.u32(panel + PANEL_NAME), PANEL_NAME_MAX)
    end = raw.find(b"\0")
    assert end > 0, "panel %#x: name not terminated in %d bytes" % (pid, PANEL_NAME_MAX)
    return raw[:end].decode("latin-1")


def loading(g):
    """Whether a load screen or movie is up: panel 0x41 at full GUI size. The
    save message reuses that panel as a small box over the running game.
    WHY: docs/rendering.md §3"""
    table = g.u32(g.u32(g.u32(APP) + APP_GUI) + GUI_PANELS)
    panel = g.u32(table + 4 * PANEL_MOVIE)
    return panel != 0 and g.rect(panel)[2:] == GUI_SIZE


def busy(g):
    """Why a save now would capture a transient state, or None when idle."""
    if g.query("GetIsDead(GetPlayer())"):
        return "player dead"
    if g.query("GetIsInCombat()"):
        return "in combat"
    if g.query("GetIsInConversation(GetPlayer())"):
        return "in conversation"
    if g.query("GetInCutsceneMode()"):
        return "in cutscene"
    table = g.u32(g.u32(g.u32(APP) + APP_GUI) + GUI_PANELS)
    if g.u32(table + 4 * PANEL_MOVIE):
        return "movie or loading screen open"
    return None


def menu_key(g, name):
    """Tap a keyboard shortcut (F5, J, Escape...) after moving the mouse.
    Once gamepad input is used (the stick, pad buttons), the engine ignores
    keyboard shortcuts until the mouse moves; movement keys still work.
    WHY: docs/modding.md §3"""
    wake_keys(g)
    g.send("key " + name)


def wake_keys(g):
    """Move the mouse so the engine takes keyboard shortcuts again (see
    menu_key). WHY: docs/modding.md §3"""
    for x, y in WAKE_POINTS:
        g.send("move %d %d" % (x, y))


def save(g):
    """Quick save after clearing what test commands queued.

    A command such as AssignCommand(npc, ActionMoveToObject(...)) leaves an
    action in that object's queue, and a save stores queues: one left on the
    then-inactive dragon in the Spirit Cave stalled its conversation after the
    next load. WHY: docs/modding.md §4
    """
    why = busy(g)
    if why:
        raise SystemExit("not saving: " + why)
    tags = g.touched()
    for t in tags:
        if not g.query('GetIsObjectValid(GetObjectByTag("%s", 0))' % t):
            print("ledger tag %s: no such object here, skipped" % t)
            continue
        g.run('AssignCommand(GetObjectByTag("%s", 0), ClearAllActions())' % t)
    g.run("AssignCommand(GetPlayer(), ClearAllActions())")
    g.frames(FRAMES_SETTLE)
    path = os.path.join(g.game, SAVE_FILE)
    before = os.stat(path).st_mtime_ns if os.path.exists(path) else 0
    menu_key(g, "F5")
    g.frames(FRAMES_SAVE)
    if not os.path.exists(path) or os.stat(path).st_mtime_ns == before:
        raise SystemExit("quick save not written: %s" % path)
    if tags:
        os.remove(os.path.join(g.ctl, LEDGER))
    print("saved; cleared %d ledger objects and the player" % len(tags))


def slot_paths(game):
    return [os.path.join(game, "override", SLOT_NAME % i + ".ncs") for i in range(SLOTS)]


def init(game):
    """Write a placeholder into every missing slot; the game sees them after a restart."""
    code = ncs.assemble(SLOT_INIT)
    made = 0
    for p in slot_paths(game):
        if not os.path.exists(p):
            with open(p, "wb") as f:
                f.write(code)
            made += 1
    print("created %d of %d slots; restart the game if it is running" % (made, SLOTS))


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    if sys.argv[3] == "init" and len(sys.argv) == 4:
        init(sys.argv[2])
        return
    g = Game(sys.argv[1], sys.argv[2])
    cmd, a = sys.argv[3], sys.argv[4:]
    while "--reply" in a[:-1]:
        k = a.index("--reply")
        g.prefer += (a[k + 1],)
        del a[k:k + 2]
    n = int(a[0]) if cmd in ("talk", "fight") and a else 0
    tag = '"%s"' % a[0] if a else ""  # an NWScript string literal; tags hold no quotes
    if cmd == "query" and len(a) == 1:
        _, rt = ncs.expr(ast.parse(a[0], mode="eval").body)
        print(g.query_str(a[0]) if rt == "String" else g.query(a[0]))
    elif cmd == "do" and len(a) == 1:
        g.touch(a[0])
        g.run(a[0])
    elif cmd == "goto" and len(a) == 1:
        goto(g, tag)
    elif cmd == "use" and len(a) == 1:
        use(g, tag)
    elif cmd == "face" and len(a) == 1:
        face(g, nearest_tagged(g, tag)[0])
    elif cmd == "ask" and len(a) == 1:
        # The player's own ActionStartConversation does nothing: the engine runs
        # actions that move the player only inside cutscenes and conversations
        # (as with walk-to-use); the NPC's starts it. WHY: docs/modding.md §4
        src = "AssignCommand(GetObjectByTag(%s, 0), ActionStartConversation(GetPlayer()))" % tag
        g.touch(src)
        g.run(src)
    elif cmd == "talk":
        talk(g, n or TALK_STEPS, a[1:])
    elif cmd == "fight" and len(a) <= 1:
        fight(g, n or 60)
    elif cmd == "walk" and len(a) == 2:
        walk(g, float(a[0]), float(a[1]))
    elif cmd == "walkto" and len(a) == 1:
        walk(g, *use_point(g, nearest_tagged(g, tag)[1]))
    elif cmd == "travel" and len(a) == 2:
        travel(g, float(a[0]), float(a[1]))
    elif cmd == "cross" and len(a) == 1:
        cross(g, a[0])
    elif cmd == "settle" and not a:
        settle(g, SETTLE_STEPS)
    elif cmd == "minigame" and len(a) <= 1:
        minigame(g, int(a[0]) if a else MINIGAME_STEPS)
    elif cmd == "popups" and not a:
        close_popups(g)
    elif cmd == "panels" and not a:
        for i in panels(g):
            print("%#x %s" % (i, panel_name(g, i) or "(closed since listed)"))
    elif cmd == "anims" and len(a) <= 1:
        chans = anims(g, a[0] if a else "PLAYER")
        if chans is None:
            raise SystemExit("anims: %s has no creature model" % (a[0] if a else "PLAYER"))
        for name, chan in zip(("base", "head", "weapon"), chans):
            print(name, " ".join("%s@%.2f x%.2f %x" % r for r in chan))
    elif cmd == "recover" and not a:
        recover(g)
    elif cmd == "pos" and not a:
        print("%.3f %.3f" % position(g))
    elif cmd == "save" and not a:
        save(g)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
