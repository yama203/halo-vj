# Layers

Using the layer column on the left; adding, reordering, naming and setting the volume of layers; and transitions between clips.

![The layer column](shots/en/layers.jpg)

## Layer column

The layer column on the left shows opacity, stop, blend mode and the name of the playing clip. Click it to make it the target of the layer tab in the parameter panel below.

| Action | Effect |
|---|---|
| Drag the bar with the ◐ mark left or right | Opacity (double-click for 100%) |
| “S” | Solo. Only soloed layers are shown (video and audio; any number). Others are dimmed. For checking, not saved |
| Button such as “Normal” on the lower line | Click to choose the blend mode on the spot (purple when not Normal). → [Blend Modes](blend-modes.md) |
| Eye button | Mute. → [Play, Stop and Blackout](clips-play.md) |
| Vertical bar on the right | The layer's volume (drag up or down, `⇧` for fine adjustment, double-click for 100%). The speaker above mutes only the audio |

## Naming

Double-click “L1” in the layer column to name the layer (or right-click → “Rename…”).

- The number, such as L1, stays as a marker.
- The name appears on the lower line of the layer column and on the tab in the parameter panel (without a name, the lower line shows the playing clip's name).
- The name follows the layer when you move it.
- Not included in scenes. Saved with the project.

## Reordering

Drag a layer in the layer column up or down to change the layer order (or right-click → “Move Up” / “Move Down”).

- Clips, what's playing and settings move with it.
- Scene contents are reordered too (also when adding or removing layers).

## Adding and removing layers and columns

- “Add Layer” adds a layer at the bottom, and the “＋” to the right of the column numbers adds a column at the right end.
- Right-click the layer column or a column number to add above/below (left/right) or delete (with confirmation if it contains clips).
- Adding or removing in the middle doesn't stop playing clips (only clips in the removed row or column stop and are removed).

## Transition

“Transition” in the layer tab sets how a new clip appears when switching clips on that layer.

- Cross: gradual crossfade (the classic behavior)
- Wipe: from left to right
- Circle: from the center
- Noise: melts in here and there
- Luma: from the bright areas of the new clip
- Glitch: blocks swap in randomly, with rows shifting sideways midway

The switch takes the “Transition Fade” time (0 = cut). Except for Cross, the previous clip stays underneath and the new clip is revealed in a shape (when the blend mode is “Normal”; other blend modes use Cross). Saved with the project.
