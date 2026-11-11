# Light, Shape and Glitch Effects

Values of the effects in the "Light / Blur", "Shape" and "Glitch / Digital" categories.

## Light / Blur

### Bloom

Takes the areas brighter than the threshold, shrinks them to 1/4 and 1/8 to blur them widely, and layers them on top.

Values: Threshold, Softness, Strength, Tint (glow in the color below), Original image, Spread.

### Edge Neon

Extracts edges and makes them glow like neon tubes.

Values: Strength, Thickness, Color (Original color, 1 color, Rainbow), Original image, Light spread, Threshold.

### Zoom Blur

A blur streaking out from the center.

Values: Strength, Center, Spin blur, Smoothness.

### Blur

A plain blur. Wide blurs shrink the image by halves first, so they stay light.

Values: Amount (px at 1080p; 0 leaves the image unchanged), Type (Normal, Horizontal only, Vertical only), Keep highlights (mixes in the brighter of the blurred and original image for a soft-focus look), Edges (Stretch, Transparent).

### Tilt-Shift

Blurs outside an in-focus band so the scene looks like a miniature. The farther from the band, the stronger the blur.

Values: Blur (px at 1080p), Band position, Band width, Falloff softness, Rotation (tilts the band), Shape (Band, Circle (sharp only around the center)), Saturation, Contrast. With Blur 0, Saturation 100% and Contrast 100% the image is unchanged.

### Emboss

Turns brightness slopes into a lit relief.

Values: Strength, Light direction (135° lights from the upper left), Light rotation speed, Thickness (px at 1080p), Color (Gray relief, Over original colors, Metal), Original image, Smooth (blurs a little first). Strength 0 with Over original colors leaves the image unchanged.

## Shape

### Kaleidoscope

Cuts the image into a wedge and arranges copies like mirrors, rotating them.

Values: Segments, Rotation speed, Rotation, Center, Zoom, Sample offset, Mirror, Sample angle and Sample rotation speed.

### Glass Shards

Breaks the image into cell-shaped shards of glass, each offset separately.

Values: Shards, Offset, Motion speed, Edge lines, Refract, Color shift, Edge brightness.

### Lens

Distorts the image by distance from the center.

Types: Fisheye (bulge), Pinch (pincushion), Twirl (stronger toward the center), Magnifier (zooms only inside the circle), Ripple lens.

Values: Strength (0 leaves the image unchanged), Size (radius of the effect), Center, Color fringing (red and blue get slightly different strengths), Edges (Stretch, Mirror, Transparent).

### Polar

Wraps the image into a ring (horizontal becomes angle, vertical becomes radius; at first the bottom edge goes to the center, like a "tiny planet"). Unwrap does the opposite and straightens a ring.

Values: Direction (Wrap into a ring, Unwrap), Rotate, Rotation speed, Repeats, Radius offset, Radius flow speed (flowing makes a tunnel), Center, Mirror the seam, Swap inside and outside.

### Tile

Shrinks the image and repeats it.

Values: Columns and Rows (fractions cut a tile partway), Lock (rows = columns), Mirror (Off, Horizontal, Vertical, Both), Row offset (brick layout), Scroll speed (horizontal and vertical, in tiles per second), Gap (transparent), Rotate each tile. With 1 column and 1 row the image is unchanged.

### Shake

Shakes the whole image: handheld camera, earthquake, zoom pulse.

Values: Shake (px at 1080p), Speed (times per second), Type (Smooth, Jerky, Horizontal only, Vertical only), Rotation, Zoom pulse, Motion blur (blurs along the motion), Edges (Stretch, Mirror, Transparent, Zoom in to hide).

Shake at 0 stops everything, including rotation and zoom pulse, and leaves the image unchanged (rotation and zoom pulse grow as Shake goes from 0 to 20 px). Assign Shake to audio or beat motion to shake the screen on the kick.

### Shift by Brightness

Displaces the image by its own brightness (or color, or contours), so bright areas seem to pop out.

Values: Offset (px at 1080p; 0 leaves the image unchanged), Rotation, Displace by (Brightness, Red and green (red moves sideways, green up and down), Contours (along the brightness slope)), Blur the map first (smooth warps), Neutral brightness (areas this bright do not move), Color shift (red, green and blue move by different amounts), Edges (Stretch, Mirror, Transparent).

### Droste

The picture repeats inside itself, smaller each time, like facing mirrors.

Values: Shrink ratio, Count (1 to 12; deeper levels keep showing the last level), Rotate (angle per level), Rotation speed, Zoom speed (pulls into or out of the nest; one level later it looks the same again, so it loops forever), Center, Frame (a line on the edge of each level, in the "Color"), Shape (Square, Circle), Fill the outside too (when the center is moved, fills the outside with an enlarged picture). Count 1 and Zoom speed 0 leave the image unchanged.

## Glitch / Digital

### RGB Split

Offsets red, green and blue.

Values: Offset, Rotation, Shape (Straight, Radial, Wobble), wobble, Wobble speed.

### Mosaic / Halftone

Square, Round dots, Halftone (brighter means bigger dots), Horizontal lines.

Values: Size, Rotation, Dot size, Transparent gaps.

### Pixel Sort

For each continuous run (band) whose brightness is between the thresholds, re-sorts the pixels by brightness so they melt and stream vertically or horizontally.

Values: lower and upper threshold, Streak length, Direction, Reverse, Detail.

### Datamosh Style

Finds the block-by-block motion from the previous frame and drags the stored image along the direction of motion. The current image is mixed in only little by little. Resets to the original on the beat.

Values: Blocks, Motion strength, Mix in the current image, Color bleed, Every how many beats.

### ASCII Mosaic

Turns brightness into characters.

Values: Character size, Characters (Symbols, Blocks, 0 and 1, Katakana), Color (Original color, 1 color, Green screen), Contrast, Background.

### Dither

Reduces the image to 2 to 8 colors and shows brightness with dots.

Values: Palette (Monochrome, Handheld green, 4-color retro PC, Reduce original colors, Palette), Dot size, Layout (Ordered, Noisy), Contrast.

### LED Wall

Turns the image into a wall of LEDs: dots up close, a picture from afar. Each cell takes its color from its center.

Values: Cell size (px at 1080p), Shape (Round dots, RGB stripes, Square), Particle size (relative to the cell), Brightness (makes up for the dark gaps), Glow (light around each dot), Panel seams (every 8×8 dots the brightness differs a little, with a thin line at the border), Transparent gaps.

### Slices

Cuts the image into bands and shifts each band sideways (up and down for vertical bands). Great when driven by the beat.

Values: Direction (Horizontal bands, Vertical bands), Bands, Offset (relative to the screen width; 0 leaves the image unchanged), Shift pattern (Random, Staggered, Wave, Stairs), Change rate (reshuffles per second; 0 stops), Smooth (eases between reshuffles), Uneven band widths, Shift colors too, Edges (Mirror, Stretch, Transparent).

### Stretch

Stretches the pixels on one line all the way to the edge, like a moving scanner.

Values: Direction (Right, Left, Down, Up, Both sides), Position (where the line is; for Both sides, the width kept in the middle), Position wobble (each row shifts the line, giving a sawtooth edge), Wobble detail, Wobble flow speed, Blend (mixes with the original just before the line), Add streaks (thin streaks in the stretched area). A position with nothing to stretch (100% for Right) leaves the image unchanged.
