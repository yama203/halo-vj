# Parameter Panel

The contents of the tabs in the parameter panel at the bottom, and how to change values.

## Tabs

The panel has “Composition”, “Layer” and “Clip” tabs, each with a preview.

| Tab | Contents |
|---|---|
| Composition | Master: Volume, Speed |
| Layer | Mix: Adjustment Layer, blend mode, Volume, Transition Fade |
| Clip | Audio / Playback: Volume, Speed, Play Range (in point, out point), At End (Loop / Ping-pong / Stop at End / Blackout) |

For the play range, speed and jump in the clip tab, see [Play Range, Speed and Jump](clips-range.md).

## Transform

Every tab groups position, scale, rotation and opacity under “Transform”. The current state is drawn to the left of the values.

- Position: a dot on a small screen
- Scale: the screen frame and the clip rectangle
- Rotation: a dial

## Changing values

- Drag to adjust.
- Double-click or right-click to reset to the default.
- The waveform button to the right of a number field lets you drive the value by time, beats, audio, and more. → [Animating Values](animation.md)

For the meaning of number field colors, see [Interface Overview](interface.md).

### px values

px values, such as the spread of bleed or ripples, or dots, are sizes on a 1080p output. In the preview and at other resolutions they scale with the image size, so they look the same everywhere.

### Color swatches

Click the swatch of an effect or generator “Color”, or a palette color, to open a color picker in place (instead of the Mac color panel).

- In the square, horizontal is hue and vertical is saturation (whiter toward the bottom).
- The bar below sets brightness (darker to the left).
- You can also type #RRGGBB.
- Includes buttons for frequently used colors.
- Changes are reflected in the output while dragging.

## Effects section

Added effects are listed in the effects section of the panel. → [Adding and Reordering Effects](effects.md)

## Narrow panel

When the panel is made narrow, it rearranges into a single column, usable without horizontal scrolling.

- Tab names are shortened (Comp / L1 / Clip).
- The in point and out point go on two lines.
- “At End” shows only an icon.
- The jump buttons go on two lines.

## When the panel switches

When the contents switch, for example by selecting a clip or layer, the edge of the panel flashes briefly. → [Interface Overview](interface.md)
