# Interface Overview

The main areas of the Halo VJ window, and how the grid, layers and number fields are displayed.

## Grid and layers

- Each row of the grid is one layer. The default is 4 rows × 8 columns. You can add up to 16 layers and 64 columns. If they don't fit, the grid scrolls.
- One clip per row can play at a time, and higher rows are composited in front.
- Playing another clip in the same row switches only that row's clip.
- Adding or removing layers or columns in the middle doesn't stop playing clips (only clips in the removed row or column stop and are removed).

## Main areas

![The top bar](shots/en/topbar.jpg)

| Area | Contents |
|---|---|
| Layer column on the left | Opacity, stop, blend mode and name of the playing clip. Click to make it the target of the layer tab below. → [Layers](layers.md) |
| Grid | Slots for clips. “Deck” tabs and column numbers above it. → [Decks and Grid Display](decks.md) |
| Output monitor | The image being output. |
| Parameter panel at the bottom | Values for the composition, layer and clip. → [Parameter Panel](parameters.md) |
| Tabs at the bottom right | “Live”, “Scenes”, “Cues”, “Effects”, “Generators”, “Sources”. |
| “FX Pads” panel | Effects that apply only while held. → [FX Pads](fx-pads.md) |
| Top bar | Workspace, “Audio Input”, “Connect”, “Auto”, “Record”, “Output”, “Resolution / fps”, “Audio”, panels, and more. |

Click the icon at the left end of the top bar to show “About Halo VJ” (version number).

## Grid thumbnails

- Drawn on the same black background as the output.
- Media with transparency get a checkerboard mark at the bottom right.
- Dark media with transparency (such as a black logo) are shown on a gray background so they are visible.
- Media drawn small inside a large transparent area are zoomed to the drawn area (magnifier mark).
- While the mouse is over a thumbnail, the whole image is shown over a checkerboard to show the transparent area.

## Hovering over a clip slot

- Upper image area: ▶ appears. Click to send it to the output. For a playing clip it shows ↺ (restart from the beginning).
- Lower name strip: the strip turns light gray with a line above it. Click to select only (no output).
- The selected strip stays blue and gets slightly brighter.

## Number field colors

- Values changed from the default are orange.
- For values that can be positive or negative (position, rotation, speed, tilt, etc.), positive is orange and negative is light blue. A thin line below the field runs from 0 to the current value (showing direction and amount).

## Indicators for changes

### When the parameter panel switches

When the contents switch, for example by selecting a clip or layer, the edge of the panel flashes briefly (composition: orange, layer: blue, clip: green). What it switched to (such as “Clip ○○”) appears at the top right and fades out after 1 second.

### When the output changes

- When you trigger a clip, recall a scene or stop, the edge of the output monitor flashes briefly (clip: green, scene: purple, stopped: gray).
- What changed (such as “L3 Forest” or “Scene 4”) appears at the top left and fades out.
- Several changes at the same moment are combined into one, such as “Triggered 3 clips”.
- Clips triggered and layers stopped within a scene are not counted.
- Changes made by the autopilot show an airplane mark.

Both can be turned off in “Display” in the settings. → [Settings](settings.md)
