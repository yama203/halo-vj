# Effect List

The effects in the "Effects" panel and what each category contains. Detailed values for the analog gear, light, blur and glitch effects are on their own pages.

## List

| Category | Effects |
|---|---|
| Color, Shape, Time | Mirror / Colorize / Levels / Posterize (color levels, dither, dots) / Invert (color and brightness, luminosity, color only; amount) / Posterize Time (frame rate that drops frames) / Strobe / Echo (trails) / Mask (shape) / Mask (free shape) / Warp (organic distortion) / Time Displace (slit scan) / Fluid (flowing paint) / Keyer (luma / color to transparent) |
| Analog Gear | Glitch Box / VHS Tape / Video Feedback / Raster Scan / CRT Monitor → [Analog Gear Effects](effects-analog.md) |
| Light / Blur | Bloom / Edge Neon / Zoom Blur / Blur → [Light, Shape and Glitch Effects](effects-glitch.md) |
| Shape | Kaleidoscope / Glass Shards / Lens / Polar / Tile / Shake → [Light, Shape and Glitch Effects](effects-glitch.md) |
| Glitch / Digital | RGB Split / Mosaic / Halftone / Pixel Sort / Datamosh Style / ASCII Mosaic / Dither / LED Wall / Slices → [Light, Shape and Glitch Effects](effects-glitch.md) |

For Mask (shape) and Mask (free shape), see [Adding and Ordering Effects](effects.md).

## Colorize

As in Resolume, there are two modes. The hue can also be shifted.

- Color: one color. Keep brightness or not.
- Palette: replaces brightness with palette colors. Presets are available.

## Keyer

Makes part of the image transparent by brightness or color (in the "Color" category), so the layer below shows through.

- Key by: Dark areas, Bright areas, Color.
- Threshold: for dark or bright areas, how much to remove. 0 removes nothing.
- Softness: the width of the edge between removed and kept areas.
- Color and Color range: for Color, the color to remove (green at first) and how close a color must be to be removed (by hue and saturation).
- Spill removal: for Color, subtracts the key color from what remains (removes green fringes from a green screen).
- Invert: swaps what is kept and what is removed.
- Show matte: shows what stays in white and what is removed in black.

## Warp (organic distortion)

Distorts the image smoothly (in the "Shape" category).

Types:

- Liquid: re-samples the noise at the distorted position. Raising the viscosity layers the distortion into patterns that look alive.
- Heat haze: flows upward while wavering sideways.
- Swirl: flows in swirls.
- Ripple: ripples along contour lines.

Values: Strength (px at 1080p; looks the same at any resolution), Warp scale, Speed, Detail, Viscosity, Color fringing (red and blue bleed in the direction of the offset), Screen edges (Stretch, Mirror, Transparent).

## Time Displace

Shows a slightly earlier frame in each place (slit scan; in the "Time" category).

- Remembers up to 4 seconds in the past at 30 frames per second, and blends smoothly between them.
- Direction: Vertical (past toward the top), Horizontal (past toward the left), Circle (past toward the center), Noise (moves slowly), Luma (past in brighter areas).
- Reverse, Stepped (bands of 2 to 32 steps), noise detail and speed.
- Stored frames are up to 540 px high.

## Fluid

Moves paint with a real fluid simulation (incompressible flow) (in the "Shape" category).

Motion in the image (where brightness changes) pushes the flow, and the paint (the colors of the original image) rides it, swirling and mixing like smoke or ink, and lingering.

Values: Push with motion, Paint amount, Add paint at (Moving areas, Bright areas, Total), Paint persistence, Swirl, Wind (flows even with a still image), Viscosity, Original image (how much shows underneath), Detail (Coarse, Normal, Fine).
