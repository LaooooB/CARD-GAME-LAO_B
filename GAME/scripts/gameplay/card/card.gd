extends Node2D
class_name Card

# =========================
# —— 可在 Inspector 调参 ——
# =========================
@export var grid_manager_path: NodePath                 # 可以留空，自动找 Main 里的 GridManager 节点
@export var sprite_path: NodePath = ^"Sprite2D"
@export var hit_full_path: NodePath = ^"hit_full"
@export var hit_header_path: NodePath = ^"hit_header"

@export var pickup_scale: float = 1.06
@export var drag_z: int = 9000

# =========================
# —— 信号 ——
# =========================
signal drag_started(card: Card)
signal drag_moved(card: Card, mouse_global: Vector2)
signal drag_ended(card: Card)

# =========================
# —— 运行期状态 ——
# =========================
var _grid: Node = null
var _sprite: Sprite2D = null
var _hit_full: Area2D = null
var _hit_header: Area2D = null
var _anim: Node = null

var _dragging: bool = false
var _drag_mode: StringName = &"single"        # "single"|"pile"|"substack"
var _drag_offset: Vector2 = Vector2.ZERO      # 统一用“全局坐标”计算

var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _interaction_enabled: bool = true
var _pre_drag_global: Vector2 = Vector2.ZERO

# 堆信息（由 PileManager 调用 set_pile 维护）
var _in_pile: bool = false
var _pile_ref: Node = null

# =========================
# —— 生命周期 ——
# =========================
func _ready() -> void:
	# 找 GridManager（按路径→按名字→最后兜底/root/Grid）
	_grid = get_node_or_null(grid_manager_path)
	if _grid == null and get_tree().current_scene != null:
		_grid = get_tree().current_scene.get_node_or_null(^"GridManager")
	if _grid == null:
		_grid = get_tree().get_root().find_child("GridManager", true, false)
	if _grid == null:
		_grid = get_node_or_null(^"/root/Grid")

	# 找子节点
	_sprite = get_node_or_null(sprite_path) as Sprite2D
	_hit_full = get_node_or_null(hit_full_path) as Area2D
	_hit_header = get_node_or_null(hit_header_path) as Area2D
	if _sprite == null:
		_sprite = find_child("Sprite2D", true, false) as Sprite2D
	if _hit_full == null:
		_hit_full = find_child("hit_full", true, false) as Area2D
	if _hit_header == null:
		_hit_header = find_child("hit_header", true, false) as Area2D

	_anim = find_child("CardAnimation", true, false)

	# 记录原始视觉
	_orig_scale = scale
	_orig_z = z_index

	# 连接命中区输入
	if _hit_full != null:
		_hit_full.input_event.connect(_on_hit_full_input)
	if _hit_header != null:
		_hit_header.input_event.connect(_on_hit_header_input)

	set_process(true)
	set_process_unhandled_input(true)

# =========================
# —— 拖拽跟随（统一用全局鼠标） ——
# =========================
func _process(_delta: float) -> void:
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()      # ✅ 全局鼠标
		var target: Vector2 = mouse_g - _drag_offset            # ✅ 偏移以全局计算
		_follow_to(target)
		emit_signal("drag_moved", self, mouse_g)

func _unhandled_input(event: InputEvent) -> void:
	if _dragging and event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_end_drag_and_drop()

# =========================
# —— 命中区事件 ——
# =========================
func _on_hit_full_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not _interaction_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_on_pressed_full()

func _on_hit_header_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not _interaction_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_on_pressed_header()

func _on_pressed_full() -> void:
	if _in_pile and is_instance_valid(_pile_ref) and _pile_ref.has_method("request_drag"):
		_pile_ref.call("request_drag", self, "pile")
		return
	begin_drag(&"single")

func _on_pressed_header() -> void:
	if _in_pile and is_instance_valid(_pile_ref) and _pile_ref.has_method("request_drag"):
		var start_index: int = -1
		if _pile_ref.has_method("index_of_card"):
			start_index = int(_pile_ref.call("index_of_card", self))
		_pile_ref.call("request_drag", self, "substack", start_index)
		return
	begin_drag(&"single")

# =========================
# —— 公共：开始/结束拖拽 ——
# =========================
func begin_drag(mode: StringName = &"single") -> void:
	if _dragging or not _interaction_enabled:
		return
	_dragging = true
	_drag_mode = mode
	_pre_drag_global = global_position

	# 视觉
	if pickup_scale > 0.0 and absf(pickup_scale - 1.0) > 0.0001:
		scale = _orig_scale * Vector2(pickup_scale, pickup_scale)
	if drag_z >= 0:
		z_index = drag_z

	# ✅ 用全局鼠标计算偏移，避免“飞远”
	var mouse_g: Vector2 = get_global_mouse_position()
	_drag_offset = mouse_g - global_position

	emit_signal("drag_started", self)

func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	_dragging = false
	emit_signal("drag_ended", self)

	# 恢复视觉
	_restore_visual()

	# ✅ 单卡落子：把“卡的全局位置”传给 Grid（或传全局鼠标也行）
	if _drag_mode == &"single" and _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_card"):
		var ok := bool(_grid.call("drop_card", self, global_position))
		if not ok:
		# 回到原位（有动画就用动画）
			if _anim != null and _anim.has_method("tween_to"):
				_anim.call("tween_to", _pre_drag_global, 0.15, 1.0, z_index)
			else:
				global_position = _pre_drag_global

func cancel_drag() -> void:
	if _dragging:
		_dragging = false
		emit_signal("drag_ended", self)
	_restore_visual()

# =========================
# —— 公共：堆叠归属 & 命中开关 ——
# =========================
func set_pile(pile: Node) -> void:
	_pile_ref = pile
	_in_pile = is_instance_valid(pile)

func is_in_pile() -> bool:
	return _in_pile

func get_pile() -> Node:
	return _pile_ref

func set_interaction_enabled(enabled: bool) -> void:
	_interaction_enabled = enabled
	if not enabled and _dragging:
		cancel_drag()

func set_hit_areas(full_enabled: bool, header_enabled: bool) -> void:
	if _hit_full != null:
		_hit_full.monitoring = full_enabled
		_hit_full.input_pickable = full_enabled
		_hit_full.visible = full_enabled
	if _hit_header != null:
		_hit_header.monitoring = header_enabled
		_hit_header.input_pickable = header_enabled
		_hit_header.visible = header_enabled

# =========================
# —— 内部：位置/视觉/动画 ——
# =========================
func _follow_to(target_global: Vector2) -> void:
	if _anim != null and _anim.has_method("follow_immediate"):
		_anim.call("follow_immediate", self, target_global)
	else:
		global_position = target_global

func _restore_visual() -> void:
	z_index = _orig_z
	scale = _orig_scale

# =========================
# —— 辅助 ——
# =========================
func get_dragging() -> bool:
	return _dragging

func get_drag_mode() -> StringName:
	return _drag_mode
