# MIDI Controllers and Keys

How to assign actions to MIDI devices and keyboard keys using “MIDI controllers / keys” under “Connect” at the top.

## Connecting

All connected MIDI devices are listened to automatically (connecting and disconnecting are tracked).

## Buttons

Choose “Learn MIDI / Key to…” from the right-click menu of a clip or FX pad, then press a controller button (note or CC) or a keyboard key to assign it.

- Esc cancels. A guide appears at the top of the screen.
- Clips are remembered by row and column. When you switch decks, the same position in that deck is used.
- Pads apply only while held.
- Learning the same button again removes its previous assignment.
- The name of the assigned button appears on the clip and in the list (× removes it).

### Actions other than clips and pads

The following actions are assigned from “Choose an action” in “Connect”:

- Next Cue
- Previous Cue
- Blackout
- Tap
- Make Now Beat 1
- Stop All
- Record

Autopilot (“Auto”) can be assigned to MIDI or a key from its right-click menu.

### Button lights

Clips, pads, blackout, and recording assigned to notes send their current state back to the controller's button lights (the playing clip lights up).

## Knobs and faders

Set a value's motion to “OSC / MIDI” with its waveform button, press “Learn”, and turn a knob; the value then follows it (the address is /midi/channel/cc/number). → [Animating values](animation.md)

## Saving

Assignments are per Mac.
