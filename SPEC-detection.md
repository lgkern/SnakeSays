# SnakeSays — automatic detection: functional specification

This describes what the automatic detection has to **do**. It does not describe
how, and it must not be read as a description of any existing implementation.

Everything factual in here came from combat logs recorded by the addon's author
on 2 August 2026 — one normal clear and two hard sessions — and from measurements
the author took in game. Nothing came from another addon.

## Why this document exists

SnakeSays had automatic detection before. It was removed because it had not been
written independently. Nothing from it survives in this repository, and nothing
from it may be reconstructed.

That is why the ground rules below are stricter than they would normally be, and
why this document gives you observations and requirements rather than a design.
The design is the part that has to be yours.

## Ground rules for whoever implements this

1. **Do not read, download, or consult any other addon for this boss.** If you
   find one on disk, stop and say so rather than opening it.
2. **Do not restore anything from this repository's git history.** The previous
   implementation was removed on purpose.
3. Design the solution from the observations below. Where this document states a
   requirement, satisfy it however you think best — the decomposition, the names
   and the algorithms are yours to choose.
4. Where a number is needed that is not given here, ask. Do not invent a
   measurement and do not recall one from anywhere.

## The fight

Azta'rec is a Delve Nemesis in Venomfall Deeps (instance 3079). The room is
split into four quarters. The boss runs a memory game three times per pull, at
roughly 90%, 60% and 30% health.

Each round has two halves:

**The showing half.** Waves cross the room one at a time. Each wave leaves
exactly one quarter safe. The player watches, and where they stand is the answer
they will need later.

**The calling half.** The boss repeats the same run with no visual warning. The
player has to be back in the right quarter for each wave, in the same order.

SnakeSays records the showing half and calls it back during the calling half.

### Wave counts

| Difficulty | Encounter ID | Rounds |
|---|---|---|
| Normal | 3508 | 3, then 4, then 5 waves |
| Hard | 3525 | 5, then 6, then 7 waves |

### What the client actually tells you

This is the important part, and it is narrower than it looks.

**The showing half is invisible to addons.** The waves produce no cast, no
damage when avoided, and no unit event of any kind. There is nothing to observe
per wave. Do not go looking for one.

**But the round announces its own length.** While the showing half runs, the
boss carries an aura called `Sermon of Ula'tek`. It appears when the round starts
and is removed when it ends, and:

> **aura duration = slot length × number of waves**

Each wave owns one slot. The wave lands slightly before its slot closes.

Observed, per round:

| Difficulty | Aura durations | Waves | Duration ÷ waves |
|---|---|---|---|
| Normal | 10.509s, 14.003s, 17.523s | 3, 4, 5 | 3.503, 3.501, 3.505 |
| Hard | 15.025s, 15.018s, 15.016s, 15.010s | 5 each | 3.005, 3.004, 3.003, 3.002 |

So the slot is **≈3.503s on normal** and **≈3.003s on hard**.

This was checked against a reconstructed hard round. Cutting that round's aura
duration into five equal slots and reading the player's quarter at the end of
each gave a run with no consecutive repeats, which is what the fight guarantees —
a wrong slot length would drift and start producing adjacent duplicates.

The hard figures are all from the first round; later hard rounds are hard to
reach. The linear rule is confirmed across three different wave counts on normal,
so extrapolating it to 6 and 7 waves is reasonable — but see R3.4, which makes
the addon self-correcting rather than dependent on the extrapolation.

**The aura ID is not a wave count.** Normal used a different ID per round; hard
used one ID for every round. Use the duration, not the ID.

**The calling half is fully observable.** The boss casts `Echo of Ula'tek`
(spell ID **1288125**), once per wave. The wave lands when the cast **completes**,
which gives the player about three seconds of warning per call.

The cast duration is **not constant on hard**. Normal held 3.005s across all
twelve casts. Hard sits at one of two values, about 3.31s and about 3.64s, and
switches between them part way through a round — in one logged round it ran slow
then fast, in another fast then slow. The cause is unknown and the order is not
predictable.

**Read the live cast time; never assume one.** The player's warning window
changes mid-round, and anything that hardcodes a duration will be wrong by the
last call.

**The handover is exact.** The `Sermon` aura is removed in the same millisecond
that the first `Echo of Ula'tek` cast begins.

**A wipe truncates the aura.** On a reset, the aura is removed within ~10ms of
`ENCOUNTER_END`, giving a duration that is not a whole multiple of the slot.

**A second boss exists on hard.** It casts nothing this feature cares about.

**The combat log is unreadable by addons in combat in Midnight.** Everything
above must be obtained from unit events, aura APIs and encounter events. The logs
this document is built from were read offline, from disk, after the fact.

### The room

Safe zones are centred on **north, east, south and west**. The boundaries between
them lie on the diagonals — north-east, south-east, south-west, north-west.

**Consecutive waves never use the same quarter.** Two adjacent calls resolving to
the same quarter means the reading is wrong, not that the boss repeated itself.

**Players stand close to the centre.** A quarter is an angular sector, so a melee
player satisfies it a few yards from the boss rather than out by the wall. In a
logged hard round every position sample sat between 5 and 11 yards from centre,
and one was 0.61 yards out — close enough that no bearing exists at all.

Detection therefore has to be reliable at small radius, where a yard of movement
swings the bearing a long way. Do not assume the player is anywhere near the
wall.

### Measurements

`UnitPosition("player")` returns world yards as `(a, b, z, instanceID)` where `a`
runs north and `b` runs west.

| Point | a | b |
|---|---|---|
| Centre (standing) | 181.70 | 0.60 |
| North wall | 238.30 | 0.70 |
| South wall | 127.40 | 0.70 |
| West wall | 182.00 | 39.10 |
| East wall | 181.90 | −38.10 |

The room is about 111 yd north-south and 77 yd east-west. It is modelled as a
circle on the narrower axis: **radius 38.5 yd**. Players can stand well north or
south of that circle and still be in the room; the view has to cope.

The midpoint of the four walls is `a = 182.85, b = 0.50`, about 1.15 yd north of
the standing centre. At this radius the difference is under two degrees at a
quarter boundary, so either is usable. The author's call.

## Requirements

### R1 — Recognising the encounter

1.1 Arm on `ENCOUNTER_START` for encounter 3508 or 3525.
1.2 Also arm if the encounter name contains `Azta`, in case the IDs are
    renumbered.
1.3 Disarm on `ENCOUNTER_END` and forget everything about the pull.
1.4 Remember which of the two encounters is running; the slot length depends on
    it.

### R2 — The showing half

2.1 Detect that a round has started by the `Sermon of Ula'tek` aura appearing on
    the boss.
2.2 Detect that it has ended by the aura being removed.
2.3 Know how long the round ran, to at least a tenth of a second.
2.4 A round that is cut short — by a wipe, a kill, or anything else — must be
    discarded, not recorded. A round whose length is not close to a whole number
    of slots is cut short.
2.5 Each round stands alone. Starting a round clears whatever the previous one
    recorded.

### R3 — How many waves

3.1 Derive the wave count from the round's length and the slot length for the
    current difficulty.
3.2 Seed values: 3.503s (normal), 3.003s (hard).
3.3 Reject a count that isn't a whole number of slots within a small tolerance —
    that is R2.4's cut-short case.
3.4 **Self-correct.** The calling half reveals the true wave count, because the
    boss casts once per wave. If that count disagrees with the count derived in
    3.1, the stored slot length for this difficulty is wrong: correct it from the
    round length and the observed cast count, and keep the correction. This is
    what makes the seed values a starting point rather than a dependency.

### R4 — Recording the run

4.1 For each wave of the round, record which quarter the player occupied.
4.2 The recording must reflect where the player **settled**, not where they
    happened to be while crossing to somewhere else. A single instantaneous
    reading is not good enough.
4.2.1 The wave lands near the **end** of its slot, so the end of the slot is the
    part that counts. In a logged round the player spent the first half of slot 1
    in one quarter and the second half in the quarter they were actually going
    to; an even weighting across the whole slot would have been a coin toss.
4.3 If any wave cannot be resolved, discard the whole round and say so in chat.
    A run with a hole in it is worse than no run, because every later call would
    be shifted onto the wrong wave.
4.4 The board should fill as the round runs, not all at once at the end, so the
    player can see it working.
4.5 Two consecutive waves resolving to the same quarter is a signal that
    something is wrong (see "The room"). At minimum, do not let it pass silently.

### R5 — Calling the run back

5.1 Advance one call per `Echo of Ula'tek` cast from the boss unit that is
    running the encounter.
5.2 Announce the call when the cast **starts**, so the player has the cast's
    duration to move.
5.3 Ignore casts from any other unit, including the second boss on hard.
5.4 Stop at the end of the recorded run. Extra casts change nothing.
5.5 Ignore a duplicate cast event for a wave already called — the same cast can
    arrive on more than one unit token.
5.6 Each announcement must say which quarter is safe now, and which is safe
    next where there is one.

### R6 — Where the player is

Callers need to ask three things, and each must have a truthful "don't know"
answer:

6.1 Which quarter of the room the player is in.
6.2 How far they are from the centre.
6.3 Which way they are facing.

6.4 Every one of these must survive the client withholding the value or handing
    back a secret value. A secret value passes around freely and throws the
    moment it is used in a calculation, so guarding the call alone is not enough.
6.5 A guarded failure returns "unknown". It must never let an error escape into
    a combat event handler.
6.6 There is no shipped room centre. Until the player runs `/ss measure`, the
    quarter cannot be determined and the honest answer is "unknown".
6.7 A player standing very close to the centre has no meaningful bearing.

### R7 — The room view

An optional window showing the room from above with the player in it, turning so
that the way they face is up.

7.1 Show the four quarters and which marker is assigned to each.
7.2 Show the player's position, and their facing when it is known.
7.3 During the calling half, convey three things: the quarter to be in now, the
    quarter to be in next, and the quarters that are about to be hit.
7.4 The next-up hint must not appear while the player is still travelling to the
    current one. Two lit quarters at that moment is one thing too many to read.
7.5 There is no next-up on the last wave, nor when the next call is for the
    quarter the player is already in.
7.6 The current quarter should be distinguishable at a glance from "reached" to
    "not yet reached", without reading anything.
7.7 A player outside the modelled circle must still be shown usefully.

**The visual encoding is the author's decision.** This document deliberately does
not specify colours.

### R8 — Modes

8.1 **Automatic** — records with no input from the player.
8.2 **Semi-automatic** — the player presses a key at each wave; the addon decides
    which quarter from where they stand.
8.3 **Manual** — the player presses the quarter themselves.
8.4 The calling half runs in all three modes. The boss repeats the waves whether
    the addon recorded them or the player did.
8.5 In automatic mode, board presses are ignored by default so a stray press
    cannot corrupt a recording the addon is managing.

### R9 — Giving up honestly

9.1 If the client stops handing out player position while the player is in the
    delve, say so in chat once, switch to manual, and re-enable manual input.
9.2 Never record a guess. Every "don't know" in R6 must reach the player as an
    absence, not as a wrong answer.

## Integration surface

These already exist in files that were not touched and are not being rewritten.
Renaming is allowed if the callers are updated, but the behaviour is fixed.

**Subscribers** — `Announce.lua` and the room view register at load and are
driven by the replay:

- a per-step callback receiving the step number, the current quarter, and the
  next quarter if there is one
- an end callback fired once when a replay stops, however it stopped

**Read by `Announce.lua`, `Commands.lua` and the room view:**

- whether a replay is running, and which step it is on
- the player's quarter, distance from centre, and facing (R6)
- whether the addon is armed, and whether it is recording

**Existing and clean, do not reimplement:** the board and its markers, the
sequence store, the voice and on-screen call, the options page, the keybinds, the
practice run, the window sizes.

The bell in `Announce.lua` currently cannot ring because it needs R6.1. It needs
no changes once that works.

`ns.QUARANTINE` and `ns.LocationAllows()` in `Core.lua` exist only while
detection is missing. Remove both once R1 and R6 are in.

Also missing and needed: a check for whether the player is in this delve at all.
Instance 3079 and the zone name `Venomfall Deeps` are the available signals.

## Tests

The suite uses busted against a headless client mock in `spec/helpers/`. The mock
models secret values as arithmetic landmines, which is what R6.4 exists for.

**Do not restore the deleted spec files.** They asserted the removed design.
Write new ones from these requirements.

Test the behaviour, not the arithmetic. Drive the events and let the addon get
itself there — a spec that calls the replay directly proves the function works,
not that the fight ever reaches it. That mistake hid a real bug once: the replay
started fine when called by hand and never started on its own in two of the three
modes.

Cover at least:

- a full round recorded and called back, each wave in order, in every mode
- three rounds in one pull with counts growing, each independent of the last
- a round cut short by a wipe, discarded
- a wave that cannot be resolved, taking the whole round with it
- the stored slot length correcting itself when the cast count disagrees (R3.4)
- position and facing going unreadable, and going secret
- the fallback to manual, once and only once
- the room view's now / next / danger states, including 7.4 and 7.5

## Decisions left to the author

| Decision | Note |
|---|---|
| Draw margin for the room view | How much floor to show past the wall. Not a property of the room — pick a number you like |
| Which centre to use | Standing 181.70/0.60, or wall-midpoint 182.85/0.50 |
| Visual encoding in the room view | R7.3 says what to convey, not how |
| What to do when R4.5 fires | Warn, discard, or attempt a correction |
