@tool
extends EditorPlugin

## Lists the overlay's project settings (`WorldLabelLayer.SETTINGS`) in Project Settings, at their
## defaults where the project has not set them. Labels work without the plugin; it only makes the
## settings visible. Disabling it leaves any values the project saved.


func _enter_tree() -> void:
	for name: String in WorldLabelLayer.SETTINGS:
		var entry: Array = WorldLabelLayer.SETTINGS[name]
		if not ProjectSettings.has_setting(name):
			ProjectSettings.set_setting(name, entry[0])
		ProjectSettings.set_initial_value(name, entry[0])
		ProjectSettings.set_as_basic(name, true)
		ProjectSettings.add_property_info(
			{ "name": name, "type": entry[1], "hint": entry[2], "hint_string": entry[3] },
		)
