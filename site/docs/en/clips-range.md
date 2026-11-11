# Play Range, Speed and Jump

The play range (in point and out point), end behavior, speed and jump set in the clip tab, plus the overall speed and scrubbing.

## Play range

In “Play Range” in the clip tab, drag the two ends of the bar to set the in point and out point (double-click to reset an end).

- The clip's frames are shown behind the bar, and unused parts are darkened.
- “First frame” (in point) and “Last frame” (the frame just before the out point, the last one shown) appear above, so you can check that no black frames remain.
- The ◀ ▶ buttons next to In and Out move them one frame at a time (10 frames with `⇧`).
- The length is also shown in frames.

## At end

In “At End” in the clip tab, choose what happens when playback reaches the out point.

- Loop
- Ping-pong (plays backward from the out point and forward again from the in point)
- Stop at End
- Blackout

When triggered from a cue, this can be overridden in the cue settings. → [Cues](cues.md)

## Speed

### Manual

“Speed” in the clip tab sets the speed of the clip itself.

### BPM Sync

Switch “Speed: Manual / BPM Sync” to BPM Sync to play the play range (in point to out point) at the speed that loops it exactly once over the chosen number of beats (audio plays at the same speed).

- Follows BPM and tap.
- Clip speed and composition speed don't apply.
- The speed is limited to 0.05–8x.

### Composition speed

Drag the speed control at the bottom left or right to change the composition speed. It applies to all playing clips. Hold `Shift` for fine adjustment.

Right-click or double-click the speed control to reset it to 1.000x.

## Jump

“Jump” in the clip tab jumps to a random position within the play range every set number of beats (1/4–16 beats), on the BPM beat. Audio jumps too. The destination is preloaded, so the switch lands exactly on the beat.

## Scrubbing

Drag the progress bar in the “Live” panel to move the playback position. → [Live Panel and Tempo](live.md)
