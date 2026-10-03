class_name WorldLabelSystem
extends RefCounted

## The arithmetic behind a floating label: how large it is drawn, how much of it the fog and its
## range leave, and where on the window's pixel grid it lands. Static only, never instantiated.
## WHY: addons/world_label/README.md §4.1

## Metres of em per font pixel: `Label3D`'s default `pixel_size`, so a label keeps the size it was
## authored at in `Label3D` units.
## WHY: addons/world_label/README.md §4.2
const METRES_PER_FONT_PX: float = 0.005


## The fog `environment` lays over a point `distance` metres from the camera at world height
## `height`, 0..1: the forward shader's own fog amount. 0 with no environment or with fog off.
## WHY: addons/world_label/README.md §4.4
static func fog_amount(environment: Environment, distance: float, height: float) -> float:
	if environment == null or not environment.fog_enabled:
		return 0.0
	var amount: float = 0.0
	if environment.fog_mode == Environment.FOG_MODE_DEPTH:
		var along: float = smoothstep(
			environment.fog_depth_begin,
			environment.fog_depth_end,
			distance,
		)
		amount = pow(along, environment.fog_depth_curve) * environment.fog_density
	else:
		amount = 1.0 - exp(minf(0.0, -distance * environment.fog_density))
	if absf(environment.fog_height_density) >= 0.0001:
		var above: float = height - environment.fog_height
		amount = maxf(amount, 1.0 - exp(minf(0.0, above * environment.fog_height_density)))
	return clampf(amount, 0.0, 1.0)


## The share of a label left drawn, 0..1, at `distance` metres under `fog` (0..1): full inside
## `range_m - fade_m`, falling linearly to nothing at `range_m`, times what the fog leaves.
static func label_alpha(fog: float, distance: float, range_m: float, fade_m: float) -> float:
	if distance >= range_m:
		return 0.0
	var band: float = clampf(fade_m, 0.0, range_m)
	var ranged: float = 1.0
	if band > 0.0:
		ranged = clampf((range_m - distance) / band, 0.0, 1.0)
	return ranged * (1.0 - clampf(fog, 0.0, 1.0))


## Em, in canvas units, a label of `em_m` metres is drawn at from view depth `depth` metres (above 0):
## its projected world size, or `floor_canvas` if that is larger. `proj_yy` is the camera
## projection's vertical scale, `visible_height` the viewport's height in canvas units.
## WHY: addons/world_label/README.md §4.2
static func em_canvas(
	em_m: float,
	depth: float,
	proj_yy: float,
	visible_height: float,
	floor_canvas: float,
) -> float:
	var world: float = em_m * absf(proj_yy) * visible_height * 0.5 / depth
	return maxf(world, floor_canvas)


## `canvas_point` moved to the nearest window position on a whole multiple of `ratio` window pixels,
## back in canvas units. `to_window` maps canvas units to window pixels.
## WHY: addons/world_label/README.md §4.5
static func snap_to_cells(canvas_point: Vector2, to_window: Transform2D, ratio: int) -> Vector2:
	var cell: float = float(maxi(ratio, 1))
	var window: Vector2 = to_window * canvas_point
	window = (window / cell).round() * cell
	return to_window.affine_inverse() * window
