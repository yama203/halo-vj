# Scenes

How to use the “Scenes” panel to save your favorite combinations and switch between them.

![The Scenes panel](shots/en/scenes.jpg)

## Saving

“Save Current State as Scene” saves the following, together with a thumbnail of the output:

- The clips that are playing (the column for each layer).
- Layer and composition settings (opacity, blend mode, position, effects, mute, and so on).
- Settings of the playing clips (clip effects, position, size, rotation, opacity, and how values move).

“Empty Scene” adds a scene that plays nothing, so you can edit it right away.

## Recalling

Click a thumbnail image to switch to that scene.

- Clips also take the scene's values (smoothly during a fade; clip values are overwritten as is).
- Older scenes that have no clip record do not change the clips.
- A clip that is already playing is not restarted from the beginning.

### Fade

The fade time (Instant to 8 seconds) is set per scene.

- Clips crossfade.
- Opacity, position, and effect values move smoothly.
- Things that cannot be blended (blend mode, effects of a different kind) switch partway through.

## Editing

Click the name strip below a scene to edit that scene while the output stays as is (an orange strip appears above the grid).

- While editing, the grid, the layer column, and the panels below show the contents of that scene.
- Clicking a clip makes it the clip the scene plays (clips currently being output are marked “On Air”).
- Clicking an empty slot sets that layer of the scene to “None”.
- Clicking a column number makes the scene play the clips of that column.
- Opacity, effects, and so on can be changed the same way, and the preview shows the scene's image.
- Changes go into the scene immediately, and the thumbnail is retaken.
- A clip newly chosen while editing records its values at the time you chose it. “Record Clip Settings” on the strip records it again with the current values.
- The settings of a clip itself are shared by all scenes.
- Click “Done Editing”, or click the name strip again, to go back.

## Right-click

Overwrite, name, fade time, delete, deck. A scene remembers the deck it was saved with, and recalling it shows that deck. → [Decks and grid display](decks.md)

## Display size

“L / M / S / Min” at the top right changes the size of the scenes (how many per row).

The button to its right switches between thumbnails and a list. The list shows one scene per row, with the number, a small thumbnail, name, deck and fade time easy to read.

- Click a row to switch to that scene.
- The knob at the right end edits the scene while the output stays as it is.
- Drag a row onto another row to reorder scenes (you can also drag it into the cue list to add it).

## Saving

Scenes are saved in the project. The grid contents are shared. A scene stores “which column to play”, so if you move clips, whatever clip is in that place plays.

To add a scene to the cues, drag the scene (the image) onto the list in the “Cues” panel. → [Cues](cues.md)
