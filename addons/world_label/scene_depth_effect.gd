@tool
class_name SceneDepthEffect
extends CompositorEffect

## Copies the opaque 3D pass's depth into `texture` as linear view depth in metres, one texel per
## pixel of the 3D buffer, for one viewport's pass only (the root viewport's, until `watch` names
## another), so a 2D shader can hide what the scene stands in front of. The texture follows the 3D
## buffer's size. Does nothing where there is no RenderingDevice (headless, Compatibility).
## WHY: addons/world_label/README.md §5.2

## The compute shader, compiled at run time so the addon needs no `.glsl` import, which a headless
## editor cannot do. Each texel of `view_depth` is the linear view depth (m) of one 3D-buffer pixel,
## or NOTHING_DRAWN where the pass drew nothing; `depth_buffer` is the pass's reversed-Z depth.
## WHY: addons/world_label/README.md §5.2
const SHADER_SOURCE: String = """
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D depth_buffer;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D view_depth;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float depth_scale;
	float depth_offset;
}
params;

const float NOTHING_DRAWN = 1.0e6;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, ivec2(params.raster_size)))) {
		return;
	}
	float depth = texelFetch(depth_buffer, pixel, 0).r;
	float metres = depth <= 0.0 ? NOTHING_DRAWN : params.depth_scale / (depth + params.depth_offset);
	imageStore(view_depth, pixel, vec4(metres));
}
"""
## Compute work-group edge (px). Must match `local_size` in the shader.
const GROUP: int = 8

## The copy. Its RID is invalid until the first pass has been written, and is replaced in place when
## the 3D buffer changes size.
var texture: Texture2DRD = Texture2DRD.new()
## `Engine.get_process_frames()` at the last pass copied, or -1 before the first. A copy older than
## the frame before is not the scene on screen.
var copied_frame: int = -1

var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
# Unfiltered, so the shader reads the scene depth one texel per pixel.
var _sampler: RID
var _target: RID
var _target_size: Vector2i = Vector2i.ZERO
# Render target of the viewport whose pass is copied; the root viewport's, resolved on first use,
# until `watch` names another.
# WHY: addons/world_label/README.md §5.2
var _watched: RID
# Instance id of the viewport `watch` named, or 0 for the root viewport.
var _watched_id: int = 0


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE
	RenderingServer.call_on_render_thread(_compile)


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# The canvas texture goes first, so nothing is left sampling the copy when it is freed.
	texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(
		SceneDepthEffect.free_resources.bind(_rd, _pipeline, _shader, _sampler, _target)
	)


## The first SceneDepthEffect in `compositor`, or null if it has none or `compositor` is null.
static func within(compositor: Compositor) -> SceneDepthEffect:
	if compositor == null:
		return null
	for effect: CompositorEffect in compositor.compositor_effects:
		var depth: SceneDepthEffect = effect as SceneDepthEffect
		if depth != null:
			return depth
	return null


## Copies `viewport`'s 3D pass from the next frame on, in place of the root viewport's. For a game
## drawn inside a SubViewport. Main thread.
func watch(viewport: Viewport) -> void:
	_watched_id = viewport.get_instance_id()
	_watched = RenderingServer.viewport_get_render_target(viewport.get_viewport_rid())


## True if `viewport` is the one whose 3D pass is copied.
func watches(viewport: Viewport) -> bool:
	if _watched_id != 0:
		return viewport.get_instance_id() == _watched_id
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	return tree != null and viewport == tree.root


## Frees every valid RID given, on `rd`. Render thread only; this effect's teardown is its one
## caller.
static func free_resources(
	rd: RenderingDevice,
	pipeline: RID,
	shader: RID,
	sampler: RID,
	target: RID,
) -> void:
	if target.is_valid():
		rd.free_rid(target)
	if sampler.is_valid():
		rd.free_rid(sampler)
	# The pipeline is built from the shader, so it goes first.
	if pipeline.is_valid() and rd.compute_pipeline_is_valid(pipeline):
		rd.free_rid(pipeline)
	if shader.is_valid():
		rd.free_rid(shader)


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_OPAQUE:
		return
	if _rd == null or not _pipeline.is_valid():
		return
	var buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	if buffers == null or buffers.get_render_target() != _watched_target():
		return
	var size: Vector2i = buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	if size != _target_size and not _refit(size):
		return
	var projection: Projection = render_data.get_render_scene_data().get_cam_projection()
	# std430 push constants are padded to a multiple of 16 bytes: four floats.
	var params: PackedFloat32Array = [size.x, size.y, projection.w.z, projection.z.z]
	var bytes: PackedByteArray = params.to_byte_array()
	var depth: RDUniform = RDUniform.new()
	depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth.binding = 0
	depth.add_id(_sampler)
	depth.add_id(buffers.get_depth_layer(0))
	var image: RDUniform = RDUniform.new()
	image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image.binding = 1
	image.add_id(_target)
	var uniforms: Array[RDUniform] = [depth, image]
	var uniform_set: RID = UniformSetCacheRD.get_cache(_shader, 0, uniforms)
	@warning_ignore("integer_division")
	var groups: Vector2i = (size + Vector2i(GROUP - 1, GROUP - 1)) / GROUP
	var list: int = _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_set_push_constant(list, bytes, bytes.size())
	_rd.compute_list_dispatch(list, groups.x, groups.y, 1)
	_rd.compute_list_end()
	copied_frame = Engine.get_process_frames()


# The render target of the viewport whose pass is copied: the one `watch` named, or the root
# viewport's, looked up once. Invalid while there is neither.
# WHY: addons/world_label/README.md §5.2
func _watched_target() -> RID:
	if _watched.is_valid():
		return _watched
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree != null:
		_watched = RenderingServer.viewport_get_render_target(tree.root.get_viewport_rid())
	return _watched


# Replaces the copy with one `size` texels across, hands it to `texture`, then frees the old one.
# False, loudly, if the new texture could not be made; the old one is kept.
func _refit(size: Vector2i) -> bool:
	var format: RDTextureFormat = RDTextureFormat.new()
	format.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	format.width = size.x
	format.height = size.y
	format.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	var fresh: RID = _rd.texture_create(format, RDTextureView.new())
	if not fresh.is_valid():
		push_error("SceneDepthEffect: no %s depth texture could be made" % size)
		return false
	texture.texture_rd_rid = fresh
	if _target.is_valid():
		_rd.free_rid(_target)
	_target = fresh
	_target_size = size
	return true


# Builds the compute pipeline and the depth sampler on the render thread. Leaves `_pipeline` invalid,
# loudly, on any failure, and quietly where the renderer has no RenderingDevice.
func _compile() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		return
	var source: RDShaderSource = RDShaderSource.new()
	source.source_compute = SHADER_SOURCE
	var spirv: RDShaderSPIRV = _rd.shader_compile_spirv_from_source(source)
	if not spirv.compile_error_compute.is_empty():
		push_error("SceneDepthEffect: %s" % spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		push_error("SceneDepthEffect: the depth shader did not build")
		return
	_sampler = _rd.sampler_create(RDSamplerState.new())
	if not _sampler.is_valid():
		push_error("SceneDepthEffect: the depth sampler did not build")
		return
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		push_error("SceneDepthEffect: the depth pipeline did not build")
