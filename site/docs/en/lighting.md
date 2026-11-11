# Lighting (Art-Net / DMX)

How to light fixtures and LED strips with the colors of the composition, using “Lighting (Art-Net / DMX)…” in the Output menu.

## Sending

- Sends Art-Net (ArtDmx, UDP 6454) 40 times per second.
- The destination is a broadcast to 255.255.255.255 by default. A node's IP can also be specified.
- The composition is reduced to 128×72 to sample colors.

## Fixtures

Set the following for each fixture:

- Type: RGB (1 point), RGBW (1 point; the white part goes to W), Brightness only (1 point), LED strip (line, RGB, number of pixels).
- Universe.
- Start channel.
- Sample area: drag the point or the ends of the line on the composition.

Channels beyond 512 are sent to the next universe.

## Global settings

Overall brightness, gamma.

Saved in the project, and undo works for it.
