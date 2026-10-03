extends SceneTree

## What the overlay draws, read off the drawn 2D labels: sizes, placement, alpha and the font,
## never pixels. Headless; the depth mask needs a RenderingDevice and is not measured here.
## Runs in any project holding the addon. A project extends this script and overrides
## `_extra_rows` to add rows of its own.
## WHY: addons/world_label/README.md §8
#
# One camera looking down -Z from the origin, or from CAMERA_BACK behind it, in an environment with
# depth fog from FOG_BEGIN to FOG_END. The window is WINDOW and the 3D scale SCALE_3D, set here.
#
#   SIZE      labels at their reading distances, in both views: the drawn em is at least FLOOR_PX
#             pixels of the 3D buffer, and where the world size is bigger than that, it is the world
#             size to within a pixel. Both figures come from the camera's fov, the window and the 3D
#             scale, never from the overlay's own floor dial.
#   BEHIND    an anchor behind the camera draws nothing, although its mirrored projection is on
#             screen.
#   FOG       a label 40 m off draws at no more than 1 - the depth fog there; one 6 m off at 1.
#   RANGE     a label past its range draws nothing; inside its fade band it draws under the fog
#             alpha alone; short of the band it draws at the fog alpha.
#   GRID      a label's top-left corner lands on a whole 3D pixel, and its centre within one of the
#             anchor's projection.
#   STEADY    a label moved from 2 m to 4 m is drawn smaller by its scale alone: its font size and
#             outline stay as they were, so nothing is shaped again, and its font is a distance field.
#   COLOUR    the drawn text and outline take the anchor's colours, and follow a change to them.
#   LEAVE     a WorldLabel subclass that defines its own _exit_tree stops being drawn when it leaves.
#
#   godot --headless --fixed-fps 60 --path . --script res://addons/world_label/checks/world_label_check.gd

## The smallest em a label may be drawn at, in 3D-buffer pixels. Written here, not read off the layer.
const FLOOR_PX: float = 8.0
## Metres the third-person camera stands behind the eye.
const CAMERA_BACK: float = 1.5
## Metres per font pixel of the unit labels are authored in.
const METRES_PER_FONT_PX: float = 0.005
## Frames after a move before the drawn labels are read.
const SETTLE: int = 2
const FOG_BEGIN: float = 8.0
const FOG_END: float = 50.0
## Window (px) every row is measured at.
const WINDOW: Vector2i = Vector2i(1152, 648)
## 3D render scale every row is measured at: a 324-line buffer under the 648-line window.
const SCALE_3D: float = 0.5

# Each kind's font size and the two distances (m) from the eye it is read at: a small readout, a
# note, a large sign.
var _kinds: PackedVector3Array = [
	Vector3(18.0, 4.0, 12.0),
	Vector3(24.0, 2.0, 6.0),
	Vector3(40.0, 8.0, 30.0),
]
var _fails: int = 0
# SIZE cases whose world size is over the floor, and under it: both must occur or a bar is idle.
var _world_sized: int = 0
var _floored: int = 0
var _camera: Camera3D
var _world: Node3D


func _initialize() -> void:
	_world = Node3D.new()
	root.add_child(_world)
	var environment: Environment = Environment.new()
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_density = 1.0
	environment.fog_depth_begin = FOG_BEGIN
	environment.fog_depth_end = FOG_END
	environment.fog_depth_curve = 1.0
	var world_environment: WorldEnvironment = WorldEnvironment.new()
	world_environment.environment = environment
	_world.add_child(world_environment)
	_camera = Camera3D.new()
	_world.add_child(_camera)
	_camera.make_current()
	_run()


func _run() -> void:
	# A headless window is 64 px square until given a size after boot; every figure here is per
	# window pixel.
	await process_frame
	root.size = WINDOW
	await _settle()
	root.scaling_3d_scale = SCALE_3D
	await _settle()
	if root.size != WINDOW or root.get_visible_rect().size != Vector2(WINDOW):
		_fail("premise: the window is %s, showing %s" % [root.size, root.get_visible_rect().size])
		quit(1)
		return
	await _size()
	await _behind()
	await _fog()
	await _range()
	await _grid()
	await _steady()
	await _colour()
	await _leave()
	await _extra_rows()
	print("WORLD LABEL %s — %d bar(s) tripped" % ["PASS" if _fails == 0 else "FAIL", _fails])
	quit(0 if _fails == 0 else 1)


func _steady() -> void:
	var label: WorldLabel = _label("STEADY", 40, 100.0, Vector3(0.0, 0.0, -2.0), 0.0)
	await _settle()
	var drawn: Label = _drawn(label)
	var near_font: int = drawn.get_theme_font_size(&"font_size")
	var near_outline: int = drawn.get_theme_constant(&"outline_size")
	var near_scale: float = drawn.scale.y
	label.position = Vector3(0.0, 0.0, -4.0)
	await _settle()
	var far_scale: float = drawn.scale.y
	var font: FontFile = drawn.get_theme_font(&"font") as FontFile
	print(
		"STEADY font %d, outline %d, scale %.3f at 2 m and %.3f at 4 m"
		% [near_font, near_outline, near_scale, far_scale]
	)
	_check(
		far_scale < near_scale * 0.8,
		"STEADY premise: the scale went %.3f to %.3f, so the move tested nothing"
		% [near_scale, far_scale],
	)
	_check(
		drawn.get_theme_font_size(&"font_size") == near_font,
		"STEADY the font size went %d to %d, so the text was shaped again"
		% [near_font, drawn.get_theme_font_size(&"font_size")],
	)
	_check(
		drawn.get_theme_constant(&"outline_size") == near_outline,
		"STEADY the outline went %d to %d"
		% [near_outline, drawn.get_theme_constant(&"outline_size")],
	)
	_check(
		font != null and font.multichannel_signed_distance_field,
		"STEADY the drawn font is not a distance field, so a scaled label blurs",
	)
	label.free()


func _size() -> void:
	for kind: Vector3 in _kinds:
		for distance: float in [kind.y, kind.z]:
			for back: float in [0.0, CAMERA_BACK]:
				await _size_one(int(kind.x), distance, back)
	_check(_world_sized > 0, "SIZE premise: no label was big enough to be drawn at its world size")
	_check(_floored > 0, "SIZE premise: no label was small enough to be held at the floor")


func _size_one(font: int, distance: float, back: float) -> void:
	var label: WorldLabel = _label("SIZE", font, 100.0, Vector3(0.0, 0.0, -distance), back)
	await _settle()
	var drawn: Label = _drawn(label)
	var depth: float = distance + back
	var buffer_h: float = root.get_visible_rect().size.y * _canvas_to_buffer()
	var world_px: float = (
		font * METRES_PER_FONT_PX * buffer_h / (2.0 * depth * tan(deg_to_rad(_camera.fov) * 0.5))
	)
	var em_px: float = (
		float(drawn.get_theme_font_size(&"font_size")) * drawn.scale.y * _canvas_to_buffer()
	)
	print(
		"SIZE  font %d at %.1f m, back %.1f: em %.2f px, world %.2f px"
		% [font, distance, back, em_px, world_px]
	)
	_check(
		drawn.visible,
		"SIZE font %d at %.1f m (back %.1f) is not drawn" % [font, distance, back],
	)
	_check(
		em_px >= FLOOR_PX - 0.01,
		"SIZE font %d at %.1f m (back %.1f) is %.2f px, under the %.0f px floor"
		% [font, distance, back, em_px, FLOOR_PX],
	)
	if world_px < FLOOR_PX:
		_floored += 1
	if world_px > FLOOR_PX + 1.0:
		_world_sized += 1
		_check(
			absf(em_px - world_px) <= 1.0,
			"SIZE font %d at %.1f m (back %.1f) is %.2f px, not its world size %.2f px"
			% [font, distance, back, em_px, world_px],
		)
	label.free()


func _behind() -> void:
	var label: WorldLabel = _label("BEHIND", 32, 100.0, Vector3(0.0, 0.0, 3.0), 0.0)
	await _settle()
	_check(not _drawn(label).visible, "BEHIND an anchor behind the camera is drawn")
	label.free()


func _fog() -> void:
	var far: WorldLabel = _label("FOG far", 40, 100.0, Vector3(0.0, 0.0, -40.0), 0.0)
	var near: WorldLabel = _label("FOG near", 40, 100.0, Vector3(1.0, 0.0, -6.0), 0.0)
	await _settle()
	var far_alpha: float = _alpha(_drawn(far))
	var near_alpha: float = _alpha(_drawn(near))
	var fog: float = _depth_fog(Vector3(0.0, 0.0, -40.0).length())
	print("FOG   40 m alpha %.3f, fog %.3f; 6 m alpha %.3f" % [far_alpha, fog, near_alpha])
	_check(fog > 0.5, "FOG premise: the fog at 40 m is %.3f, too thin to test" % fog)
	_check(
		far_alpha <= 1.0 - fog + 0.001,
		"FOG 40 m draws at %.3f through fog %.3f" % [far_alpha, fog],
	)
	_check(is_equal_approx(near_alpha, 1.0), "FOG 6 m draws at %.3f, not 1" % near_alpha)
	far.free()
	near.free()


func _range() -> void:
	# Range 20 fades over its last fifth, 16 m to 20 m.
	var past: WorldLabel = _label("RANGE past", 32, 20.0, Vector3(0.0, 0.0, -21.0), 0.0)
	var band: WorldLabel = _label("RANGE band", 32, 20.0, Vector3(2.0, 0.0, -18.9), 0.0)
	var short: WorldLabel = _label("RANGE short", 32, 20.0, Vector3(-2.0, 0.0, -11.8), 0.0)
	await _settle()
	var band_fog: float = 1.0 - _depth_fog(Vector3(2.0, 0.0, -18.9).length())
	var short_fog: float = 1.0 - _depth_fog(Vector3(-2.0, 0.0, -11.8).length())
	var band_alpha: float = _alpha(_drawn(band))
	var short_alpha: float = _alpha(_drawn(short))
	print(
		"RANGE band alpha %.3f of fog %.3f; short %.3f of %.3f"
		% [band_alpha, band_fog, short_alpha, short_fog]
	)
	_check(not _drawn(past).visible, "RANGE a label past its range is drawn")
	_check(
		band_alpha > 0.0 and band_alpha < band_fog - 0.1,
		"RANGE the fade band draws at %.3f, the fog alone gives %.3f" % [band_alpha, band_fog],
	)
	_check(
		absf(short_alpha - short_fog) < 0.01,
		"RANGE short of the band draws at %.3f, the fog gives %.3f" % [short_alpha, short_fog],
	)
	past.free()
	band.free()
	short.free()


func _grid() -> void:
	var anchor: Vector3 = Vector3(0.37, 0.23, -5.3)
	var label: WorldLabel = _label("GRID off the cells", 27, 100.0, anchor, 0.0)
	await _settle()
	var drawn: Label = _drawn(label)
	var ratio: int = maxi(1, roundi(1.0 / root.scaling_3d_scale))
	var corner: Vector2 = root.get_final_transform() * drawn.position
	var centre: Vector2 = drawn.position + drawn.size * drawn.scale * 0.5
	var projected: Vector2 = _camera.unproject_position(anchor)
	var cell: float = float(ratio) / root.get_final_transform().get_scale().y
	print("GRID  corner %s window px, centre %s, projection %s" % [corner, centre, projected])
	_check(
		is_zero_approx(fposmod(corner.x, ratio)) and is_zero_approx(fposmod(corner.y, ratio)),
		"GRID the corner %s is not on a %d px cell" % [corner, ratio],
	)
	_check(
		centre.distance_to(projected) <= cell * 1.5,
		"GRID the centre %s is off the projection %s" % [centre, projected],
	)
	label.free()


func _colour() -> void:
	var label: WorldLabel = _label("COLOUR", 32, 100.0, Vector3(0.0, 0.0, -4.0), 0.0)
	label.color = Color(0.9, 0.6, 0.2)
	label.outline_color = Color(0.1, 0.2, 0.3)
	await _settle()
	var drawn: Label = _drawn(label)
	_check(
		drawn.get_theme_color(&"font_color") == label.color,
		"COLOUR the text is %s, the anchor says %s"
		% [drawn.get_theme_color(&"font_color"), label.color],
	)
	_check(
		drawn.get_theme_color(&"font_outline_color") == label.outline_color,
		"COLOUR the outline is %s, the anchor says %s"
		% [drawn.get_theme_color(&"font_outline_color"), label.outline_color],
	)
	label.outline_color = Color(0.7, 0.0, 0.7)
	await _settle()
	_check(
		drawn.get_theme_color(&"font_outline_color") == label.outline_color,
		"COLOUR the outline did not follow a change to %s" % label.outline_color,
	)
	label.free()


func _leave() -> void:
	await _leave_one(ExitTreeLabel.new())


## Shows `label` 4 m ahead, takes it out of the tree, and checks its drawn label went with it.
## Frees `label`.
func _leave_one(label: WorldLabel) -> void:
	label.text = "LEAVE"
	_world.add_child(label)
	label.position = Vector3(0.0, 0.0, -4.0)
	await _settle()
	var layer: WorldLabelLayer = _layer()
	var before: int = layer.get_child_count()
	_check(layer.drawn(label) != null, "LEAVE premise: %s was never drawn" % label.get_class())
	_world.remove_child(label)
	await _settle()
	_check(layer.drawn(label) == null, "LEAVE a label out of the tree is still drawn")
	_check(layer.get_child_count() == before - 1, "LEAVE the label's drawn label was not freed")
	label.free()


## Rows a project adds by overriding. Runs after every row above, before the verdict.
func _extra_rows() -> void:
	pass


# A label in the world at `at` seen from the camera `back` metres behind the origin.
func _label(text: String, font: int, range_m: float, at: Vector3, back: float) -> WorldLabel:
	_camera.position = Vector3(0.0, 0.0, back)
	var label: WorldLabel = WorldLabel.new()
	label.text = text
	label.font_size = font
	label.range_m = range_m
	_world.add_child(label)
	label.position = at
	return label


func _layer() -> WorldLabelLayer:
	return root.get_node_or_null(^"WorldLabelLayer") as WorldLabelLayer


func _drawn(label: WorldLabel) -> Label:
	var layer: WorldLabelLayer = _layer()
	var drawn: Label = layer.drawn(label) if layer != null else null
	if drawn == null:
		_fail("%s has no drawn label" % label.text)
		return Label.new()
	return drawn


func _alpha(drawn: Label) -> float:
	return drawn.modulate.a if drawn.visible else 0.0


# 3D-buffer pixels per canvas unit.
func _canvas_to_buffer() -> float:
	return root.get_final_transform().get_scale().y * root.scaling_3d_scale


# The engine's depth fog at `distance` for this file's environment, curve 1, density 1.
func _depth_fog(distance: float) -> float:
	var t: float = clampf((distance - FOG_BEGIN) / (FOG_END - FOG_BEGIN), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


func _settle() -> void:
	for i: int in SETTLE:
		await process_frame


func _check(ok: bool, message: String) -> void:
	if not ok:
		_fail(message)


func _fail(message: String) -> void:
	print("FAIL: " + message)
	_fails += 1


# A label that defines its own _exit_tree, as a game's subclass might.
class ExitTreeLabel:
	extends WorldLabel

	func _exit_tree() -> void:
		pass
