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

## Shape

### Kaleidoscope

Cuts the image into a wedge and arranges copies like mirrors, rotating them.

Values: Segments, Rotation speed, Rotation, Center, Zoom, Sample offset, Mirror, Sample angle and Sample rotation speed.

### Glass Shards

Breaks the image into cell-shaped shards of glass, each offset separately.

Values: Shards, Offset, Motion speed, Edge lines, Refract, Color shift, Edge brightness.

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
