# NDI

How to exchange video with other Macs and PCs on the network using NDI under “Connect” at the top.

## Sending

Sends the composition (the same image as Syphon) over NDI.

- The name can be changed. The default is “Halo VJ”.
- It can be received by another Mac or PC on the same network (TouchDesigner's NDI In TOP, Resolume, OBS, etc.).
- It is sent as opaque (BGRX) at 60 frames per second; if the previous frame has not finished sending, the frame is skipped.
- The number of receivers is shown.

## Receiving

Place the generator “From NDI” (category “From Other Apps / Cameras”) in a slot, then choose a detected sender under “Video” in the clip tab.

- Senders are searched for again every 2 seconds. The sender is remembered by name.
- Scaling, Density.
- Transparency is kept (when BGRA).
- Halo VJ's own output is not shown in the list.

## The NDI library

The NDI library (libndi) is loaded while the app is running. Search order:

1. The one bundled with the app (`Contents/Frameworks`).
2. The one included in the NDI Runtime, NDI SDK, Resolume, etc.

- Which NDI is in use is shown in the NDI section of “Connect”.
- If none is found, that is shown (install NDI Tools from ndi.video).

### Bundling when building the app

If the NDI SDK for Apple is present (downloaded from ndi.video with its license agreed to; at `/Library/NDI SDK for Apple`, or a location set with `NDI_SDK_DIR`), `tools/make_app.sh` bundles libndi and the license documents (`Contents/Resources/NDI`). If not, nothing is bundled (libndi from other apps is not copied).

## Trademark

Where NDI is used and in the About window, “NDI® is a registered trademark of Vizrt NDI AB” is shown with a link to ndi.video.
