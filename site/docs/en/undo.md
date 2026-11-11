# Undo

What `⌘Z` (Undo) and `⌘⇧Z` (Redo) restore, and what they don't.

## Commands

- `⌘Z`: Undo.
- `⌘⇧Z`: Redo.
- Also in the Edit menu.

## What can be undone

Everything that is saved: values, effects, adding, deleting, moving, and renaming clips, layers, scenes, cues, pads, and so on. Output Mapping and Lighting (Art-Net / DMX) settings are also restored.

## What can't be undone

- BPM and the deck being viewed (they are values you change during a show). Just changing the deck being viewed is not an undo step.
- BPM changed automatically.
- Autopilot switches (and their fades). When you come back and press `⌘Z`, your own actions are undone.

## How steps are grouped

- A step is recorded once changes settle for 0.6 seconds.
- A value changed by dragging becomes a single step.
- Up to 60 steps.
- While typing text, undo applies to that field.
- Opening or creating a project clears the undo steps.

## Playing clips

If the number of rows, columns, and decks is the same, only the settings are restored without rebuilding the clips, so playing clips do not stop. Undoing the addition or removal of rows or columns rebuilds everything.
