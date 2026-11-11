# Live Panel and Tempo

The progress bar and the tempo controls (BPM, tap, downbeat) in the “Live” panel.

![The Live panel: tempo and composition speed](shots/en/live.jpg)

## Progress bar (scrubbing)

Drag the progress bar in the “Live” panel to scrub. Release it to play from that position. The audio follows as well.

## Tempo

“Tempo” in the “Live” panel has the following:

- BPM: drag to change.
- TAP: press a few times on the beat. The moment you press becomes the downbeat.
- Resync: makes now beat 1.
- Beat display.

“Auto” in the BPM field keeps matching the BPM and downbeat to the audio. → [Audio input and BPM](audio-input.md)

BPM changes do not count as undo steps (it is a value you change during a show).

Over OSC, `/halo/bpm <number>`, `/halo/tap`, and `/halo/resync` are received. → [OSC](osc.md)
