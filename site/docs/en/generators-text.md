# Text and Clock Generators

The Text and Clock / Countdown generators.

## Text

Shows the text typed in the text field (line breaks separate lines).

### Motion

- Still
- Scroll horizontally
- Scroll vertically
- Tile (each line scrolls in the opposite direction)
- One character at a time (typewriter)
- Bounce on beat

### Font

10 fonts: Gothic Black / Thin, Mincho, Rounded Gothic, SF Black, Condensed, Futura, Didot, Monospaced, Script. Japanese is displayed even with fonts that have no Japanese characters.

### Line Switching

Moves to the next line every 1, 2, 4 or 8 beats (empty lines are skipped).

### Other values

- Size, Speed, Letter spacing.
- Horizontal / Vertical spacing: the gap between characters when scrolling or tiling. The unit is the height of one line; negative values make them overlap. Can be animated.
- Wave.
- Glitch (band shift + color shift).
- Outline only.
- Fill: color / palette gradient.

The clip's name is the first line. Text is redrawn only when it changes, and motion runs on the GPU, so it is light.

## Clock / Countdown

### Mode

| Mode | Description |
|---|---|
| Current time | A clock |
| Countdown | Counts down to the target hour, minute and second. If that time has already passed, counts down to the same time the next day. For 1 hour after reaching 0, shows the finished display |
| Timer | A length in minutes and seconds, starting when the clip is triggered |
| Stopwatch | |

### Display

- Auto: h:mm:ss for an hour or more, otherwise m:ss. The last 10 seconds of a countdown or timer show only the number.
- h:mm:ss, h:mm, m:ss, seconds.
- Sub-seconds (1/10, 1/100).

### Other

- Text shown at 0: if empty, it stays at 0. If it is wider than the screen, it is scaled down.
- In the last 10 seconds the number bounces each time it changes (can be turned off).
- Digits are drawn with equal widths, so they don't shift sideways.
- Font, motion, wave, glitch, colors and so on are the same as Text.
