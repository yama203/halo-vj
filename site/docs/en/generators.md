# Generators

How to place, set up and set the quality of "generators", images placed as clips instead of video, plus a list of the types.

![Some of the generators](shots/generators.jpg)

## What a generator is

An image placed as a clip instead of a video. Gaps and the surroundings are transparent. Settings are saved in the project.

## Placing

The generator list is at the very top of the effect list.

- Drag it onto a clip slot.
- Double-click to place it in an empty slot of the selected layer.
- You can also place one from the right-click menu of an empty slot.
- You can also place one from the `⌘E` search window (into an empty slot of the selected layer). → [Adding and Ordering Effects](effects.md)

## Settings

Settings appear in the clip tab. Headers are teal (so you can tell them from the purple of effects). Values can be animated by seconds or BPM. → [Animating Values](animation.md)

Some generators have "Look" buttons that set several values at once.

## Quality

Each generator has a "Quality" setting.

- High: full
- Medium: 3/4
- Low: half

It draws smaller and stretches the result, which reduces GPU load (about 1/4 at half). Lines and fine patterns get slightly blurry.

- Newly placed generators start at "Low" ("High" for Text and Clock). Ones already placed keep their setting.
- Camera, Syphon and NDI inputs do not have it.
- Previews of generators that are not playing are always drawn smaller (up to 540 px high).

## List

The list and the right-click menu of empty slots are grouped by category (Color / Gradient, Lines / Patterns, Shapes / Particles, Text / Logo / Clock, and so on).

| Generator | Described on |
|---|---|
| Solid Color, Gradient (palette; Linear / Circle / Rotate) | This page |
| Lines, Dots, Tunnel, Phyllotaxis, Light Flow, Audio Scope | [Line, Particle and Light Generators](generators-lines.md) |
| Flock (fish, birds), Physarum (slime mold), Particle Life, Firefly Sync, Strange Attractor | [Life and Nature Generators](generators-nature.md) |
| Stripes, Checker / Grid / Dots, Noise (Smooth / Static), Shapes (Circle, Ring, Square, Frame, Triangle; can be tiled) | This page |
| Reaction-Diffusion, Fractal, Growth, Metaballs, Laser Show, Synthwave Terrain, Starfield Warp, Water Ripples, Lightning / Discharge, Logo Particles, Plasma, Aurora, Nebula / Smoke, Truchet Tiles, Hexagon Tiles, Code Rain, Spinning Wireframe, Moiré, Sunburst, Ridge Lines, Bokeh, Spiral, Cells (Voronoi), Lissajous, Fireworks, Fire, Ring Particles | [More Generators](generators-more.md) |
| Text, Clock / Countdown | [Text and Clock Generators](generators-text.md) |
| From Camera, From Syphon, From NDI | [Camera](camera.md), [Syphon](syphon.md), [NDI](ndi.md) |

Phyllotaxis (sunflower) is a port of an FFGL generator originally made for Resolume.
