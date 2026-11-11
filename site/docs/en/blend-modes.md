# Blend Modes

The blend modes used to composite a layer over the layers below. Choose the blend mode with the button on the lower line of the layer column, or in the layer tab.

## Blend modes without values

Difference, Overlay, Soft Light, Color Dodge, Hue Only and Luminosity read the image below and mix with it, and have no values. Opacity sets how strongly they apply.

| Blend mode | Look |
|---|---|
| Difference | Overlapping areas look inverted (identical colors become black) |
| Overlay, Soft Light | Brights get brighter, darks get darker |
| Color Dodge | Bright areas glow as if burned |
| Hue Only | The top colors at the brightness of the image below |
| Luminosity | The top brightness with the colors of the image below |

## Mask (white shows / white hides)

Cuts out all layers below using this layer's brightness. The layer itself is not visible. Useful with the “Solid Color” and “Shapes” generators.

## Overdrive Add

A special blend that adds to the layers below and turns the part exceeding 100% (the overflow) into the following:

- Bleed (halation)
- Hue shift
- Ripple (concentric waves spread outward from the overflowing areas; strength, density, speed, spread)
- Highlight protection

The values appear in the layer tab (can be driven by time or BPM). It works by reading the image below and mixing in a shader, so more special blends can be added the same way.

## Interacting blends

The “Interacting blends” in the layer's blend mode use this layer's image to change the image below itself. The values appear in the layer tab (can be driven by time or BPM; changing the blend mode resets them to that type's initial values).

### Refract

Uses this layer's brightness as height and bends the image below along the slope. Clear glass text or shapes flow over the video.

Values: Bend strength, Smoothness, Color fringing, Edge glow, Show the top image too.

### Light

Uses this layer as light to illuminate the image below, and darkens the rest. Works well with Dots, Firefly Sync, Physarum (slime mold) and similar.

Values: Darkness of unlit areas, Light spread, Light strength, Tint with the light's color, Show the light itself.

### Flow

Pushes and stirs the image below like paint with this layer, then gradually returns to the original image.

- Push by: Moving areas (for video with motion) / Around bright areas (swirls around large bright shapes such as text).
- Values: Stir strength, Return speed, Swirl, Viscosity, Show the top image too.
- Thin, small shapes push weakly.

### Interfere

Turns the brightness of both images into waves and overlaps them, creating moving stripes (moiré) where they differ.

Values: Stripe density, Flow speed, Stripe strength, Sharpness, color (Color below / Color above / Rainbow).

### Borrow Color

Paints this layer's colors onto the brightness (shapes) of the image below.

- Borrow from: Color at the same spot / Top image as palette (Palette row).
- Values: Brightness contrast, Shift by brightness, Keep the original color.

### Dissolve

The image below dissolves into this layer starting from its dark areas (or bright areas, noise, or the top brightness), with a glowing edge.

Values: Dissolve amount, Dissolve from, Edge softness, Edge glow, Edge hue, Mix in noise.
