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

## Saving the current frame as an image (snapshot)

Output menu > “Save Current Frame as Image” (`⌘⇧P`) saves the current frame as a PNG.

- It goes to the same folder as recordings. The file name is the date and time.
- When it's saved, “Saved” appears under ▾ to the right of “Record”.
- The image is the composite before the corner adjustment and output slicing, including pad effects. Master opacity and blackout are not applied.
- The size is the composition resolution. When all layers are stopped, the image is black.
- Colors match recordings (sRGB, 8 bits; transparent areas become black).

“Make Clip from Current Frame” saves the image the same way and also puts it as a still-image clip in the leftmost empty slot of the selected layer. If the selected layer is full, it goes to the first layer from the top that has room. It does not start playing. You can undo it with `⌘Z`. If there is no empty slot, the image is only saved.

OSC `/halo/snapshot` and `/halo/snapshot/clip` do the same. → [OSC](osc.md)
