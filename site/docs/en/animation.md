# Animating Values

How to drive values automatically with the waveform button to the right of a number field. Choose from Fixed, Time, BPM, Audio and OSC / MIDI.

## Motion types

| Motion | Description |
|---|---|
| Fixed | No motion |
| Time | Seconds per cycle |
| BPM | Beats per cycle |
| Audio | Driven by the sound from “Audio Input” |
| OSC / MIDI | Driven by an OSC address or a MIDI knob |

## Direction and range

- The direction is forward, reverse, ping-pong or random.
- Set the range (“From” and “To”).
- While the value is moving, the field keeps showing the current value.

## Values that can be animated

- Position, scale, rotation and opacity (clip, layer, composition) and master opacity.
- Effect and generator values.
- Blend mode values.

## Driving with audio

With the motion set to “Audio”, the value moves between “From” and “To” by the selected band × sensitivity (Invert: louder moves toward “From”).

The bands are Volume, Low, Mid, High and Attack. For setting up the audio input, see [Audio Input and BPM](audio-input.md).

## Driving with OSC

Set the motion to “OSC” and enter an address, or click “Learn” and move a fader; the value (0–1) then moves between “From” and “To”.

- Invert is available.
- Until a message arrives, the original value is kept.

→ [OSC](osc.md)

## Driving with MIDI knobs and faders

Set the motion to “OSC / MIDI”, click “Learn” and turn a knob; the value then follows it (the address is /midi/channel/cc/number).

→ [MIDI Controllers and Keys](midi.md)

## Saving

Motion settings are saved in the project. The audio input, OSC and MIDI settings themselves are per Mac and are not saved in the project.
