extends Node2D
class_name BorderAreaManager

# —— 可调参数（全局）——
@export_range(0.0, 512.0, 1.0) var border_thickness: float = 64.0        # 全局默认粗细
@export var top_enabled: bool = true
@export var right_enabled: bool = true
@export var bottom_enabled: bool = true
@export var left_enabled: bool = true

# —— 可调参数（分别调粗细）——
@export var per_side_thickness_enabled: bool = false                      # 开=按边设置；关=用全局
@export_range(0.0, 512.0, 1.0) var top_thickness: float = 64.0
@export_range(0.0, 512.0, 1.0) var right_thickness: float = 64.0
@export_range(0.0, 512.0, 1.0) var bottom_thickness: float = 64.0
@export_range(0.0, 512.0, 1.0) var left_thickness: float = 64.0

# —— 物理层 —— 
@export_flags_2d_physics var collision_layer: int = 1
@export_flags_2d_physics var collision_mask: int = 1

# —— 调试显示 —— 
@export var debug_visible: bool = false
@export var debug_color: Color = Color(1, 0, 0, 0.15)

# 只向内侧增加的“内缩量”（不会让外框外扩）
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
	var r: Rect2 = _compute_local_rect()
	var t := _calc_thickness_per_side(r)

	if top_enabled and t.top > 0.0:
		draw_rect(Rect2(r.position, Vector2(r.size.x, t.top)), debug_color, true)
	if right_enabled and t.right > 0.0:
		draw_rect(Rect2(Vector2(r.position.x + r.size.x - t.right, r.position.y), Vector2(t.right, r.size.y)), debug_color, true)
	if bottom_enabled and t.bottom > 0.0:
		draw_rect(Rect2(Vector2(r.position.x, r.position.y + r.size.y - t.bottom), Vector2(r.size.x, t.bottom)), debug_color, true)
	if left_enabled and t.left > 0.0:
		draw_rect(Rect2(r.position, Vector2(t.left, r.size.y)), debug_color, true)

func _rebuild() -> void:
	# 清理旧节点
	for n in [N_TOP, N_RIGHT, N_BOTTOM, N_LEFT]:
		var old: Node = get_node_or_null(n)
		if old != null:
			old.queue_free()
	await get_tree().process_frame

	var r: Rect2 = _compute_local_rect()
	var t := _calc_thickness_per_side(r)

	# Top（外缘贴外框，只向内收）
	if top_enabled and t.top > 0.0:
		_make_bar(N_TOP, Rect2(r.position, Vector2(r.size.x, t.top)))
	# Right
	if right_enabled and t.right > 0.0:
		_make_bar(N_RIGHT, Rect2(Vector2(r.position.x + r.size.x - t.right, r.position.y), Vector2(t.right, r.size.y)))
	# Bottom
	if bottom_enabled and t.bottom > 0.0:
		_make_bar(N_BOTTOM, Rect2(Vector2(r.position.x, r.position.y + r.size.y - t.bottom), Vector2(r.size.x, t.bottom)))
	# Left
	if left_enabled and t.left > 0.0:
		_make_bar(N_LEFT, Rect2(r.position, Vector2(t.left, r.size.y)))

func _make_bar(name_: String, rect_local: Rect2) -> void:
	var area := Area2D.new()
	area.name = name_
	area.collision_layer = collision_layer
	area.collision_mask = collision_mask
	area.monitoring = true
	area.monitorable = true
	add_child(area)

	var cs := CollisionShape2D.new()
	area.add_child(cs)

	var shape := RectangleShape2D.new()
	shape.size = rect_local.size
	cs.shape = shape

	# Area2D 放到矩形中心
	area.position = rect_local.position + rect_local.size * 0.5

# —— 计算每条边的有效厚度（外框固定，向内收）——
class Thickness:
	var top: float
	var right: float
	var bottom: float
	var left: float

func _calc_thickness_per_side(r: Rect2) -> Thickness:
	var t_base: float = max(border_thickness, 0.0)
	var inset: float = max(inset_offset, 0.0)

	var raw_top: float = (max(top_thickness, 0.0) if per_side_thickness_enabled else t_base)
	var raw_right: float = (max(right_thickness, 0.0) if per_side_thickness_enabled else t_base)
	var raw_bottom: float = (max(bottom_thickness, 0.0) if per_side_thickness_enabled else t_base)
	var raw_left: float = (max(left_thickness, 0.0) if per_side_thickness_enabled else t_base)

	var t := Thickness.new()
	# 限制：上下厚度 ≤ 高度一半；左右厚度 ≤ 宽度一半（只向内收缩）
	t.top = clampf(raw_top + inset, 0.0, r.size.y * 0.5)
	t.bottom = clampf(raw_bottom + inset, 0.0, r.size.y * 0.5)
	t.left = clampf(raw_left + inset, 0.0, r.size.x * 0.5)
	t.right = clampf(raw_right + inset, 0.0, r.size.x * 0.5)
	return t


# —— 关键：根据坐标空间计算“本节点局部”矩形 —— 
func _compute_local_rect() -> Rect2:
	var vp: Rect2i = get_viewport_rect()
	var vp_size: Vector2 = Vector2(vp.size.x, vp.size.y)

	if coordinate_space == CoordinateSpace.ScreenOverlay:
		return Rect2(local_offset, vp_size)

	var cam: Camera2D = null
	if camera_path != NodePath(""):
		var node: Node = get_node_or_null(camera_path)
		if node is Camera2D:
			cam = node as Camera2D

	if cam == null:
		return Rect2(local_offset, vp_size)

	# —— 显式类型，避免 Variant 推断 —— 
	var tl_world: Vector2 = cam.screen_to_world(Vector2.ZERO)
	var br_world: Vector2 = cam.screen_to_world(vp_size)

	var world_pos: Vector2 = tl_world
	var world_size: Vector2 = br_world - tl_world

	var tl_local: Vector2 = to_local(world_pos)
	return Rect2(tl_local + local_offset, world_size)
