# SnakeSays

A Simon-Says HUD for World of Warcraft. Built for the memory game from Azta'rec,
the Delve Nemesis from Midnight Season 2, who divides the room into four quadrants,
sends a run of waves through them (one safe quadrant each), then repeats the same
run in silence.

SnakeSays **records the sequence as it happens** and reads it back to you during
the silent repeat: by voice, by a bell when you reach safety, and on screen.

The mechanic runs more than once per pull, and the run gets longer each time. On 
**??** difficulty it's 5 waves at 90%, 6 at 60% and 7 at 30%. Each phase is
recorded and replayed on its own; the previous one is cleared when the next
channel starts.

It records and displays only. It never moves your character, targets, or places
world markers, so there is nothing protected here: **every button and keybind
works in combat.**

## Modes

The first time you walk into the delve, SnakeSays asks how it should work. The
answer is remembered; change it any time with `/ss mode` or in the options.

| Mode | Who decides *when* | Who decides *which quadrant* |
|------|--------------------|------------------------------|
| **Automatic** | SnakeSays | SnakeSays |
| **Semi-automatic** | You (one keybind per wave) | SnakeSays, from where you stand |
| **Manual** | You | You |

**Automatic** watches the boss channel and records where you stood for each
wave, with no input from you. **Semi-automatic** leaves the timing to you: press
the *Quadrant detection* keybind at each wave and SnakeSays reads your position.
**Manual** is the original behaviour where you press the quadrant yourself.

In automatic mode, board clicks and quadrant keybinds are ignored by default so
a stray press can't corrupt a recording SnakeSays is managing. There's a setting
to allow them anyway.

### If position stops working

The automatic modes depend on the game telling addons where your character is.
If that ever stops (most likely because Blizzard restricted it) SnakeSays says
so in chat, re-enables manual input and drops you back to **Manual**. It won't
quietly record garbage.

## The HUD

A circle split by an X into four cardinal wedges:

```
        North
     \    ▲    /
   West ◀  ●  ▶ East
     /    ▼    \
        South
```

Each wedge shows a raid marker and is tinted to that marker's colour. The
defaults are:

| Quadrant | Marker | Colour |
|----------|--------|--------|
| North    | Circle   | Orange |
| East     | Diamond  | Purple |
| South    | Square   | Blue   |
| West     | Cross    | Red    |

The recorded sequence renders as a row of marker icons beneath the circle, and a
**reset** button sits at the left of that row. Wedges flash as each wave is
recorded, whoever recorded it.

## During the repeat

When the boss starts repeating the run, SnakeSays calls each wave four ways:

- **Voice**: one word per wave, the safe colour (*"Red"*) or the marker's name
  (*"Cross"*), your choice. Deliberately short: waves are about three seconds
  apart.
- **Bell**: rings the moment you actually reach the safe quadrant, so you can
  confirm the move without looking away.
- **On-screen call**: the current quadrant large, with the next one beneath it
  so you can start moving early. Drag it anywhere; unlock the HUD to grab it.
- **Radar**: the safe slice in green, the next in yellow, everything else red.
  See below.

### Position radar

An optional second window showing the room top-down with you inside it. It turns
with you, so "up" is always the way you're facing and a call of "go left" reads as
left.

Each quadrant's marker sits on the rim, with the dividing lines between them.
Those lines are the real quadrant boundaries, so a marker means "anywhere in this
quarter", not "on this line".

During the repeat, every slice is painted for what it is right now:

| Colour | Meaning |
|--------|---------|
| 🟩 **Green** | stand here |
| 🟨 **Yellow** | where you're going next |
| 🟥 **Red** | the wave lands here |

The green slice **pulses slowly until you get there**, then holds steady, so you
can tell at a glance whether you've made it without reading anything.

Yellow only appears **after you've arrived**. While you're still travelling
everything except the call is red, because none of it is safe yet. A second lit
slice at that moment is just something else to misread under pressure. It's also
absent on the last wave, and when the next call is for the slice you're already in
(yellow over the green would read as "move" when the answer is "stay").

Switch the pulse off with **Blink the safe slice until you reach it** if you'd
rather green just sat there.

By default the radar hangs off the left edge of the board and moves with it, so
there's only one thing to place. Drag the radar itself (with the HUD unlocked)
and it pins to the screen on its own instead; `/ss recenter` reattaches it.

## Practice run

`/ss sim` makes up a run anywhere in the world, shows it going onto the board,
then calls it back with the real voice, bell, radar and popup. It prints the run
it's about to play, so you can check the calls against it. `/ss sim stop` ends it.

It runs a 5-wave phase by default; `/ss sim 6` or `/ss sim 7` practises the
longer ones. **You don't have to move for this one**. It exists to check the
announcements and to place the windows.

`/ss sim record` is the other half: it records from where you actually stand, the
way a real pull does. You become the centre of the room, so **walk around** during
the wave phase. If you stand still and there's no quadrant to read, so nothing gets
recorded. It follows your mode, so in Semi-automatic you press the capture key
and in Manual you press the board.

The board and the radar are normally hidden outside the delve, so a practice run
brings them up for its duration and puts them away afterwards. It only lifts the
*location* restriction: if you've hidden the board or switched the radar off,
they stay that way.

## When something doesn't behave

`/ss status` prints what the addon currently believes: mode, whether it thinks
it's in the delve, whether position and facing are readable and which quadrant it
sees, where the room centre is, which windows are up, the encounter state, and
how many TTS voices are installed.

## Settings

`/ss` (or `Esc → Options → AddOns → SnakeSays`) opens the options page:

- **Recording mode** - Automatic, Semi-automatic or Manual.
- **Per-quadrant marker** - click one of the eight markers to assign it. Markers
  are unique across quadrants: choosing one that's already in use **swaps** the
  two, so you never end up with a duplicate.
- **Keybinds** - one per quadrant, plus *Quadrant detection* (semi-automatic
  capture) and *Reset*. Click a key box and press the combo (Esc cancels,
  right-click clears). These are real game bindings, so they also show up under
  `Esc → Options → Keybindings → SnakeSays`.
- **Show HUD** / **Lock HUD** - unlock to drag the board, the call and the radar.
- **Ignore board clicks and quadrant keybinds** - on by default in Automatic.
- **Auto-reset** - clears the sequence a set number of seconds after the *first*
  press (30–60s, default 40s). The timer is anchored to the first press and
  doesn't slide forward as you add to the sequence.
- **Only show inside the Delve Nemesis map** - on by default. Untick it to place
  the windows out in the world.
- **During the replay** - speak the safe quadrant on/off, call things by colour
  or by marker, voice volume, let calls overlap, bell on/off, on-screen call
  on/off, next-up line on/off, radar on/off, blink the safe slice on/off.
- **Window size** - one slider each for the board, the radar and the on-screen
  call, 50% to 200%. They're separate on purpose: the board is a click target,
  the radar is read out of the corner of your eye, and the call is read head-on,
  so one size for all three is usually wrong for two of them. Resizing also
  scales the window's offset from whatever it's anchored to, so it can shift a
  little as it grows - nudge it back, or `/ss recenter`.

## Slash commands

| Command | Effect |
|---------|--------|
| `/ss` | open the options window |
| `/ss mode` | show the mode; `/ss mode auto\|semi\|manual` sets it |
| `/ss sim` | demo run anywhere; `/ss sim 7` for a 7-wave phase, `/ss sim stop` ends it |
| `/ss sim record` | practice run recorded from where you stand |
| `/ss status` | report what the addon currently sees |
| `/ss radar` | toggle the position radar |
| `/ss measure` | re-pin the room centre to where you stand |
| `/ss show` · `/ss hide` · `/ss toggle` | show / hide the HUD |
| `/ss lock` · `/ss unlock` | lock / unlock for dragging |
| `/ss reset` | clear the recorded sequence |
| `/ss recenter` | move the HUD, radar and on-screen call back to their default places |

(`/snakesays` is a long alias for `/ss`.)

### About `/ss measure`

Quadrant detection is measured from the centre of the boss room, and those
coordinates ship with the addon. If they're ever wrong, stand in the middle of
the room and run `/ss measure`. This will record a new center. `/ss measure
reset` restores the shipped values.

## Detection Module

The detection module was inspired by [Rothirr's Azta'rec Helper](https://www.curseforge.com/wow/addons/aztarec-helper).

