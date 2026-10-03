# world_label

Floating world text for Godot 4 that stays legible. A `WorldLabel` is a `Node3D` that names a
point in the world. It is not drawn in 3D. A per-viewport overlay draws it as crisp 2D text over the
3D image, at its true world size up close and never below a legible floor far away. The overlay
fades it with the scene's own fog and with distance. With the optional depth copy, it is also hidden
per pixel wherever the 3D pass drew something in front of it.

It exists for a low-resolution 3D image (a 360-line, PS1-style buffer upscaled to the window), where
a `Label3D` is rasterised into a handful of buffer pixels and stops being readable. The overlay draws
at the window's own resolution instead. It works as well at full resolution, where it buys the fog
fade, the size floor and text that is never aliased by the 3D pass.

## §1 — Requirements

- Godot 4.4 or later. Tested on 4.4.1, 4.6 and 4.7 stable and on a 4.8 development build.
- The depth mask needs a `RenderingDevice`: Forward+ or Mobile. Under Compatibility, or headless,
  labels draw unmasked and nothing errors.
- Nothing to import by hand. The depth copy's compute shader is embedded in
  `scene_depth_effect.gd` and compiled at run time, so a fresh project, a headless import and an
  export all work without a `.glsl` import step.

## §2 — Quick start

1. Copy `addons/world_label/` into your project's `addons/` folder.
2. Enable **World Label** under Project Settings › Plugins. The plugin only lists the overlay's
   settings in Project Settings (§6); labels draw without it.
3. Add a `WorldLabel` node where the text belongs. Set `text`, `font_size`, `color`, `outline_color`
   and `range_m`. In the editor it shows as a billboard `Label3D` preview, which is never saved. The
   overlay is made the first time a label enters a viewport; no scene has to carry it.
4. For the depth mask, add a `SceneDepthEffect` to the compositor your camera renders with, on the
   `Camera3D` or the `WorldEnvironment`. Without one, labels draw over everything, and on a
   renderer that could have drawn one the overlay reports it once per compositor.

`example/world_label_example.tscn` shows all of it: a fogged scene, a pillar with a name, a label
hidden behind the pillar, and a near and a far label.

A subclass of `WorldLabel` that changes `text` every tick is a live readout; nothing more is needed.

## §3 — The pieces

| File | Class | Role |
|---|---|---|
| `world_label.gd` | `WorldLabel` (`Node3D`) | The anchor: text, size, colours, range. Joins its viewport's layer. |
| `world_label_layer.gd` | `WorldLabelLayer` (`CanvasLayer`) | One per viewport. Draws one 2D `Label` per anchor each frame. |
| `world_label_system.gd` | `WorldLabelSystem` | Static arithmetic: fog amount, alpha, drawn em, pixel-grid snap. |
| `world_label.gdshader` | — | Canvas shader that applies the depth mask. |
| `scene_depth_effect.gd` | `SceneDepthEffect` (`CompositorEffect`) | Copies the 3D pass's depth as linear metres. |
| `world_label_plugin.gd` | — | Editor plugin: lists the settings in Project Settings. |
| `example/` | — | A scene showing every feature. |
| `checks/world_label_check.gd` | — | Headless check of what the overlay draws (§8). |

`WorldLabelLayer.drawn(anchor)` returns the 2D `Label` drawing an anchor, for tests that measure
what is drawn.

## §4 — How a label is drawn

### §4.1 — An overlay, not a `Label3D`

A `Label3D` is drawn inside the 3D image, so at a low 3D resolution its letters are a few buffer
pixels high and stop being readable at a few metres. The overlay draws a 2D `Label` per anchor at
the window's resolution and places it where the anchor projects. Size, fade, sort and occlusion are
then the overlay's job, and the rest of this section is how each is done. The arithmetic is
static and lives in `WorldLabelSystem`, so it can be tested without a scene.

### §4.2 — Size

- A label's em is `font_size × 0.005 m`. 0.005 is `Label3D`'s default `pixel_size`, so a label moved
  over from `Label3D` keeps the world size it was authored at.
- The em in canvas units is `em_m · |P.y.y| · visible_height / (2 · depth)`, the projected world size.
- The floor is `world_label/min_em_px`, 8 pixels of the 3D buffer by default, converted to canvas
  units through the viewport's 3D scale and its final transform. A far label is drawn at the floor,
  not smaller.
- An anchor at a view depth at or below the camera's `near` draws nothing. A projection with
  negative w would otherwise put a mirrored copy on screen.
- Placement uses the camera's interpolated transform, so labels do not jitter against a
  physics-interpolated image.

### §4.3 — Shaped once, sized by scale

Changing a `Label`'s font size reshapes its text and re-rasterises glyphs. Doing that every frame
while the view turns costs frames: the first version of this overlay stuttered on every turn.

- Every label is shaped once at `SHAPED_EM` (48 px) and drawn at `scale = em / SHAPED_EM`. Moving
  the camera writes a transform and nothing else.
- So that scaled glyphs stay sharp, the overlay uses one shared runtime copy of the label font with
  `multichannel_signed_distance_field` on, `msdf_size` 48 and `msdf_pixel_range` 16. It is a copy,
  so the project theme's own use of the same file keeps its rasterised glyphs.
- The label font is `world_label/font` if set, else the project theme's font
  (`gui/theme/custom_font`), else the engine's fallback font. Only a `FontFile` has font data to
  copy; a `SystemFont` or `FontVariation` falls back to the engine font.
- The outline is `OUTLINE_SHARE` (0.12) of the em, so it stays in proportion at every size. The
  canvas renderer divides an MSDF outline size by 4, so the size written is
  `roundi(48 × 0.12) × 4 = 24`. The pixel range of 16 holds an outline of up to `16 / 2 − 1 = 7`,
  above the 6 drawn.

### §4.4 — Fade

- Alpha is multiplied by `1 − fog`, where fog is the world environment's own fog amount at the
  label's distance and height: depth or exponential fog, plus height fog, computed as the forward
  shader computes it. A label in fog fades as the scene behind it does.
- Over the last `FADE_SHARE` (0.2) of `range_m` the alpha falls linearly to 0. The default range is
  20 m.

### §4.5 — The pixel grid

The label's top-left corner is snapped to whole multiples of the 3D pixel ratio in window pixels,
so its position steps with the 3D image beneath it rather than sliding between buffer pixels.

### §4.6 — Canvas layer

The overlay draws on canvas layer `world_label/canvas_layer`, −1 by default: above the 3D image,
under layer 0 and up. A HUD or a crosshair drawn on layer 0 or higher therefore draws over a label.
Labels are sorted far to near by `z_index = −depth × 16`, so nearer labels draw over farther ones.

### §4.7 — Joining the layer

`WorldLabel` joins and leaves its layer in `_notification`, not in `_enter_tree` and `_exit_tree`.
A subclass that defines its own `_exit_tree` replaces the base class's. When that happened, a freed
label stayed in the layer and the next frame's draw loop stopped at it. A layer that is freed
(by whoever freed its viewport) tells its anchors to rejoin; `WorldLabel.rejoin()` does the same by
hand.

## §5 — The depth mask

### §5.1 — The mask

- The shader zeroes alpha where the copied depth is nearer than the label's own view depth by more
  than `world_label/depth_bias_m` (0.1 m by default). The bias keeps a label anchored just inside
  the thing it names, such as a readout over a head or a name on a pillar's face, from being hidden
  by that surface.
- Each label writes its depth through an `instance uniform`; all labels share one material.
- The mask applies only in the viewport whose pass is copied (§5.2).
- With no effect, with a copy more than `STALE_FRAMES` (2) process frames old, or in another
  viewport, labels draw unmasked. A copy that stopped updating, for example after a scene without
  the compositor loads, would otherwise mask with an old scene.
- The overlay looks for the effect on the camera's compositor, then on the `WorldEnvironment` whose
  environment is the world's. `World3D` has no `compositor` property, so the node is found once per
  environment and its compositor is read every frame.

### §5.2 — The depth copy

- Linear depth is `proj.w.z / (d + proj.z.z)` from `RenderSceneDataRD.get_cam_projection()`. That
  projection already carries the reversed-Z correction. A texel where nothing was drawn (`d ≤ 0`)
  stores 1e6 m.
- One viewport's pass is copied: the root viewport's by default. The callback compares
  `RenderSceneBuffersRD.get_render_target()` to that viewport's render target. A `SubViewport`
  (a weapon view, a mirror, a portal) shares the compositor and would otherwise overwrite the copy.
- A game drawn inside a `SubViewport` calls `effect.watch(sub_viewport)` once, on the main thread.
  The copy and the mask then follow that viewport instead of the root.
- The copy is refit in the callback when the internal size differs from the copy's, so it follows
  every change to the 3D buffer's size. The new texture is created and handed to the `Texture2DRD`
  before the old one is freed, so the canvas never samples a freed texture.
- The compute shader is GLSL source held in `SceneDepthEffect.SHADER_SOURCE` and compiled with
  `RenderingDevice.shader_compile_spirv_from_source`. A `.glsl` file would need the editor's import,
  which a headless editor refuses, and a failed import there broke every class that loaded it.
- **Trap:** a saved compositor stores `effect_callback_type`, and the stored value overrides the
  one set in `_init`. The effect must be stored as `1` (`POST_OPAQUE`). Stored as anything after
  the opaque pass, the callback returns on every pass and nothing is copied.

## §6 — Project settings

Read once per layer, so a change applies to layers made after it. Enable the plugin to edit them in
Project Settings; without it, set them in `project.godot` or leave the defaults.

| Setting | Default | Meaning |
|---|---|---|
| `world_label/font` | `""` | Font file labels are drawn in. Empty uses the theme font, then the engine font (§4.3). |
| `world_label/min_em_px` | `8.0` | Smallest em drawn, in pixels of the 3D buffer (§4.2). |
| `world_label/canvas_layer` | `-1` | Canvas layer the overlay draws on (§4.6). |
| `world_label/depth_bias_m` | `0.1` | Metres the scene may stand nearer than an anchor without hiding it (§5.1). |

## §7 — Limits

- Glass, flames and particles write no depth, so labels show through them.
- Labels do not hide each other; they only sort.
- The depth mask covers one viewport at a time (§5.2).
- The multi-threaded render model is untested. `copied_frame` is written on the render thread.

## §8 — Checks

`checks/world_label_check.gd` measures what the overlay draws, read off the drawn 2D labels:
size against the floor and the world size, nothing behind the camera, fog and range fade, the pixel
grid, no reshaping on a move, colours, and leaving cleanly. It runs headless in any project that
holds the addon and prints `WORLD LABEL PASS` or one line per failed bar:

```
godot --headless --fixed-fps 60 --path . --script res://addons/world_label/checks/world_label_check.gd
```

`--fixed-fps 60` is needed: without it the frame delta varies and the size rows can read a frame
early. The depth mask needs a `RenderingDevice` and is not measured here.

A project adds rows of its own by extending the script and overriding `_extra_rows()`, an
awaitable hook run after the built-in rows. `_leave_one(label)` checks that any `WorldLabel`
subclass stops being drawn when it leaves the tree.

## §9 — License

MIT. See `LICENSE`.
