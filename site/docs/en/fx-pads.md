# FX Pads

How to use the “FX Pads” panel, a row of effects that apply only while held.

![The FX Pads panel, with pad 3 held](shots/en/fx-pads.jpg)

## Assigning

Drag an effect from the “Effects” panel onto a pad to assign it (any number per pad). Clicking an empty FX pad opens its settings, where you can also add effects.

## How they apply

- The moment you press a pad, its effects apply at the very end of the output (after the composition's effects), and they disappear when you release it.
- Pads are separate from scenes and the composition, so they work regardless of scene changes.
- Time-based effects (such as strobe) start from the moment you press.

### Attack and Release

Set per pad, from the right-click menu or the settings.

- “Attack”: time from pressing until full strength (Instant to 4 seconds).
- “Release”: time until it fully disappears (Instant to 4 seconds).

The shape at the top right of the pad shows this: a vertical line = instant, a slope = gradual. If you press again while it is fading out, it rises again from the current strength.

### Latch (toggle on each press)

Set “Behavior” in the right-click menu to “Toggle on each press (latch)”. Press once to turn it on, press again to turn it off (releasing does not turn it off).

- Keys, clicks, MIDI and OSC all work the same way.
- Attack and Release still apply.
- A lock mark appears at the bottom right of the pad; it closes while the pad is on.
- The names of latched pads are shown at the bottom left of the output monitor, so you don't forget them.
- Blackout (`Esc`), Stop All (`⇧Esc`) and recalling a scene do not turn them off.
- “Turn Off All Latches” is in the pad's right-click menu (and in the right-click menu of the “FX” heading).

## Pressing with the keyboard

- By default, `1`–`9` and `0` in pad order.
- Effects apply only while held, and any number can be pressed at once.
- The key is shown at the top left of the pad.
- “Key” in the right-click menu reassigns it to `1`–`0` or `Q`–`M`, or None.

Pads can also be assigned to MIDI buttons. → [MIDI controllers and keys](midi.md)

## Reordering and editing

- `⌘`-drag (or “Move Left” / “Move Right” in the right-click menu) to reorder.
- Right-click for settings (values, order), name, clear, delete.
- “＋” adds a pad (up to 16).

Pads are saved in the project.
