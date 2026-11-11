# More Generators

Generators added later (Reaction-Diffusion, Fractal, Growth, Metaballs, the light and space ones, Logo Particles, and the second batch: Plasma, Aurora, Nebula / Smoke, Truchet Tiles, Hexagon Tiles, Code Rain, Spinning Wireframe, Moiré). Some have "Look" buttons. All values can be driven by sound, the beat or OSC.

## "Lines / Patterns" category

### Reaction-Diffusion

Coral, maze, spot, fingerprint and mitosis patterns grow slowly.

- Flow: carries the pattern on a swirling flow whose direction changes slowly (once per frame), so it keeps moving even when fully grown.
- Keep changing: varies how each area grows with slowly drifting unevenness, and occasionally opens holes that then grow back.
  - A hole spreads from its center over the number of seconds set in "Hole speed".
  - The pattern inside dissolves away, and nothing grows while the hole is open.
  - Once fully open, it grows back in from the surroundings.
- Wither / Lifespan: growing areas age, and after the lifespan (seconds) they weaken and wither.
  - Withered areas rest for a while with nothing growing (like scorched land after a wildfire); afterward the pattern grows back in from the surroundings (waves of birth and death).
  - Older areas get darker, and with a palette their color changes too.
- Disturb with sound: disturbed strongly at the moment of an attack, and grows faster with the low end.
- Glow with sound: brighter with louder sound, and the edges glow.
- Seeding.

### Fractal

Dives into Mandelbrot, Julia or Burning Ship and comes back. Colors: Palette or Rainbow.

### Growth

Circuits, branches and hyphae extend, and older lines gradually fade.

### Plasma

Smoothly undulating color fields, like old-school demos.

- Warp: bends the coordinates to make the shapes organic.
- Coloring: Rainbow, Palette, Palette Bands (repeats the palette colors), Monochrome. Color Cycle Speed makes the colors flow.
- Bands: splits the colors into 2–12 steps. 0 is smooth.

### Truchet Tiles

Quarter circles (or diagonals, triangles) in randomly oriented tiles join up into a maze-like pattern. The surroundings are transparent.

- Turn Speed: each tile spins 90° at its own moment.
- Flow Direction / Speed: scrolls the whole pattern.
- Two-Color Fill: fills the areas separated by the lines with the first and last palette colors (the background gets filled too).

### Hexagon Tiles

Honeycomb tiles light up one by one. Unlit tiles are transparent.

- Flash style: Wave (rings spreading from the center), Noise, Random (each tile blinks), Flow (a diagonal sweep).
- Amount Lit: how many tiles are lit.
- Coloring: 1 color, Palette (mixed by the brightness of lit tiles), Rainbow (per tile).

### Moiré

Two or three slightly offset sets of rings or lines overlap, producing moving interference patterns. The surroundings are transparent.

- Shape: Rings + Rings, Lines + Lines, Rings + Lines, Rays + Rays.
- Blend Mode: Cancel Overlaps (XOR; palette colors from the center outward) or Add (one palette color per set).
- Where the lines get finer than a pixel, they fade to their average brightness so they don't flicker.

## "Shapes / Particles" category

### Metaballs

A lava lamp.

### Spinning Wireframe

Draws only the edges of a cube, tetrahedron, octahedron, icosahedron, sphere, torus or pyramid as glowing lines, and spins it. The surroundings are transparent.

- Rotation Speed X / Y / Z (°/s), Perspective (0 is parallel projection), Dim the Back (back edges get darker and thinner).
- Coloring: 1 color, Rainbow (per edge), Palette by Depth.
- Count: nests up to 5 copies of the same shape at different sizes.

## "Light / Space" category

### Laser Show

Count, Fan spread, sweep, rotation, Origin (Bottom, Top, Center, Left / Right), Haze, Blink on beat.

### Synthwave Terrain

A glowing grid floor with wireframe mountains and a sunset.

### Starfield Warp

Raise the speed and the stars turn into streaks.

### Water Ripples

Drops fall on the beat, with sound, or now and then.

### Lightning / Discharge

Branching lightning strikes on the beat, on sound attacks, or now and then.

### Aurora

Curtains of light hanging in the night sky. Vertical streaks slowly sway sideways. The surroundings are transparent.

- Colors go from the palette's bottom color → top color (green → purple at first).
- Height, Undulation, Streak Detail, Curtains (1–4 layered at different depths), Brightness, Show Stars.

### Nebula / Smoke

Smoke or nebula that slowly billows and swirls. Thin areas are transparent.

- Swirl Strength: how much it twists. Density: the amount of smoke. Flow Direction / Speed moves the whole thing (90° is up).
- Coloring: Palette, Rainbow, Fire (black → red → yellow → white), Ice (black → blue → white). Stars can be shown too.

## "Text / Logo / Clock" category

### Code Rain

Columns of katakana and digits streaming down. The head is bright and the trail fades away. The surroundings are transparent.

- Character Size (rows on screen), Fall Speed, Trail Length, Column Density, Character Change Speed, Head Whiteness, Glow.
- Direction: flow down, up, right or left. Set the color with "Color" (green at first).

### Logo Particles

Turns an image (a PNG with transparency is recommended) or text into particles of light, and sets how they scatter (Explode, Wind, Swirl) and the return speed. Choose an image or type text in the clip tab.
