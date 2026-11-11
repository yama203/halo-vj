# Loading Clips

How to place videos and still images in grid slots, and which media formats can be loaded.

## Placing clips

- Click the “＋” at the top right of an empty slot.
- Right-click an empty slot.
- Drop a video onto an empty slot.
- Drag from the “Sources” panel to a grid slot.

If you choose several files, they fill the slots to the right in order (up to the right end of the row).

For placing generators (images placed instead of a video), see [Generators](generators.md).

## Supported videos

- Videos that AVFoundation can read.
- HAP videos: Hap, Hap Alpha, Hap Q, Hap Q Alpha, Hap R. AVFoundation can't read these, so the app reads the compressed data directly, decompresses the Snappy data and draws it on the GPU. Layering several 4K clips stays light.

## Supported still images

- PNG, JPEG, HEIC, TIFF, GIF, WebP.
- PSD (the flattened composite).
- PDF and AI (first page; AI files must be saved with “Create PDF Compatible File”).
- SVG.

Transparent areas stay transparent.

### Animated images

GIF, APNG and WebP animations play.

- They loop using each frame's display time.
- Clip speed and composition speed apply.
- Large ones are scaled down on loading to fit in memory.

## “Sources” panel

Lists the videos and still images in folders on your Mac.

- Add and switch folders with the menu at the top. You can also browse subfolders.
- You can search by name. Sizes are L / M / S.
- Move the pointer left and right across a thumbnail to scrub through its contents.
- Double-click to preview (no sound, looping).
- Drag to a grid slot to place it.
- Added folders are kept in the app settings (not in the project).
