# Line, Particle and Light Generators

Values of the Lines, Dots, Tunnel, Phyllotaxis, Light Flow and Audio Scope generators.

## Lines

Evenly spaced lines, like Lines in Arena. Gaps are transparent.

- Count: how many fit the screen height. 0° makes vertical lines.
- Line width: px (size at 1080p; lines thinner than 1 px are drawn fainter).
- Rotation, Speed (lines/s), Blur, Color.
- Wave (amount, density, speed, offset per line): lines undulate like a waveform.
- Tilt back (vertical, horizontal): tilts the plane the lines are drawn on, with perspective (positive vertical tilt makes a floor, with the top going back). Darken distance.
- Wave height (3D): lifts horizontal lines up like terrain (peaks in front hide the lines behind).
  - Peak shape: Wave, Smooth peaks, Sharp peaks.
  - Flat center (like a road) / peaks only in the center.
  - Fill below the peaks with black.
  - With 0° tilt you see a mountain range from the front; add vertical tilt for terrain that stretches into the distance, and Speed makes it flow toward you.

## Dots

The particle version of Lines. Gaps are transparent.

- Count (how many fit the screen height), Particle size (px).
- Shape: Circle, Square, Diamond, Cross.
- Layout: Grid, Staggered, Random.
- Rotation, Speed, Position jitter, Size jitter, Twinkle.
- Wave (Horizontal, From the center, Noise): the particle size ripples (like halftone).
- Tilt back turns them into a floor or wall; Wave height (3D) lifts the particles into a point-cloud terrain.
- Darken distance, Blur, Color.
- Wander (fly freely): each particle slowly flies around on its own path (speed can be set).
- Glow bleed: a soft glow around each particle (brighter where they overlap).
- Wander and Glow bleed work only when flat.
- "Look" buttons: Fireflies, Floating Dust, Grid.

## Tunnel

The inside of a tube that keeps going deeper. The surroundings are transparent.

- Shape: Circle, Square, Hexagon, Triangle.
- Pattern: Rings, Grid, Checker, Light rays (light flies from the depths), Haze.
- Speed (negative goes backward), Rings.
- Line width: at 100% every pattern fills in with no gaps. For Checker, above 50% the gap cells fill in from the middle.
- Rotation speed, Twist (rotates more toward the back), Depth darkness (the depths darken into transparency).
- Bend and Bend speed, Center X/Y, Segments.
- Coloring: 1 color, Palette (color changes with depth), Rainbow.
- Brightness, Glow bleed (glow around the lines).
- "Look" buttons: Warp, Neon, Grid Tube, Swirl, Hazy Cave.
- Overly fine detail in the depths is smoothed out to prevent flicker.

## Phyllotaxis

Particles are born at the center, each turning by the golden angle (137.5°), and spread outward (the same calculation as resolume_generator/phyllotaxis). The surroundings are transparent.

- Spawn rate, Spread speed, Particle size, Growth time, Larger toward the outside, Glow bleed, Rotate, Line length (turns them into sticks), Color variation, Color.
- Particles start being born when the clip is triggered.

## Light Flow

Abstract light. Soft bands of light flow while slowly undulating. Outside the edges they fade away cleanly; inside they spread from white → beige → teal → deep blue. The surroundings are transparent.

- Speed, Softness, Bands, Band width, Undulation, Color bleed (blue and orange at the edges), Rainbow, Grain (film grain), Rotation, Brightness, Hue shift, Ambient glow, Size, Color.
- Spectrum complexity and Spectrum detail: layer the following into the light.
  - Dispersion (offset slightly across 6 wavelengths, bleeding blue outside the edges).
  - Slowly moving hazy colored light (blue, teal, amber, orange).
  - Soft intersecting folds of light (non-repeating shapes, so they don't form stripes).

## Audio Scope

Draws the sound (from "Audio Input" in the top bar) directly: the level per frequency (spectrum) and the waveform (in the "Lines / Patterns" category). The surroundings are transparent.

- The spectrum covers 30 Hz to 16 kHz, split into 128 bands at intervals close to human hearing.
- Shape: Bars, Line (smooth curve), Waveform, Circle (bars), Circle (waveform).
- Bands, Height, Thickness.
- Coloring: 1 color, Rainbow, Palette (by height).
- Mirror vertically, Brightness, Circle size.
- Smoothness: bands rise and fall smoothly, and the waveform moves gradually toward its previous shape.
- With Auto gain, the loudest recent level becomes 100%.

### How it draws

- Each time it draws, it takes the "now" part of the sound. Audio arrives in chunks every 20 to 100 ms, so it keeps advancing with time in between.
- Like an oscilloscope, the waveform starts at a rising zero crossing (so it doesn't jump).
- Points are connected with curves, and lines keep the same width on slopes.
- The circular waveform connects all the way around (including the rainbow colors).
