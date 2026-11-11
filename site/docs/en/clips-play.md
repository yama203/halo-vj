# Play, Stop and Blackout

How to send clips to the output and stop them, and how to temporarily hide video and audio.

## Triggering a clip

- Click a slot to play it from the beginning (from the in point) the moment you click.
- You can also trigger clips with keyboard keys or MIDI buttons (right-click → “Learn MIDI / Key to trigger…”). → [MIDI Controllers and Keys](midi.md)
- Triggering another clip in the same row switches only that row's clip. How it switches is set by the layer's “Transition”. → [Layers](layers.md)

## Select only (no output)

Click the name strip below the thumbnail (or `⌥`-click) to select the clip without sending it to the output. You can play it in the clip preview while editing.

## Triggering a column

Click a column number above the grid to trigger the clips in that column on all layers at once (like column playback in Resolume).

- Layers whose slot in that column is empty stop.
- The number of the column currently playing lights up green.
- While editing a scene, the clips that scene plays become those in that column.

## Stopping

- Click an empty slot to stop that layer (as in Arena). While editing a scene, this sets that layer of the scene to “None”.
- `⇧Esc` stops all layers.

## Blackout

`Esc` toggles blackout. Clips keep playing in the background; only the output video and audio are hidden.

The time to fade to black and to fade back is set in the settings. → [Settings](settings.md)

## Mute (eye button)

Hides video and audio while playback continues (click again to restore). Saved with the project.

| Where to click | Target |
|---|---|
| Layer column, layer tab | That layer |
| Clip tab, thumbnail right-click | That clip (red mark on the thumbnail) |
| Above the output monitor, composition tab | The whole output (hidden immediately, no fade) |

## Muting audio only (speaker button)

The speaker button next to the volume field mutes only the audio (video stays). Clips, layers and the master each have one. It is red while muted. Saved with the project.

## Slot right-click menu

Right-click a slot to choose what happens at the end, replace the clip, or delete it.
