# Cues

How to use the “Cues” panel, a cue list for triggering.

## Cue types

Line up what to show in order, and trigger them one after another with “Go”.

| Type | What it does |
|---|---|
| Scene | Shows that whole state |
| Clip | Shows only that clip; the other layers fade out and stop. Choose “Keep other layers” in the right-click menu to replace only that layer |
| Stop All | Stops everything |

Marks in front of the names in the list:

- Green square: only that clip.
- Stacked mark with an L number: replaces only that layer.

## Triggering

- “Go” (`Space`) triggers the next cue.
- `⇧Space` or “Back” triggers the previous one again.
- Double-click to jump to that cue.
- “Now” and “Next” are shown large.
- Repeated presses of “Go” are ignored for 0.5 seconds.
- If there are no cues, the Space key does nothing.

## Per-cue settings

- Fade: Default (the scene or layer fade time), Cut to 8 seconds.
- Note (cue line, etc.).
- For a clip cue, the cue can override “At End” (Loop, Ping-pong, Stop at End, Blackout). This applies only when triggered from that cue. Triggering it again from the grid returns to the clip's setting.
- The buttons on the right of a row let you choose the fade time and “At End” on the spot (→| = Stop at End, →|B = Blackout; teal = overridden by the cue).
- Even when the clip's layer is empty, the clip fades in over the fade time.

## Adding and reordering

- Drag a scene (the image) or a clip's name strip in the grid onto the cue list (dropping a name strip onto a grid slot moves the clip instead).
- “Add Cue”.
- Right-click a scene or clip.
- Drag to reorder.

Cues are saved in the project.
