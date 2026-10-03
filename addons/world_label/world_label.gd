@tool
class_name WorldLabel
extends Node3D

## A name or a measurement floating at this node's position. Drawn as crisp 2D text over the 3D image
## by its viewport's WorldLabelLayer: at world size up close, never under a legible floor far away,
## faded by the fog and out past `range_m`, and hidden per pixel wherever the 3D pass drew something
## in front of it. In the editor it shows as a billboard Label3D preview, which is never saved.
## WHY: addons/world_label/README.md §4.1

## What the label says. Blank draws nothing. Written straight through to the drawn text.
@export_multiline var text: String = "":
	set(value):
		if value == text:
			return
		text = value
		_changed()

## Size in font pixels of `WorldLabelSystem.METRES_PER_FONT_PX` metres each, the unit `Label3D`
## authored in: 40 is an em of 0.2 m.
@export_range(1, 256, 1) var font_size: int = 32:
	set(value):
		if value == font_size:
			return
		font_size = value
		_changed()

## Colour of the letters.
@export var color: Color = Color.WHITE:
	set(value):
		if value == color:
			return
		color = value
		_changed()

## Colour of the outline round the letters.
@export var outline_color: Color = Color.BLACK:
	set(value):
		if value == outline_color:
			return
		outline_color = value
		_changed()

## Metres from the camera at which the label is gone. It fades out over the last
## `WorldLabelLayer.FADE_SHARE` of this.
## WHY: addons/world_label/README.md §4.4
@export_range(1.0, 200.0, 0.5, "suffix:m") var range_m: float = 20.0

# The layer drawing this label; null out of the tree. A layer can be freed by whoever owns the
# viewport, so every use is validity-checked.
var _layer: WorldLabelLayer
# The editor's stand-in for the drawn text; null outside the editor.
var _preview: Label3D


# Joins the layer on entering the tree and leaves it on exit; in the editor, shows the preview
# instead. A notification rather than `_enter_tree`/`_exit_tree`, which a subclass defining its own
# would replace.
# WHY: addons/world_label/README.md §4.7
func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		if Engine.is_editor_hint():
			_show_preview()
		else:
			_layer = WorldLabelLayer.join(self)
	elif what == NOTIFICATION_EXIT_TREE:
		if is_instance_valid(_layer):
			_layer.leave(self)
		_layer = null


## Registers with this viewport's layer again, after the layer drawing it was freed. Does nothing
## out of the tree, in the editor, or while a live layer still has it.
func rejoin() -> void:
	if is_inside_tree() and not Engine.is_editor_hint() and not is_instance_valid(_layer):
		_layer = WorldLabelLayer.join(self)


# Copies the label's look to whatever draws it: the layer in a running game, the preview in the editor.
func _changed() -> void:
	if is_instance_valid(_layer):
		_layer.rewrite(self)
	if is_instance_valid(_preview):
		_write_preview()


# Makes the preview, an internal child with no owner, so it is neither listed nor saved.
func _show_preview() -> void:
	if is_instance_valid(_preview):
		return
	_preview = Label3D.new()
	_preview.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_preview.pixel_size = WorldLabelSystem.METRES_PER_FONT_PX
	add_child(_preview, false, INTERNAL_MODE_FRONT)
	_write_preview()


func _write_preview() -> void:
	_preview.text = text
	_preview.font_size = font_size
	_preview.modulate = color
	_preview.outline_modulate = outline_color
	_preview.outline_size = roundi(float(font_size) * WorldLabelLayer.OUTLINE_SHARE)
