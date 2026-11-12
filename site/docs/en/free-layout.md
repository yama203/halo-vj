# Free Layout (Experimental)

“Free Layout” lets you place panels freely in areas. This feature is still experimental.

## Turning it on

Turn it on with “Layout” → “Free Layout (Experimental)” in the menu. Turning it off returns to the original fixed arrangement.

## What can be placed

The screen is divided into areas, and any of the following can be placed in any area:

- Grid
- Output Monitor
- FX Pads
- Preview
- Parameters (the preview and the settings are separate panels, and each fills its area)
- Live
- Scenes
- Effects
- Generators
- Sources

## Moving

Grab a panel's tab and drag it to where you want it.

- While you move it sideways within the tab bar, it reorders the tabs. The other tabs slide aside to make room.
- Once you drag it out of the tab bar, it moves the panel. Exactly one drop location lights up in blue, and the panel's name follows the pointer.
- Grabbing the empty part of a tab bar (to the right of the tabs) moves the panel currently shown.
- Press Esc while dragging to cancel without changing anything.

| Drop location | Result |
|---|---|
| Another area's tab bar | Inserted as a tab at that position (where the blue vertical line is) |
| Center of an area | Grouped as the last tab |
| Edge of an area (roughly the outer quarter) | Splits the area and places it on that side |
| On the divider between areas | Inserts a column (or row) at that divider (spanning the full length of the divider) |
| Just inside any of the four screen edges | Places it along that whole edge (e.g. the grid full height on the left edge, the FX pads full width at the bottom) |
| Outside the main window | Opens it in a separate window (only for panels that can have one) |

Places where dropping would not change anything (such as the center of an area that only holds this panel) do not light up, and dropping there leaves the layout as it is.

- Right-click a tab for Left / Right, Open in Separate Window, and Close.
- When an area is too narrow for all tab names, unselected tabs show only their icon (hover to see the name).
- Double-click a tab (or the empty part of a tab bar) to temporarily maximize that area. Double-click again, or use the restore button at the top right, to go back (this is not saved).
- Drag the dividers between areas to resize.
- Areas that become empty are closed.
- Separate windows and saved layouts work as before.

For closing panels, see [Workspaces and panels](layout.md).
