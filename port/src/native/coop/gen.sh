#!/bin/sh
# Assembles the online partner's scripts (native/coop_hero.odin) with
# tools/ncs (tools/build.sh builds it into port/build). The style ids native
# code fills in at run time are sentinels, 0x7e570000 + slot; the look and drop
# scripts take one each. Run from the repository root.
set -e
D=port/src/native/coop
P='GetPosition(OBJECT_SELF)'
port/build/ncs asm $D/spawn.ncs "ApplyEffectToObject(CreateObject(2, \"jec_p2\", Location(GetArea(OBJECT_SELF), Vector($P.x - 1.5, $P.y, $P.z), GetFacing(OBJECT_SELF))), 0, EffectResurrection(), 0.0)"
S=''
i=0
while [ $i -lt 34 ]; do
	S="${S}AddCombatStyle(OBJECT_SELF, $((0x7e570000 + i)), 1, 0, 0); "
	i=$((i + 1))
done
port/build/ncs asm $D/setup.ncs "${S}SetCurrentStyle(OBJECT_SELF, $((0x7e570000))); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyHealth(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyChi(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyFocus(100000), 0.0)"
F='ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyHealth(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyChi(100000), 0.0); ApplyEffectToObject(OBJECT_SELF, 0, EffectModifyFocus(100000), 0.0)'
port/build/ncs asm $D/revive.ncs "ApplyEffectToObject(OBJECT_SELF, 0, EffectResurrection(), 0.0); $F"
port/build/ncs asm $D/look.ncs "SetAppearance(OBJECT_SELF, $((0x7e580000)), -1)"
port/build/ncs asm $D/drop.ncs "RemoveCombatStyle(OBJECT_SELF, $((0x7e590000)))"
