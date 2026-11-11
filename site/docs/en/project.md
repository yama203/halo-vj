# Projects

Saving and opening project files (.halovj), relinking missing videos, collecting media and saving, and autosave.

## Project files

The project file extension is .halovj. Older .vjproj files can also be opened.

Use the “File” menu.

| Item | Key |
|---|---|
| New | `⌘N` |
| Open… | `⌘O` |
| Recent Projects | |
| Save | `⌘S` |
| Save As… | `⇧⌘S` |

In Finder, project files have their own icon, and double-clicking one opens Halo VJ.

### What is and isn't included

- Included: grid, clips (range, speed, effects, motion, mute), layers, composition, BPM, corners.
- Not included: output display, audio output, blackout fade time (per-Mac settings).

Other per-Mac settings not included in the project: audio input, OSC, and MIDI settings, recording settings, and folders added to the “Sources” panel.

### Video locations

Videos in the same folder as the project file (or below it) are also recorded relative to it, so the project still opens if you move the whole folder.

## Missing videos

When a video can't be found, it is placed as a “Not found” clip with its settings kept. When you choose a folder, files with the same name are searched for and relinked.

- “Find Missing Videos…”
- Right-click a clip → “Relink Video File…”

## Collect Media and Save

“Collect Media and Save…” in the File menu creates a folder with the given name at the chosen location, and puts the project and a “素材” (media) folder (copies of the videos and images in use) inside it.

- The whole folder can be taken to another Mac (the project refers to media as “素材/name”).
- The same media file is copied only once.
- Media with the same name from different locations get numbers, like “name 2”.
- If you collect to the same place again, files copied before (with the same size) are reused.
- Missing media are reported.
- Copying runs in the background; when it finishes, the collected project is reopened.

## Autosave

Settings and slot contents are saved automatically to `~/Library/Application Support/Halo VJ/state.json` (the older VJPlayer folder is carried over on first launch).

Autosave continues even when you use project files, so the next launch starts from the previous state (including the project that was open).
