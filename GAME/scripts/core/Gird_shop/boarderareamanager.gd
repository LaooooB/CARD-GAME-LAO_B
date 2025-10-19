extends Node2D
class_name BorderAreaManager

# —— 可调参数 —— 
@export_range(0.0, 512.0, 1.0) var border_thickness: float = 64.0
@export var top_enabled: bool = true
@export var right_enabled: bool = true
@export var bottom_enabled: bool = true
@export var left_enabled: bool = true

@export_flags_2d_physics var collision_layer: int = 1
@export_flags_2d_physics var collision_mask: int = 1

@export var debug_visible: bool = false
@export var debug_color: Color = Color(1, 0, 0, 0.15)
@export var inset_offset: float = 0.0

# 额外：对整体边框矩形做局部偏移（用于对齐父级原点、相机左上等）
@export var local_offset: Vector2 = Vector2.ZERO

# 0=ScreenOverlay；1=WorldWithCamera
enum CoordinateSpace { ScreenOverlay, WorldWithCamera }
@export var coordinate_space: CoordinateSpace = CoordinateSpace.ScreenOverlay
@export var camera_path: NodePath

# —— 内部常量 —— 
const N_TOP := "Top"
const N_RIGHT := "Right"
const N_BOTTOM := "Bottom"
const N_LEFT := "Left"

func _ready() -> void:
	var win: Window = get_window()
	if win != null and not win.size_changed.is_connected(_on_window_resized):
		win.size_changed.connect(_on_window_resized)
	_rebuild()

func _on_window_resized() -> void:
	_rebuild()
	queue_redraw()

func refresh() -> void:
	_rebuild()
	queue_redraw()

func _draw() -> void:
	if not debug_visible:
		return
	var r_local: Rect2 = _compute_local_rect()
	var t: float = max(border_thickness, 0.0)
	var inset: float = inset_offset

	if top_enabled:
		draw_rect(Rect2(r_local.position + Vector2(0, -inset), Vector2(r_local.size.x, t + inset)), debug_color, true)
	if right_enabled:
		draw_rect(Rect2(r_local.position + Vector2(r_local.size.x - t, 0) + Vector2(inset, 0), Vector2(t + inset, r_local.size.y)), debug_color, true)
	if bottom_enabled:
		draw_rect(Rect2(r_local.position + Vector2(0, r_local.size.y - t) + Vector2(0, inset), Vector2(r_local.size.x, t + inset)), debug_color, true)
	if left_enabled:
		draw_rect(Rect2(r_local.position + Vector2(-inset, 0), Vector2(t + inset, r_local.size.y)), debug_color, true)

func _rebuild() -> void:
	# 清理旧节点
	for n in [N_TOP, N_RIGHT, N_BOTTOM, N_LEFT]:
		var old: Node = get_node_or_null(n)
		if old != null:
			old.queue_free()
	await get_tree().process_frame

	var r_local: Rect2 = _compute_local_rect()
	var t: float = max(border_thickness, 0.0)
	var inset: float = inset_offset

	if top_enabled:
		_make_bar(N_TOP, Rect2(r_local.position + Vector2(0, -inset), Vector2(r_local.size.x, t + inset)))
	if right_enabled:
		_make_bar(N_RIGHT, Rect2(r_local.position + Vector2(r_local.size.x - t, 0) + Vector2(inset, 0), Vector2(t + inset, r_local.size.y)))
	if bottom_enabled:
		_make_bar(N_BOTTOM, Rect2(r_local.position + Vector2(0, r_local.size.y - t) + Vector2(0, inset), Vector2(r_local.size.x, t + inset)))
	if left_enabled:
		_make_bar(N_LEFT, Rect2(r_local.position + Vector2(-inset, 0), Vector2(t + inset, r_local.size.y)))

func _make_bar(name_: String, rect_local: Rect2) -> void:
	var area: Area2D = Area2D.new()
	area.name = name_
	area.collision_layer = collision_layer
	area.collision_mask = collision_mask
	area.monitoring = true
	area.monitorable = true
	add_child(area)

	var cs: CollisionShape2D = CollisionShape2D.new()
	area.add_child(cs)

	var shape: RectangleShape2D = RectangleShape2D.new()
	shape.size = rect_local.size
	cs.shape = shape

	area.position = rect_local.position + rect_local.size * 0.5

# —— 关键：根据坐标空间计算“本节点局部”矩形 —— 
func _compute_local_rect() -> Rect2:
	var vp: Rect2i = get_viewport_rect()
	var vp_size: Vector2 = Vector2(vp.size.x, vp.size.y)

	if coordinate_space == CoordinateSpace.ScreenOverlay:
		# 屏幕叠加：以屏幕像素为局部坐标，并应用自定义偏移
		return Rect2(local_offset, vp_size)

	# WorldWithCamera：将屏幕四角换算成世界矩形，再转到本地，并应用自定义偏移
	var cam: Camera2D = null
	if camera_path != NodePath(""):
		var node: Node = get_node_or_null(camera_path)
		if node is Camera2D:
			cam = node as Camera2D

	if cam == null:
		# 容错：没有相机就退化成屏幕矩形
		return Rect2(local_offset, vp_size)

	var tl_world: Vector2 = cam.screen_to_world(Vector2.ZERO)
	var br_world: Vector2 = cam.screen_to_world(vp_size)
	var world_pos: Vector2 = tl_world
	var world_size: Vector2 = br_world - tl_world

	var tl_local: Vector2 = to_local(world_pos)
	# 加上偏移
	return Rect2(tl_local + local_offset, world_size)
