# Adding and Ordering Effects

How to add effects to a clip, layer or composition, and how to reorder, adjust and mask the effects you added.

## Add from the "Effects" panel

The "Effects" panel lists the effects (grouped into Color, Shape and Time, with search). Drag one to where you want it.

| Drag to | Applied to |
|---|---|
| Clip thumbnail | Clip |
| Layer row | Layer |
| Output Monitor | Composition |
| Effects section of the Parameters panel | That tab |

Double-click to add it to the tab that is open now.

## Add without dragging

- The "Add Effect" button (in the effects section of the Parameters panel and in FX pad settings) opens the search window.
- The right-click menu (clip slot, layer row, Output Monitor, FX pad) has "Find and Add Effect…" and an "Add Effect" menu grouped by category.
- An empty slot in an adjustment layer has "Make Effect Clip With…". → [Adjustment Layers](adjustment-layers.md)
- Clicking an empty FX pad opens its settings, where you can also add one.

An added card opens expanded.

## Search window (`⌘E`, "Effects" menu)

![The effect and generator search window](shots/en/search.jpg)

- Type to filter (name, description, English name). Hiragana also matches katakana names. Separate words with spaces to match items containing all of them.
- Choose with ↑↓ and press Enter, or click, to add. Esc closes it.
- The `⌘E` window also shows generators. Effects go to the current tab (composition, layer or clip); generators go to an empty slot in the selected layer.
- A preview of the selected item appears on the right.

## Favorites and recently used

Put the effects and generators you use often in your favorites to find them quickly.

- Hover over an item in the "Effects" or "Generators" panel to show a star at its top right. Click it to add the item to your favorites (click again to remove it). You can also use "Add to Favorites" and "Remove from Favorites" in the right-click menu. Favorite items always show a small star.
- The top of the panel shows "Favorites" (in the order you added them) and, below it, "Recently Used" (up to 8, newest first). You can drag or double-click them like any other item. They are hidden while you search.
- In the search window, "Favorites" and "Recently Used" also appear at the top when nothing is typed. While you search, favorites come first among equally good matches. You can also toggle them with the star at the right end of a row or the right-click menu.
- "Recently Used" lists what you added from the panel, the search window or a menu (not undo, scene recall or opening a project).
- Favorites and recently used items are saved as app-wide settings and are the same in every project.

## Previews

Hover over an item in the "Effects" or "Generators" panel list to show a small window with a moving preview and a description.

- For effects, the preview shows the effect at its initial values on sample images (sunset, moving balls, text, bars).
- Camera, Syphon and NDI inputs do not run the preview.

## Effects section of the Parameters panel

The effects that are applied are listed here. They have purple headers with a purple strip on the left edge (generator settings are teal, so you can tell them apart at a glance).

- They are applied from top to bottom.
- You can turn them on/off, reorder, delete and adjust them.
- Numeric values can be animated by seconds or BPM with the waveform button.

### Opacity

Every effect has "Opacity" (how strongly it is applied).

- 0% is the original image; 100% is full strength.
- It can be animated with the waveform button.
- When lowered, the % is also shown on the collapsed header.

### Reset to the initial state

The ↺ button resets values, motion, opacity and colors to the initial state. Generator text, free-shape points and on/off are kept. It is disabled when nothing has changed.

### Order of application

- Clip effects are applied after the clip's transform (position, scale, rotation). If you apply Mirror to a rotated clip, the rotated image is mirrored.
- An adjustment layer replaces the image below with the image passed through its effects (by its opacity).
- A mask cuts out the entire image below with its shape, and the outside becomes black. Masks are cut out last regardless of their position in the list.

## Masks

- Mask (shape): cuts out with a square or circle (position, size, rotation, blur, invert).
- Mask (free shape): use "Edit Shape" on the card to draw a shape over the preview on the left.
  - Click: add a point
  - Drag: move a point
  - Drag inside: move the whole shape
  - Right-click: delete a point

For the blend modes "Mask (white shows / white hides)", which cut out the image below by the layer's brightness, see [Blend Modes](blend-modes.md).
