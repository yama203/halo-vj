# Output, Resolution, and Corners

The output display, output resolution and frame rate, audio output, corner adjustment, and the test pattern.

![The output monitor](shots/en/monitor.jpg)

## Output display

Choose the output display (or a test window) under “Output” at the top.

## Audio output

Choose the audio output device (headphones, etc.) under “Audio” at the top.

## Resolution and fps

Set these under “Resolution / fps” at the top (also in the settings window, `⌘,`). Both are saved in the project.

### Output resolution

- Match Output (height 1080, with the output display's aspect ratio).
- HD / Full HD / WUXGA / 2.5K / 4K / Vertical (phone) / Square / XGA.
- Custom (width × height).

The composition is rendered at the chosen size, then scaled up or down to the output display's size. The preview and output monitor also use the composition's aspect ratio.

How to fit when the aspect ratio differs from the output display:

- Fit (letterbox)
- Fill (crop)
- Stretch

### Frame rate

- Match Display.
- 24 / 25 / 30 / 50 / 60 fps. Frames are drawn at the chosen rate, and the previous image is held in between. The previews in the control window do the same.

“Render” at the bottom right of the screen shows the actual rate.

## Corners

With “Corners”, drag the yellow points on the preview to adjust the corner pin.

For finer adjustment, or to send different parts to multiple outputs, use [Output Mapping](mapping.md).

## Test pattern

“Test” outputs a test pattern (for aligning the corners).

## Output monitor

- The eye button above the output monitor mutes the whole output (it disappears instantly, without a fade).
- When the output switches, the edge of the output monitor flashes briefly. → [The interface](interface.md)
