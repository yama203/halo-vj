# Life and Nature Generators

Values of the Flock, Physarum, Particle Life, Firefly Sync and Strange Attractor generators. In all of them, the surroundings are transparent.

## Flock (fish, birds)

A flock (boids) like sardines or starlings. Each fish is moved on the GPU, and simply by moving toward its neighbors (cohesion), matching their direction (alignment) and moving away when too close (separation), the whole flock undulates and changes shape.

- Count (up to 4000), Size.
- Shape: Fish, Birds (flapping), Particles, Line.
- Speed, Neighbor range.
- Wander: the flock slowly circles around the screen.
- Flee from predators: invisible predators move in and out of the flock, splitting it or opening holes, and it regroups.
- Jitter.
- Sparkle: brightness changes with direction, so when the flock turns together it flashes all at once.
- Depth: distant fish are smaller and darker.
- Screen edges: Bounce back / Wrap around.
- Color.
- Thickness (3D): raise it and they swim in 3D inside a box, drawn with perspective from a camera (orbit speed, angle, eye height, distance, field of view). Fish facing you look shorter, their sides shine when turned toward the light, and fish in front hide those behind. At thickness 0 the flock is flat, and depth is only an illusion that makes distant fish smaller and darker.
- Swirl: the flock circles around the center in a ring (in 3D, a tornado with a wider ring toward the top).
- "Look" buttons: Sardines, Starlings, Random, Tornado.
- When stopped, it stops, and continues from there.

## Physarum (slime mold)

Up to 1 million points that imitate how slime mold moves. Each one smells the scent (trails left by itself and others) ahead, to the left and to the right, turns toward the stronger side, moves forward and leaves a trail. That alone makes them build networks like leaf veins, nerves or river maps, and keep rearranging them.

- Count: the number on a 720p grid. Small previews reduce it to keep the same density.
- Speed, Sensor angle and Sensor distance, Turn angle, Trail length, Bleed, Brightness.
- Coloring: 1 color, Palette (by trail density).
- Food: None, Moving points, Rings (the network connects the food), and Food strength.
- Jitter.
- Starting shape: Random, Circle, From the center (changing it restarts the simulation).
- "Look": Leaf Veins, Fine Mesh, Cells, Wide Rivers, Connect Food.

## Particle Life

Particles (up to 6000) driven only by a table that sets, for each color (species), which colors to approach and which to flee. They move apart when too close, and at a little distance they attract or repel each other according to the table. That alone creates clusters that gather like cells, chase each other and orbit.

- Count, Species (up to 8 colors).
- Seed (character; changes the table).
- Force range, Force strength, Friction, Speed, Particle size, Glow bleed.
- Coloring: Rainbow, Palette.
- Reshuffle character: moves to the next seed every 1 to 32 beats, blending smoothly during the beat before the switch.
- Brightness, Trails.
- The screen edges wrap around.
- "Look": Creatures, Light Trails, Beat Morph, Big Cells.

## Firefly Sync

Each firefly flashes at its own speed and gradually matches the timing of the fireflies it can see around it (Kuramoto model). Even if they start out random, neighbors sync first, and eventually the whole field flashes at once.

- Count.
- Sync strength (at 0 they stay random).
- Sight range (100% is the whole screen).
- Flash speed, Speed variation, Flash length, Size, Glow bleed, Wander.
- Follow the beat: once every ½ to 4 beats, pulls them toward the downbeat (Pull to the beat).
- Brightness, Color variation.
- "Look": Random, Gradual Sync, Unison, Flash on Beat.

## Strange Attractor

Moves points by repeating a simple formula and draws the density of where they pass (up to 4 million points per frame) as light.

- Type: Clifford, De Jong (2D), Thomas, Aizawa (3D; seen from slightly above while rotating). Changing the type clears what is left of the previous shape.
- Coefficients a to d.
- Morph: the speed and amount at which the coefficients slowly sway.
- Density, Persistence, Size, Rotation speed.
- Coloring: 1 color, Palette (by density), Motion direction (rainbow).
- Points.
- "Look": Silk, Smoke, Tangled Thread, Apple Core.
