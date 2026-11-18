# Cues

How to use the “Cues” panel, a cue list for triggering.

![The Cues panel, with Now and Next shown large](shots/en/cues.jpg)

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

## Advancing automatically

Cues can advance without anyone pressing “Go”. A cue with something scheduled gets a tag, and “Now” and “Next” show the time left.

### Auto-advance

- Choose it with the `↳` button on the right of a row (or “Auto-advance” in the right-click menu).
- “Next after … s”: goes to the next cue that many seconds after firing (1–60 seconds; “Enter Seconds…” for any value).
- “Next When the Clip Ends”: goes to the next cue when the clip reaches its out point. Looping and ping-pong clips advance the first time. Only video clips can use it (generators, still images and cameras have no end).
- The top right of “Now” shows the time left, such as “Next in 0:03”.

### Firing at a time

- Use “Fire at a Time…” in the right-click menu to set hours, minutes and seconds. “1 Minute from Now” is there too.
- At that time the cue fires, regardless of its position in the list.
- The row gets a “19:00” tag, plus “in 12:30” within an hour. The top right of “Next” shows the time until the next timed cue.
- Times that have already passed when the app or project opens do not fire. They also do not fire if more than 5 seconds pass between checks (for example, waking from sleep).
- There is no date (it fires every day at that time). If you keep the project open, it fires again the next day.

### Next cue when a clock reaches 0

Set “At zero” of the clock generator (countdown or timer) to “Next cue”, and the cue list advances by one the moment it reaches 0 while on the output. → [Text and clock](generators-text.md)

### People come first

- When you fire a cue with “Go”, “Back” or a double-click, whatever the previous cue had scheduled is cleared. Only the newly fired cue's schedule stays.
- If a timed cue and a clock at 0 happen at the same moment, the list advances only once.
- Cues keep advancing during a blackout.

### Pausing

Turn off “Auto” (the bolt) to the right of “Add Cue”, and auto-advance, timed cues and clocks at 0 all stop firing. Their tags turn gray with a strikethrough. It is not saved and is always on at launch.

### Rehearsal clock

The clock button to the right of “Auto” sets a pretend time.

- “Make It 23:59:30 Now”: the show clock (timed cues and countdown clocks) runs from that time.
- “10 s Before Next Timed Cue” lets you try one right away.
- While the clock is shifted, the Cues panel and the output monitor show a yellow band, “Rehearsal: clock +3:12:05”.
- “Back to Real Time” returns to normal. It is not saved; reopening the app uses the real time.

### Following on a backup machine

A second Mac with the same project can follow the main machine's cues.

- Main machine: in “Connect” at the top, turn on “Send beat and audio values” and set the target to the backup's IP address and port. Each fired cue sends its number (`/halo/cue/current`), and blackout sends on/off (`/halo/blackout`).
- Backup: in “Connect”, turn on OSC “Receive” and “Follow as backup”. It fires the cue with the received number and matches blackout.
- The backup does not auto-advance, fire timed cues or advance on clocks at 0 (it only follows the main machine's numbers). A blue band appears in the Cues panel.
- Only the cue number and blackout are matched, not individual frames.

→ [OSC](osc.md)

## Adding and reordering

- Drag a scene (the image) or a clip's name strip in the grid onto the cue list (dropping a name strip onto a grid slot moves the clip instead).
- “Add Cue”.
- Right-click a scene or clip.
- Drag to reorder.

Cues are saved in the project.
