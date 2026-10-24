#!/bin/sh
# Assembles the online partner's scripts (native/coop_hero.odin) with
# tools/ncs.py. The style ids native code fills in at run time are sentinels,
# 0x7e570000 + slot; the look and drop scripts take one each. Run from the repository root.
set -e
D=port/src/native/coop
P='GetPosition(OBJECT_SELF)'
python3 tools/ncs.py asm $D/spawn.ncs "ApplyEffectToObject(CreateObject(2, \"jec_p2\", Location(GetArea(OBJECT_SELF), Vector($P.x - 1.5, $P.y, $P.z), GetFacing(OBJECT_SELF))), 0, EffectResurrection(), 0.0)"
S=''
i=0
while [ $i -lt 34 ]; do
	S="${S}AddCombatStyle(OBJECT_SELF, $((0x7e570000 + i)), 1, 0, 0); "
	i=$((i + 1))
done
python3 tools/ncs.py asm $D/setup.ncs "${S}SetCurrentStyle(OBJECT_SELF, $((0x7e570000))); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyHealth(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyChi(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyFocus(100000), 0.0)"
F='ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyHealth(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyChi(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyFocus(100000), 0.0)'
python3 tools/ncs.py asm $D/revive.ncs "ApplyEffectToObject(OBJECT_SELF, 0, EffectResurrection(), 0.0); $F"
python3 tools/ncs.py asm $D/look.ncs "SetAppearance(OBJECT_SELF, $((0x7e580000)), -1)"
python3 tools/ncs.py asm $D/drop.ncs "RemoveCombatStyle(OBJECT_SELF, $((0x7e590000)))"
