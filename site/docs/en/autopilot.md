# Autopilot

How to use “Auto” at the top to keep cycling scenes and clips by rules you set. Use it when you step away, for example.

## On and off

Press “Auto” at the top to turn it on or off.

- If there are no rules, “Auto Setup” creates them: with 2 or more scenes, it switches scenes every 3 minutes; otherwise it switches the layers that have clips every 32 bars.
- While it is on, the time until the next switch is shown.
- It can be assigned to OSC `/halo/auto`, and to MIDI or a key from the right-click menu.

## Settings

Open the settings with ▾ on the right.

- A large button for on/off and the time until the next switch.
- For each rule, “Now → Next”: thumbnails of what is showing now and what will show next (decided in advance), with a bar for the remaining time between them. When it is resting because you operated something, it shows a hand mark in orange.

### Rules

| Item | What it does |
|---|---|
| What to cycle | Scenes / clips in L1 and up |
| Interval | Bars, seconds, or minutes. Bars switch at a good boundary |
| Jitter | With seconds or minutes, varies the interval so it doesn't look mechanical |
| Order | Random (avoids the current one and recent ones) / In order |
| Transition length | As set in the scene or layer / Instant / seconds |
| Scenes to use, Clips to use | Thumbnail tiles. Press to exclude or include |

Each rule can be turned on or off, advanced with “Next Now”, or deleted.

## When you operate manually

When you trigger a scene or clip yourself, that rule rests for a set time (1 minute by default).

## Undo and saving

- Automatic switches (and their fades) are not recorded for undo. When you come back and press `⌘Z`, your own actions are undone.
- Rules are saved in the project. On/off is not saved (it is always off when a project is opened).
- When the autopilot changes the output, an airplane mark appears on the output monitor.
