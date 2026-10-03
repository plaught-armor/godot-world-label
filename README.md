# godot-world-label

A Godot 4 addon for floating world text that stays legible: names and readouts drawn as crisp 2D
text over the 3D image, at true world size up close and never below a legible floor far away,
faded by the scene's fog and by distance, and hidden per pixel behind whatever the 3D pass drew in
front of them. Built for low-resolution, PS1-style 3D buffers, where a `Label3D` stops being
readable. GDScript only.

The addon lives in [`addons/world_label/`](addons/world_label/); its
[README](addons/world_label/README.md) is the documentation. This repository is a minimal host
project around it, so a clone runs the example and the checks directly:

```sh
godot --headless --import --path .
godot --path .
godot --headless --fixed-fps 60 --path . --script res://addons/world_label/checks/world_label_check.gd
```

To use it in your own project, copy `addons/world_label/` in and enable **World Label** under
Project Settings › Plugins.

MIT licence; see [LICENSE](LICENSE).
