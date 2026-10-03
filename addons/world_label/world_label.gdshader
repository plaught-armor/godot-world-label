shader_type canvas_item;

// Hides a floating label's pixels wherever the 3D pass drew something nearer than the label's
// anchor. Draws every pixel while `masked` is off, which is the fallback with no depth texture.
// WHY: addons/world_label/README.md §5.1

// Linear view depth (m) per pixel of the 3D buffer, written by SceneDepthEffect.
uniform sampler2D scene_depth : filter_nearest;
uniform bool masked = false;
// Metres the scene may stand nearer than the anchor without hiding the label.
uniform float depth_bias = 0.1;
// View depth (m) of this label's anchor, written every frame by WorldLabelLayer.
instance uniform float label_depth = 0.0;

void fragment() {
	if (masked) {
		COLOR.a *= step(label_depth, texture(scene_depth, SCREEN_UV).r + depth_bias);
	}
}
