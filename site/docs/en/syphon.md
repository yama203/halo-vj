# Syphon

How to exchange video with other apps on the same Mac using Syphon under “Connect” at the top.

## Sending

Publishes the composition over Syphon.

- What is sent is the image before the corner adjustment, including pad effects.
- The name can be changed. The default is “Halo VJ”.
- The size is the same as the output and composition image (1920×1080 or the chosen resolution if there is no image).
- Whether it is being received is shown.

In TouchDesigner, receive it with the Syphon Spout In TOP.

## Receiving

Place the generator “From Syphon” (category “From Other Apps / Cameras”) in a slot, then choose a published video under “Video” in the clip tab.

- It is remembered by app name and server name. If the source disappears, it continues when it is published again.
- Scaling: Fit, Fill, Stretch.
- Density.
- Transparency is kept.
- Halo VJ's own output is not shown in the list.
