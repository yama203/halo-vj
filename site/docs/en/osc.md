# OSC

How to control Halo VJ from an iPad (TouchOSC, etc.) or TouchDesigner using OSC under “Connect” at the top, and the values Halo VJ sends.

## Receiving

The port is 9000 by default.

- This Mac's IP address, to enter as the destination on the sender, is shown.
- The 6 most recent messages received are shown.

### Fixed addresses

Numbers start at 1.

- `/halo/layer/L/clip/C` (triggers a clip)
- `/halo/column/C`
- `/halo/layer/L/stop`
- `/halo/layer/L/opacity 0-1`
- `/halo/stop`
- `/halo/master/opacity`
- `/halo/master/volume`
- `/halo/blackout [0/1]`
- `/halo/bpm <number>`
- `/halo/tap`
- `/halo/resync`
- `/halo/pad/N 1/0` (press / release)
- `/halo/cue/next`
- `/halo/cue/back`
- `/halo/cue/N`
- `/halo/scene/N`
- `/halo/deck/N`
- `/halo/record [0/1]`
- `/halo/auto` (autopilot → [Autopilot](autopilot.md))

A button value of 0 (released) does not trigger, stop, etc.

### Any value over OSC

Set a value's motion to “OSC” with its waveform button and enter an address, or press “Learn” and move a fader; the value (0–1) then moves it between “From” and “To”. The reverse direction also works. Until a message arrives, the original value is kept. → [Animating values](animation.md)

## Sending

The destination is 127.0.0.1:7000 by default.

Sent 30 times per second:

- `/halo/bpm`
- `/halo/beat` (beat count)
- `/halo/beat/phase`, `/halo/bar/phase` (0–1)
- `/halo/audio/level`, `low`, `mid`, `high`, `attack`

Sent when a clip is triggered:

- `/halo/layer/L/clip` (name)

In TouchDesigner, receive them with the OSC In CHOP.

## Saving

Settings are per Mac (not stored in the project; motion settings are).
