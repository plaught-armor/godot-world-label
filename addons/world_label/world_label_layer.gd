class_name WorldLabelLayer
extends CanvasLayer

## Draws every WorldLabel in one viewport, once per frame from the viewport's current camera: one
## 2D Label each, sized, placed on the 3D pixel grid, faded, sorted far to near and masked by the
## scene depth. One per viewport, made by the first label to enter it and added to the viewport at
## the end of that frame. Draws unmasked, loudly, where a RenderingDevice exists but the camera's
## compositor holds no SceneDepthEffect.
## WHY: addons/world_label/README.md §4.1

## Project setting: path of the font labels are drawn in. Empty falls back to
## `gui/theme/custom_font`, then to the engine's font.
## WHY: addons/world_label/README.md §4.3
const SETTING_FONT: String = "world_label/font"
## Project setting: the smallest em a label is drawn at, in pixels of the 3D buffer.
## WHY: addons/world_label/README.md §4.2
const SETTING_MIN_EM_PX: String = "world_label/min_em_px"
## Project setting: the canvas layer labels draw on. The default, -1, is above the 3D image and
## under layer 0 and up.
## WHY: addons/world_label/README.md §4.6
const SETTING_CANVAS_LAYER: String = "world_label/canvas_layer"
## Project setting: metres the scene may stand nearer than a label's anchor without hiding it.
## WHY: addons/world_label/README.md §5.1
const SETTING_DEPTH_BIAS_M: String = "world_label/depth_bias_m"
## Per setting: [default, type, hint, hint string]. Read by `setting`; registered in Project Settings
## by the editor plugin. Read once per layer, so a change applies to layers made after it.
const SETTINGS: Dictionary = {
	SETTING_FONT: ["", TYPE_STRING, PROPERTY_HINT_FILE, "*.ttf,*.otf,*.woff,*.woff2,*.pfb,*.pfm"],
	SETTING_MIN_EM_PX: [8.0, TYPE_FLOAT, PROPERTY_HINT_RANGE, "1,64,0.5"],
	SETTING_CANVAS_LAYER: [-1, TYPE_INT, PROPERTY_HINT_RANGE, "-128,128,1"],
	SETTING_DEPTH_BIAS_M: [0.1, TYPE_FLOAT, PROPERTY_HINT_RANGE, "0,2,0.01,suffix:m"],
}
## Project setting the font falls back to when SETTING_FONT is empty.
const THEME_FONT_SETTING: String = "gui/theme/custom_font"
const LAYER_NAME: StringName = &"WorldLabelLayer"
const SHADER: Shader = preload("world_label.gdshader")
## Share of a label's range, at its far end, over which it fades out.
const FADE_SHARE: float = 0.2
## Outline width as a share of the em.
## WHY: addons/world_label/README.md §4.3
const OUTLINE_SHARE: float = 0.12
## Font size (px) every label is shaped at, once, and the MSDF atlas's glyph size. The drawn em comes
## from the label's scale, so moving the camera never reshapes text.
## WHY: addons/world_label/README.md §4.3
const SHAPED_EM: int = 48
## Factor on an MSDF outline size: the canvas renderer divides it by 4.
## WHY: addons/world_label/README.md §4.3
const MSDF_OUTLINE_FACTOR: int = 4
## Distance-field range (px) of the label font's atlas, at least 2x the outline it must hold.
## WHY: addons/world_label/README.md §4.3
const MSDF_PIXEL_RANGE: int = 16
## z_index steps per metre of view depth, for the far-to-near sort.
const Z_PER_M: float = 16.0
## Most process frames a depth copy may lag the current one and still mask.
const STALE_FRAMES: int = 2

# One layer per viewport, by viewport instance id. Entries leave when their layer is freed.
static var _layers: Dictionary[int, WorldLabelLayer] = { }
# The label font as a multi-channel distance field, shared by every layer. A copy, so the project
# theme's use of the same file keeps its rasterised glyphs.
static var _font: FontFile = _distance_field_font()

# Parallel: the label at each index draws the anchor at the same index.
var _anchors: Array[WorldLabel] = []
var _labels: Array[Label] = []
var _material: ShaderMaterial = ShaderMaterial.new()
var _masked: bool = false
# SETTING_MIN_EM_PX, read once.
var _min_em_px: float = 8.0
# Instance id of the compositor last looked at, so a missing effect is reported once per compositor.
var _compositor_id: int = -1
# The world environment last matched to a WorldEnvironment, by instance id, and that node. Its
# compositor is read each frame, so a compositor swapped on the node is followed.
var _environment_id: int = -1
var _world_environment: WorldEnvironment

# This frame's camera, written at the top of _process and read by _place.
var _view: Transform3D
var _projection: Projection
var _near: float = 0.0
var _visible: Vector2 = Vector2.ZERO
var _to_window: Transform2D
var _ratio: int = 1
var _floor: float = 0.0
var _environment: Environment


func _init() -> void:
	layer = setting(SETTING_CANVAS_LAYER)
	_min_em_px = setting(SETTING_MIN_EM_PX)
	_material.shader = SHADER
	_material.set_shader_parameter(&"depth_bias", setting(SETTING_DEPTH_BIAS_M))


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE:
		return
	for id: int in _layers.keys():
		if _layers[id] == self:
			_layers.erase(id)
	# The drawn labels were children and go with this layer; their anchors find a new one.
	for anchor: WorldLabel in _anchors:
		if is_instance_valid(anchor):
			anchor.rejoin.call_deferred()


## The layer drawing `anchor`'s viewport, made if there is none, with `anchor` added to it.
## `anchor` must be inside the tree.
static func join(anchor: WorldLabel) -> WorldLabelLayer:
	var viewport: Viewport = anchor.get_viewport()
	var id: int = viewport.get_instance_id()
	var found: WorldLabelLayer = _layers.get(id)
	if found == null:
		found = WorldLabelLayer.new()
		found.name = LAYER_NAME
		_layers[id] = found
		viewport.add_child.call_deferred(found)
	found.adopt(anchor)
	return found


## `name`'s value in Project Settings, or its SETTINGS default when the project does not set it.
static func setting(name: String) -> Variant:
	return ProjectSettings.get_setting(name, SETTINGS[name][0])


# A new FontFile over the data of the first FontFile among SETTING_FONT, THEME_FONT_SETTING and the
# engine's fallback font, with its glyphs rendered as a distance field of SHAPED_EM px.
# WHY: addons/world_label/README.md §4.3
static func _distance_field_font() -> FontFile:
	var source: FontFile = null
	for path: String in [setting(SETTING_FONT), ProjectSettings.get_setting(THEME_FONT_SETTING, "")]:
		if source == null and not path.is_empty():
			source = load(path) as FontFile
	if source == null:
		source = ThemeDB.fallback_font as FontFile
	var font: FontFile = FontFile.new()
	if source == null:
		push_error("[WorldLabelLayer] no FontFile to draw labels in — set %s" % SETTING_FONT)
		return font
	font.data = source.data
	font.multichannel_signed_distance_field = true
	font.msdf_size = SHAPED_EM
	font.msdf_pixel_range = MSDF_PIXEL_RANGE
	return font


## Stops drawing `anchor`. Does nothing for an anchor this layer does not have.
func leave(anchor: WorldLabel) -> void:
	var index: int = _anchors.find(anchor)
	if index < 0:
		return
	_labels[index].queue_free()
	var last: int = _anchors.size() - 1
	_anchors[index] = _anchors[last]
	_labels[index] = _labels[last]
	_anchors.remove_at(last)
	_labels.remove_at(last)


## Copies `anchor`'s text, size and colour to the label drawing it.
func rewrite(anchor: WorldLabel) -> void:
	var index: int = _anchors.find(anchor)
	if index >= 0:
		_write(anchor, _labels[index])


## The 2D label drawing `anchor`, or null. For lanes that measure what is drawn.
func drawn(anchor: WorldLabel) -> Label:
	var index: int = _anchors.find(anchor)
	return _labels[index] if index >= 0 else null


## Starts drawing `anchor`. `join` is the one caller; an anchor added twice is drawn twice.
func adopt(anchor: WorldLabel) -> void:
	var label: Label = Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.material = _material
	label.visible = false
	label.add_theme_font_override(&"font", _font)
	label.add_theme_font_size_override(&"font_size", SHAPED_EM)
	label.add_theme_constant_override(
		&"outline_size",
		roundi(SHAPED_EM * OUTLINE_SHARE) * MSDF_OUTLINE_FACTOR,
	)
	add_child(label)
	_anchors.append(anchor)
	_labels.append(label)
	_write(anchor, label)


func _write(anchor: WorldLabel, label: Label) -> void:
	label.text = anchor.text
	label.add_theme_color_override(&"font_color", anchor.color)
	label.add_theme_color_override(&"font_outline_color", anchor.outline_color)
	label.reset_size()


func _process(_delta: float) -> void:
	var viewport: Viewport = get_viewport()
	var camera: Camera3D = viewport.get_camera_3d()
	if camera == null:
		for label: Label in _labels:
			label.visible = false
		return
	_view = camera.get_camera_transform().affine_inverse()
	_projection = camera.get_camera_projection()
	_near = camera.near
	_visible = viewport.get_visible_rect().size
	_to_window = viewport.get_final_transform()
	_ratio = maxi(1, roundi(1.0 / maxf(viewport.scaling_3d_scale, 0.01)))
	_floor = _min_em_px * float(_ratio) / maxf(_to_window.get_scale().y, 0.0001)
	_environment = camera.environment
	if _environment == null:
		_environment = camera.get_world_3d().environment
	_refresh_mask(camera)
	for index: int in _anchors.size():
		_place(_anchors[index], _labels[index])


# Sizes, places, fades and sorts one label for this frame's camera, or hides it.
# WHY: addons/world_label/README.md §4.2
func _place(anchor: WorldLabel, label: Label) -> void:
	if anchor.text.is_empty() or not anchor.is_visible_in_tree():
		label.visible = false
		return
	var at: Vector3 = anchor.get_global_transform_interpolated().origin
	var local: Vector3 = _view * at
	var depth: float = -local.z
	if depth <= _near:
		label.visible = false
		return
	var distance: float = local.length()
	var fog: float = WorldLabelSystem.fog_amount(_environment, distance, at.y)
	var alpha: float = WorldLabelSystem.label_alpha(
		fog,
		distance,
		anchor.range_m,
		anchor.range_m * FADE_SHARE,
	)
	if alpha <= 0.0:
		label.visible = false
		return
	var em: float = WorldLabelSystem.em_canvas(
		float(anchor.font_size) * WorldLabelSystem.METRES_PER_FONT_PX,
		depth,
		_projection.y.y,
		_visible.y,
		_floor,
	)
	# The size is a transform, never a font size: a transform keeps the shaped text and its glyphs.
	# WHY: addons/world_label/README.md §4.3
	var drawn_scale: float = em / float(SHAPED_EM)
	label.scale = Vector2(drawn_scale, drawn_scale)
	var clip: Vector4 = _projection * Vector4(local.x, local.y, local.z, 1.0)
	var ndc: Vector2 = Vector2(clip.x, clip.y) / clip.w
	var centre: Vector2 = Vector2(
		(ndc.x + 1.0) * 0.5 * _visible.x,
		(1.0 - ndc.y) * 0.5 * _visible.y,
	)
	label.position = WorldLabelSystem.snap_to_cells(
		centre - label.size * drawn_scale * 0.5,
		_to_window,
		_ratio,
	)
	label.modulate.a = alpha
	label.z_index = -clampi(roundi(depth * Z_PER_M), 0, RenderingServer.CANVAS_ITEM_Z_MAX)
	label.set_instance_shader_parameter(&"label_depth", depth)
	label.visible = true


# Points the mask at the depth copy in the compositor `camera` renders with, or turns the mask off
# where there is none or the copy is not of the last frame drawn. Reports a missing effect once per
# compositor, and only where a RenderingDevice exists to have drawn one.
# WHY: addons/world_label/README.md §5.1
func _refresh_mask(camera: Camera3D) -> void:
	var compositor: Compositor = camera.compositor
	if compositor == null:
		compositor = _scene_compositor(camera.get_world_3d().environment)
	var effect: SceneDepthEffect = SceneDepthEffect.within(compositor)
	# The copy is of one viewport's pass only; any other viewport's labels draw unmasked.
	var live: bool = (
		effect != null and effect.texture.texture_rd_rid.is_valid()
		and Engine.get_process_frames() - effect.copied_frame <= STALE_FRAMES
		and effect.watches(get_viewport())
	)
	if live and _material.get_shader_parameter(&"scene_depth") != effect.texture:
		_material.set_shader_parameter(&"scene_depth", effect.texture)
	if live != _masked:
		_masked = live
		_material.set_shader_parameter(&"masked", live)
	var id: int = 0 if compositor == null else compositor.get_instance_id()
	if id == _compositor_id:
		return
	_compositor_id = id
	if effect == null and RenderingServer.get_rendering_device() != null:
		push_error(
			"[WorldLabelLayer] the camera's compositor has no SceneDepthEffect — labels draw unmasked"
		)


# The compositor of the WorldEnvironment that gave the world `environment`, or null. Searches the
# tree only when `environment` differs from the last one asked about.
func _scene_compositor(environment: Environment) -> Compositor:
	var id: int = 0 if environment == null else environment.get_instance_id()
	if id != _environment_id or not is_instance_valid(_world_environment):
		_environment_id = id
		_world_environment = _environment_owner(environment)
	return _world_environment.compositor if is_instance_valid(_world_environment) else null


# The WorldEnvironment in the tree whose environment is `environment`, or null.
func _environment_owner(environment: Environment) -> WorldEnvironment:
	if environment == null:
		return null
	for node: Node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		var world_environment: WorldEnvironment = node as WorldEnvironment
		if world_environment.environment == environment:
			return world_environment
	return null
