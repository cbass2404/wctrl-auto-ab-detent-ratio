# Ratio baseline

Why each shipped ratio is the number it is.

`config.json` carries values with no room to explain them. This file is the explanation, so
that a value can be **re-derived** rather than guessed at, and so a DCS flight model change
becomes a re-measure instead of an archaeology project.

If you change a shipped value, change its row here too.

---

## What the notch means

The detent marks **the last power you can hold indefinitely**. Below it you can sit forever;
past it you are spending a budget.

On an afterburning jet that line is the afterburner gate. On a warbird it is the gate before
WEP, water injection, MW-50 or boost cut-out. It is the same idea on the same hardware
feature, and on several of these aircraft it reproduces a gate the real pilot could feel:
the P-51's WEP wire, the F4U's water injection detent, the P-47's water injection stop, the
Mosquito's boost gate.

### The two anchors

- **Anchor A, max continuous.** Everything above the notch is time-limited in any way.
- **Anchor B, the emergency gate.** The notch sits where the real aircraft's gate sits.

**The rule is Anchor B wherever the real aircraft has a gate, Anchor A where it does not.**

The two diverge sharply on a P-51D. Max continuous is well down the lever, while takeoff and
military power is what you actually climb out on, with WEP above that behind the wire.
Anchor A would put a hard notch somewhere you cross on every single takeoff, turning a useful
signal into an obstacle. Anchor B puts it where the pilot felt one.

### Why some aircraft with an afterburner are 100

**How the extra power is actuated decides the ratio, not whether the airframe has an
afterburner.** If the emergency range is entered by a button, switch or gate release rather
than by pushing the lever further along its track, there is no point on the track for a
detent to mark, and 100 is the accurate answer.

| Entry | What happens |
| --- | --- |
| `F-100` | Throttle travels to full military power, then a button pops it left into afterburner. Military power is the top of the track. |
| `MiG-19` | Same arrangement. |
| `FW-190D` | Full power on the lever, then a button for the extra. Contrast `FW-190A`, which has a real gate and therefore a real notch. |

These are not omissions. Do not "correct" them to a value below 100 without flying them.

---

## Coverage

The table covers **every official DCS module**, plus the A-4, Growler and Super Hornet
community mods.

That is **54 entries, not 54 aircraft.** A name is matched as a case-insensitive fragment of
the DCS aircraft name and carries no variant, so a single `F-14` row serves the F-14A, the
F-14B and the F-14B (Upgrade). Variants only earn their own row when they need a genuinely
different number, and the longest match wins, so adding `F-14A` later overrides `F-14` for
that one aircraft.

### Untested rows

Four values are derived by the method below but have **not been confirmed in the cockpit**,
because the aircraft are not available to fly for testing:

| Entry | Ratio |
| --- | --- |
| `F-15E` | 75 |
| `AV8B` | 91 |
| `MiG-19` | 100 |
| `M-2000` | 89 |

Treat them as sound but unconfirmed. A reported measurement from someone flying one beats the
derivation, so these are the first rows to revisit.

---

## Conditions

Every value assumes:

- **The physical detent calibrated at the very end of its track.** This is step 1 of setup.
  A detent parked somewhere else still works, but every number possibly shifts. This is not tested.
- **No curve and full saturation on the throttle axis**, that is, a DCS axis left linear
  end to end. Any curve, saturation or deadzone set on the throttle axis moves the
  relationship between lever position and engine output, and therefore moves where the
  notch should be. This is per-aircraft in DCS, so one tuned aircraft invalidates only its
  own row.

Every value is a **starting point**. Users are told to expect to nudge a few percent.

## Method for re-measuring

On the ground, engine running:

1. Sea level, standard day, no wind, stationary. Ram air and altitude both move the
   relationship between lever position and manifold pressure, so both have to be pinned.
2. Prop lever and mixture at the setting the limit is quoted against, usually max RPM and
   auto-rich. Record which.
3. Open the DCS axis control indicator (`RCtrl+Enter`) so the throttle axis position is
   visible as a number.
4. Advance the throttle until the relevant gauge reads the limit being anchored to.
5. Record the axis percentage. That is the ratio.

Use **the module's own documentation** for the limit, not general type knowledge, the manual
under `Mods\aircraft\<module>\Doc\`, or the in-sim kneeboard power charts. DCS flight models
do not always match the real aircraft's published figures, and it is the DCS figure that
matters, because DCS is what the user is flying.

---

## Provenance

- Module list generated from a live install: **DCS 2.9.29.27278**, from the directory names
  under `CoreMods\aircraft\` and `Mods\aircraft\`.
- DCS unit names were read out of each module's `entry.lua` and module lua rather than
  assumed from marketing names. This matters, see [Name matching](#name-matching).
- Third-party mod names were read from `Saved Games\DCS\Mods\aircraft`.

### Confidence

| Tier | Meaning |
| --- | --- |
| **carried** | Carried forward unchanged from the original 12-row table. Long-standing, in use since before this baseline. |
| **verified** | Checked directly in DCS. |
| **estimated** | Derived from reference images for a module that could not be checked directly. Roughly the group sitting at 75. Re-measure when someone owns the module. |
| **convention** | Not measured and does not need to be. 100 is the established "no notch" value. |
| **provisional** | Holding value for a module that is not released yet. |

**The one field this pass did not capture is the per-aircraft gauge reading**, the actual
manifold pressure, RPM or torque figure the notch was set against. The `Limit` column below
names *which* limit each row is anchored to, but not the number on the dial. Anyone
re-measuring a row should add it.

---

## Afterburner gate

Past the notch is burner.

| Entry | DCS unit name(s) | Ratio | Limit | Confidence |
| --- | --- | --- | --- | --- |
| `F-14` | `F-14B`, `F-14A-135-GR`, `F-14A-95-GR`, `F-14A-135-GR-Early`, `F-14BU` | 54 | AB gate | carried |
| `MiG-29` | `MiG-29A Fulcrum`, `MiG-29 Fulcrum` | 60 | AB gate | carried |
| `F-4` | `F-4E-45MC` | 70 | AB gate | carried |
| `F-15E` | `F-15ESE` | 75 | AB gate | estimated |
| `F-16` | `F-16C_50` | 75 | AB gate | carried |
| `J-11` | `J-11A` | 75 | AB gate | estimated |
| `JF-17` | `JF-17` | 75 | AB gate | estimated |
| `Su-27` | `Su-27` | 75 | AB gate | estimated |
| `Su-33` | `Su-33` | 75 | AB gate | estimated |
| `Su-34` | `Su-34` | 75 | AB gate | estimated |
| `F-15C` | `F-15C` | 80 | AB gate | carried |
| `AJS37` | `AJS37` | 81 | AB gate | carried |
| `EA-18` | `EA-18G` | 82 | AB gate | verified |
| `F-5` | `F-5E-3` | 82 | AB gate | carried |
| `FA-18` | `FA-18C_hornet` | 82 | AB gate | carried |
| `Mirage-F1` | `Mirage-F1CE`, `Mirage-F1EE`, `Mirage-F1M-CE`, ~30 more | 87 | AB gate | verified |
| `M-2000` | `M-2000C` | 89 | AB gate | verified |
| `MiG-21` | `MiG-21Bis` | 91 | AB gate | carried |

All Anchor B: an afterburner gate is a real gate.

## Emergency power gate

Past the notch is on the clock.

| Entry | DCS unit name(s) | Ratio | Limit | Anchor | Confidence |
| --- | --- | --- | --- | --- | --- |
| `A-6` | `A-6E` | 75 | military vs max continuous | A | provisional |
| `I-16` | `I-16` | 80 | takeoff / boosted power | A | verified |
| `P-47` | `P-47D-30`, `P-47D-30bl1`, `P-47D-40` | 80 | water injection, forward stop | B | verified |
| `Bf-109` | `Bf-109K-4` | 81 | MW-50 | A | estimated |
| `C-101` | `C-101EB`, `C-101CC` | 85 | max continuous | A | verified |
| `C-130` | `C-130J-30` | 85 | max continuous | A | verified |
| `Mosquito` | `MosquitoFBMkVI` | 85 | boost above the gate | B | verified |
| `Spitfire` | `SpitfireLFMkIX`, `SpitfireLFMkIXCW` | 85 | boost cut-out | A | estimated |
| `La-7` | `La-7` | 90 | emergency boost | A | verified |
| `P-51` | `P-51D`, `P-51D-30-NA` | 90 | WEP, behind the wire | B | verified |
| `TF-51` | `TF-51D` | 90 | WEP, behind the wire | B | verified |
| `AV8B` | `AV8BNA` | 91 | water injection | A | verified |
| `FW-190A` | `FW-190A8` | 92 | boost / C3 injection gate | B | estimated |
| `F4U` | `F4U-1D`, `F4U-1D_CW` | 95 | water injection detent | B | verified |
| `F-86` | `F-86F Sabre` | 97 | military vs max continuous | A | verified |

`C-130` and `F4U` both shipped at 75 in the original table. Both moved here as a result of
being measured against the anchor rule rather than because 75 was presumed wrong.

`F-86` and `MiG-15` are two early jets with the same military-versus-max-continuous question
answered differently: the Sabre keeps a notch at 97, the MiG-15 goes to 100. If a later pass
finds the Sabre's split is not worth a notch either, move it to the no-notch group.

## No notch

Nothing above max continuous worth gating, or the extra power is not on the track at all.
The detent sits at the top and stays out of the way.

| Entry | DCS unit name(s) | Why | Confidence |
| --- | --- | --- | --- |
| `A-4` | `A-4E-C` | no AB, no meaningful split | convention |
| `A-10` | `A-10A`, `A-10C`, `A-10C_2` | no AB, no meaningful split | convention |
| `AH-64` | `AH-64D`, `AH-64D_BLK_II` | rotary wing | convention |
| `CH-47` | `CH-47Fbl1`, `CH-47F` | rotary wing | convention |
| `Christen Eagle` | `Christen Eagle II` | no time-limited range | convention |
| `F-100` | `F-100D` | AB is button-actuated | verified |
| `FW-190D` | `FW-190D9` | MW-50 is button-actuated | estimated |
| `Hawk` | `Hawk` | trainer | convention |
| `Ka-50` | `Ka-50`, `Ka-50_3` | rotary wing | convention |
| `L-39` | `L-39C`, `L-39ZA` | trainer | convention |
| `MB-339` | `MB-339A`, `MB-339APAN` | trainer | convention |
| `Mi-8` | `Mi-8MT` | rotary wing | convention |
| `Mi-24` | `Mi-24P` | rotary wing | convention |
| `MiG-15` | `MiG-15bis` | no meaningful split | verified |
| `MiG-19` | `MiG-19P` | AB is button-actuated | verified |
| `OH58` | `OH58D` | rotary wing | convention |
| `SA342` | `SA342M`, `SA342L`, `SA342Minigun`, `SA342Mistral` | rotary wing | convention |
| `Su-25` | `Su-25`, `Su-25T` | no AB, no meaningful split | convention |
| `UH-1` | `UH-1H` | rotary wing | convention |
| `UH-60` | `UH-60L`, `UH-60L_DAP` | rotary wing | convention |
| `Yak-52` | `Yak-52` | no time-limited range | convention |

**Every helicopter is 100 by decision, not by measurement.** Most have a takeoff or
contingency rating above max continuous that would be a legitimate anchor, but the axis in
question is the collective, not a throttle, so a notch in the throttle track is in the wrong
place to help. Revisit only if someone flies one with a notch in the collective and reports
that it helps rather than annoys.

## The fallback

| Entry | Ratio | Why |
| --- | --- | --- |
| `NONE` | 75 | Never matches by name. Used when nothing else hits. |

75 rather than 100 because 100 means no usable gate at all, which is the one thing this tool
exists to provide. It deliberately agrees with `noMatchRatio`, which is also 75, two
settings that both mean "I do not know what this aircraft is" should not answer differently.

`Merge-UserConfig` keeps a user's existing value for any name they already have, and everyone
already has `NONE`. An upgrade therefore leaves an existing install on whatever it had.
That is intended: silently rewriting a value someone may have tuned is worse than leaving it.

---

## Name matching

`Resolve-Ratio` matches a case-insensitive substring of the DCS aircraft name, and on several
matches the **longest entry name wins**. Three findings from building this table, all of them
from comparing intended names against the unit names actually read out of the install:

**1. Some unit names drop a hyphen the marketing name has.**

- `OH58D`, an entry named `OH-58` matches nothing. The entry is `OH58`.
- `AV8BNA`, an entry named `AV-8B` matches nothing. The entry is `AV8B`.

**2. `P-51` does not cover the TF-51.** The unit is `TF-51D`, which does not contain the
string `P-51`. Without its own entry the trainer falls through to `NONE`.

**3. `FA-18` does not cover the Growler.** `EA-18G` does not contain `FA-18`, which is why
`EA-18` is a separate entry. The Super Hornet needs no entry, `FA-18E`, `FA-18F`, `FA-18ET`
and `FA-18FT` all contain `FA-18` and inherit the Hornet's value.

### Longest-match hazards

A shipped name longer than a name already in a user's table silently outranks theirs on the
airframes it covers. Watch this on every name added.

- **`F-15` became `F-15C`** so the two Eagles are siblings rather than one containing the
  other. Consequence: the merge never deletes, so an existing install keeps its `F-15` row
  **and** gains `F-15C` and `F-15E`, both longer and therefore both winning on their own
  airframes. A fresh install gets the clean two-row version.
- **Do not add `FA-18E` or `FA-18F`** without deciding this deliberately. Both are longer
  than `FA-18` and would override a tuned Hornet value.

### Naming strategy

Names stay at the **family** level and match on the shortest string that identifies the family
unambiguously. This keeps the table near 55 rows rather than 90, and avoids most of the
longest-match problem. Split into variants only where the airframes genuinely want different
values, `FW-190A` against `FW-190D` is a real case, since an A-8 and a D-9 are not the same
engine and are not actuated the same way.

---

## Third-party mods

Four free mods are included because they are common on multiplayer servers. They are not
official modules and are not covered by the DCS version above.

| Entry | Mod | Unit name(s) |
| --- | --- | --- |
| `A-4` | A-4E-C | `A-4E-C` |
| `EA-18` | CJS Super Hornet | `EA-18G` |
| `UH-60` | UH-60L | `UH-60L`, `UH-60L_DAP` |
|, | CJS Super Hornet | `FA-18E`, `FA-18F`, `FA-18ET`, `FA-18FT`, inherits `FA-18` |

`C-130` is **not** in this group. `C130J` ships in `CoreMods\aircraft` and `Mods\aircraft` as
an official module with unit name `C-130J-30`.

## Known gaps

- **Per-aircraft gauge readings were not recorded.** The most valuable thing the next pass
  can add.
- **Eight rows are `estimated`**, all from reference images rather than flying: `F-15E`,
  `J-11`, `JF-17`, `Su-27`, `Su-33`, `Su-34`, `Bf-109`, `Spitfire`, `FW-190A`, `FW-190D`.
  Several sit at exactly 75, which is also the `NONE` value, that is a placeholder, not a
  measurement.
- **`A-6` is provisional.** Heatblur's A-6E is not released. Re-measure when it ships.
- **Helicopters are unexamined by decision.** See the no-notch section.
- **The nine `carried` values predate this baseline** and have never been re-measured against
  the anchor rule. They are in daily use and known good, but they are not evidence.
