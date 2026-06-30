# SnakeSays

A Simon-Says HUD for World of Warcraft. Built for the memory game from Azta'rec, 
the Delve Nemesis from Midnight Season 2, who divides the room into four quadrants and
does five casts (one safe quadrant each) before replaying the same five.

SnakeSays lets you **record the sequence as it happens**, by clicking the HUD
or pressing keybinds, and then read it back off the screen during the silent
repeat.

It records and displays only. It never moves your character, targets, or places
world markers, so there is nothing protected here: **every button and keybind
works in combat.**

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

Press a wedge (mouse or keybind) and its marker is appended to the sequence row
beneath the circle. A **reset** button sits at the left of that row (and has its
own keybind) to clear the sequence and start a fresh recording.

So pressing Diamond → Square → Cross shows that run of three icons under the
board; reset wipes it.

## Settings

`/ss` (or `Esc → Options → AddOns → SnakeSays`) opens SnakeSays' options page,
all in one place inside Blizzard's settings panel:

- **Per-quadrant marker** — each quadrant shows a row of the eight WoW markers;
  click one to assign it. Markers are unique across quadrants: choosing one
  that's already in use simply **swaps** the two quadrants, so you never end up
  with a duplicate.
- **Keybind per quadrant + reset** — click a key box and press the combo you
  want (Esc cancels, right-click clears). These are the real game bindings, so
  they also show up under `Esc → Options → Keybindings → SnakeSays`.
- **Show HUD** / **Lock HUD** — unlock to drag the board by its title bar.
- **Auto-reset** — when on (default), the sequence clears itself a set number of
  seconds after the *first* press, so a stale recording never carries into the
  next pull. The delay is the **Auto-reset after** slider (30–60s, default **40s**).
  The timer is anchored to the first press and doesn't slide forward as you add to
  the sequence.
- **Only show inside the Delve Nemesis map** — on by default; the board only
  appears while you're in Venomfall Deeps. Uncheck it to show
  the HUD everywhere (e.g. to reposition it out in the world).

## Keybinds

The addon adds five keybinds, one key per quadrant plus one for reset. You can set them
right in the options window or under `Esc → Options → Keybindings → SnakeSays`. The 
keybinds do exactly what the mouse does, so you can record the sequence without looking 
away from the fight.

## Slash commands

| Command | Effect |
|---------|--------|
| `/ss` | open the options window |
| `/ss show` · `/ss hide` | show / hide the HUD |
| `/ss toggle` | toggle the HUD |
| `/ss lock` · `/ss unlock` | lock / unlock for dragging |
| `/ss reset` | clear the recorded sequence |
| `/ss recenter` | move the HUD back to the centre of the screen |
| `/ss options` | open the options window |

(`/snakesays` is a long alias for `/ss`.)

## Files

```
Core.lua        marker catalogue, SavedVariables, assignment (with swap dedupe)
Sequence.lua    the recorded list of presses + a change listener
HUD.lua         the circular board, sequence row, reset button, drag/lock
Options.lua     AddOns settings page (canvas): marker picker, keybinds, show/lock
Commands.lua    keybind globals, binding labels, /ss hub
Bindings.xml    the five keybinding definitions
Media/          wedge-{n,e,s,w}.tga — the four pre-oriented wedge shapes
```

