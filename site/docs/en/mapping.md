# Output Mapping

Projection mapping and sending different parts to multiple outputs, done with “Output Mapping…” (`⌘⇧M`) in the Output menu.

![The Output Mapping window](shots/en/mapping.jpg)

## What it does

- Projection mapping.
- Sending different parts to multiple projectors, LED walls, or separate displays (Output 1–3).

When it is not used, things work as before (the whole image goes to Output 1 with the corner adjustment; Outputs 2 and 3 are black).

The mapping is saved in the project, and undo works for it.

## Window layout

The window has 3 columns.

### Left: list

The list of **slices** and **masks**.

- Drag to reorder. Items lower in the list are in front.
- The eye button shows or hides an item.
- “＋” adds a rectangle / triangle / polygon slice, or a mask.
- Duplicate, delete.

### Center: stage

- “Input”: on the composition image, drag the rectangle to sample. Corners and edges resize it; the circle on top rotates it.
- “Output”: on the output screen, fit the surfaces and masks.
- Scroll to zoom, `⌥`-drag to pan, and “Fit” to reset the view.

### Right: settings

Settings for the selected item.

## Output points

There are 3 kinds of points for the output:

- “Corners”
- “Mesh”: warps the surface with grid points. Cells from 1 to 8, with smoothing.
- “Crop”: a polygon inside the surface (for triangle and polygon surfaces).

A mask is a polygon of points that is filled black. Inside and outside can be inverted.

### Working with points

- Click to select, `⇧`-click to add to the selection, or drag a box to select.
- Arrow keys move by 1 output pixel (10 with `⇧`).
- Click an edge to add a point.
- Delete removes points.
- “Snap” snaps to other points and to the edges and center of the screen.

## Per-slice settings

- Source: the whole composition, or a single layer.
- Rotation and flipping of the input.
- Edge blend width (blends by light level).
- Opacity, brightness, contrast, red/green/blue.

## Alignment tools

- “Guide on output”: shows the outline and points of the selected item on the actual output.
- For each output, a photo of the venue can be placed underneath as a backdrop (only in this window).
- The test pattern is a colored grid and edges for each slice.

## Presets

- 1 projector
- 2 / 3 side by side (blended with 15% overlap, or no overlap)
- 2 stacked
- 2 / 3 side by side within one output

## Saving and loading

The mapping alone can be saved to and loaded from a `.halomap` file.
