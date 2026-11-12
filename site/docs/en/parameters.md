# Parameter Panel

The contents of the tabs in the parameter panel at the bottom, and how to change values.

![The preview and the parameter panel](shots/en/parameters.jpg)

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

### Dice (randomize values)

Click the dice button in the header of an effect or generator to randomize its values. One ⌘Z undoes it. For a clip's generator (shown without a header), Reset, Dice, and Presets sit to the right of the description.

- Hold ⌥ while clicking to change values “just a little” (within ±15% of the range around the current value). Choices are left as they are.
- Not changed: on/off values, values with an animation, opacity, quality, text and font, position and size (such as mask position or center), and input selection. Values that affect performance (such as particle counts) or that would make the picture vanish for a while (such as the Reaction-Diffusion pattern) are also left alone or only changed within a moderate range.
- Colors change only in hue (white, black, and gray stay as they are).
- Not available for Camera, Syphon, NDI, Text, and Clock.

#### Rolling automatically with the beat or the audio

Click the ▾ to the right of the dice button to open the dice panel (the same purple frame as the value animation panel).

- **Roll Now**: rolls once right away.
- **Roll automatically [Off | Beat | Audio]**: the selected one is filled in blue. While rolling automatically, the dice in the header turns orange, and a mark appears next to the name even when the card is closed.
  - **Beat**: choose the interval with the 1/4 to 16 beat buttons. The dots below show the progress until the next roll (it rolls on the beat after all dots light up).
  - **Audio**: rolls on attacks such as kicks. The graph shows the attack strength over the last 2.5 seconds; a roll happens the moment it crosses the dashed orange line (the threshold), marked with a dot. Drag the line up or down, or use the Threshold field. Lower values roll on quieter hits. Rolls are at least 0.12 seconds apart. Nothing is rolled when “Audio Input” at the top is off (the panel says so; → [Audio Input](audio-input.md)).
- **Change [Big | Just a Little]**: Just a Little works like ⌥, for both manual and automatic rolls. When rolling on the beat, starting with Just a Little is recommended (big jumps in shape and color every time can feel restless).
- **Glide**: instead of switching at once, the values move smoothly over the chosen number of beats (1/4 to 2). Choices and on/off values do not glide; they switch halfway.
- The dot and text at the bottom show the current state: orange while rolling automatically (briefly brighter at each roll), an empty circle when off.
- Only what is on screen is rolled (playing clips, layers, the composition, and held pads). Clips that are not playing do not change.
- Automatic rolls are not added to ⌘Z (changing the settings and manual rolls can each be undone).
- The automatic settings are saved in presets too.

### Presets

Use the bookmark button in the header to save the current set of values under a name and recall it later.

- Choose “Save Current Values…” and enter a name. The same name overwrites; an empty name gets a number, like “Preset 1”.
- Choose a preset from the list to load its values (⌘Z undoes it). It loads values, color, palette, and animation settings. On/off, opacity, quality, and text stay as they are.
- Presets are kept per effect type and are shared by all projects (`~/Library/Application Support/Halo VJ/effect-presets.json`).
- Remove one with “Delete Preset”.

## Narrow panel

When the panel is made narrow, it rearranges into a single column, usable without horizontal scrolling.

- Tab names are shortened (Comp / L1 / Clip).
- The in point and out point go on two lines.
- “At End” shows only an icon.
- The jump buttons go on two lines.

## When the panel switches

When the contents switch, for example by selecting a clip or layer, the edge of the panel flashes briefly. → [Interface Overview](interface.md)
