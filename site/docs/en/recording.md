# Recording

How to record the composition to a video file.

## Starting and stopping

“Record” at the top, or `⌘R`, starts and stops recording.

- While recording, the button blinks red and the elapsed time is shown.
- When you stop, “Saved” appears along with Show in Finder.
- Recording works even when the window is hidden.

## What is recorded

- The composited image: before the corner adjustment, including pad effects. Blackout is not included.
- Clip audio: the output of the audio mixer, before the master volume and mute.

## Settings

Set these with ▾ to the right of “Record”.

| Item | Details |
|---|---|
| Format | H.264, HEVC, ProRes 422, ProRes 422 HQ |
| Size | Same as output, or 720p to 4K. The aspect ratio follows the output |
| Frame Rate | 24 to 60 fps. Timestamps come from frame numbers at the chosen rate, so if rendering falls behind, frames are skipped but the timing does not drift |
| Audio | Whether to record audio too |
| Save to | By default, Movies/Halo VJ 録画. File names are the date and time |

Settings are per Mac and are not stored in the project.

Recording can also be toggled with OSC `/halo/record [0/1]`, MIDI, or a key. → [OSC](osc.md), [MIDI controllers and keys](midi.md)
