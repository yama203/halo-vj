# More Generators

Generators added later (Reaction-Diffusion, Fractal, Growth, Metaballs, the light and space ones, Logo Particles, and the second batch: Plasma, Aurora, Nebula / Smoke, Truchet Tiles, Hexagon Tiles, Code Rain, Spinning Wireframe, Moiré, and the third batch: Sunburst, Ridge Lines, Bokeh, Spiral, Cells (Voronoi), Lissajous, Fireworks, Fire). Some have "Look" buttons. All values can be driven by sound, the beat or OSC.

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

### Ridge Lines

Many horizontal lines stacked vertically, each rising into flowing noise peaks (like a radio pulse plot).

- Hide: fills black under the front peaks so they hide the lines behind. Turn it off and the lines overlap (the surroundings are transparent).
- Gather to Center: the ends stay flat and only the middle rises. Perspective: lines further back get thinner, darker and closer together.
- Coloring: 1 color, Palette (front → back), Rainbow.

### Spiral

A hypnotic rotating spiral.

- Shape: Logarithmic Spiral, Even Spiral, Rings (concentric circles flowing outward). Arms, Winding, rotation speed (°/s).
- Coloring: 2 colors (the first palette color for the bands, the last for the gaps; make the last one black for transparent gaps), Palette (per arm), Rainbow (angle), Rainbow (radius).
- Warp makes the arms wave. Tunnel darkens the center for depth. Near the center, detail finer than a pixel fades to its average brightness so it doesn't flicker.

### Cells (Voronoi)

A moving cell pattern.

- Style: Outline (glowing borders), Fill (color per cell), Distance (bright centers), Cracks (thin black lines).
- Randomness: 0 gives a neat, nearly hexagonal layout. Pulse makes each cell's brightness throb.

## "Shapes / Particles" category

### Metaballs

A lava lamp.

### Spinning Wireframe

Draws only the edges of a cube, tetrahedron, octahedron, icosahedron, sphere, torus or pyramid as glowing lines, and spins it. The surroundings are transparent.

- Rotation Speed X / Y / Z (°/s), Perspective (0 is parallel projection), Dim the Back (back edges get darker and thinner).
- Coloring: 1 color, Rainbow (per edge), Palette by Depth.
- Count: nests up to 5 copies of the same shape at different sizes.

### Sunburst

Rays radiating from the center rotate. The gaps are transparent.

- Count, Band width, Twist (makes a swirl), Center X / Y, Center Hole, Fade Outward.
- Coloring: 1 color, Palette (per band), Rainbow. Pulse makes the band widths throb (with its own speed).

### Lissajous (Oscilloscope)

Glowing curves made from combined sine waves, like an oscilloscope. The surroundings are transparent.

- The X and Y frequencies set the shape, and the rotating phase animates it. Detune keeps the shape slowly changing.
- Trail Length: 1 draws the whole curve; shorter makes a dot of light run along it. Rotate in 3D turns it into a spinning 3D figure.
- Count: up to 4 curves with offset phases. Coloring: 1 color, Rainbow (along the curve), Palette.

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

### Bokeh

Out-of-focus balls of light slowly drift and twinkle, brighter where they overlap. The surroundings are transparent.

- Count, Size, Size jitter, Rim Strength (a bright ring at the edge), Shape (Circle, Hexagon, Octagon).
- Depth adds small, dim balls in the back. The bigger the balls, the fewer fit on screen.

### Fireworks

Fireworks launch one after another and burst, with sparks falling under gravity as they fade. The surroundings are transparent.

- Launch Rate (/s), Size, Particles, Gravity, Trail Length, Twinkle (flicker as they fade), Show Rising Trails.
- Shape: Circle, Ring, Willow (heavy, long-falling), Double. Up to 6 shells are open at once.

### Fire

Flames rising from the bottom. Areas without fire are transparent.

- Height, Speed, Detail, Jitter, Width (1 fills the screen; narrower makes a campfire in the middle).
- Coloring: Fire (black → red → orange → yellow → white), Blue Flame, Palette, 1 color. Sparks, Smoke.
- Direction: flow up, down, left or right.

## "Text / Logo / Clock" category

### Code Rain

Columns of katakana and digits streaming down. The head is bright and the trail fades away. The surroundings are transparent.

- Character Size (rows on screen), Fall Speed, Trail Length, Column Density, Character Change Speed, Head Whiteness, Glow.
- Direction: flow down, up, right or left. Set the color with "Color" (green at first).

### Logo Particles

Turns an image (a PNG with transparency is recommended) or text into particles of light, and sets how they scatter (Explode, Wind, Swirl) and the return speed. Choose an image or type text in the clip tab.
