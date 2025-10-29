extends Node2D
class_name Card

# =========================
# —— 可在 Inspector 调参 ——
# =========================
@export var grid_manager_path: NodePath
@export var sprite_path: NodePath = ^"Sprite2D"
@export var hit_full_path: NodePath = ^"hit_full"
@export var hit_header_path: NodePath = ^"hit_header"

@export var pickup_scale: float = 1.06
@export var drag_z: int = 9000

# ——（新增）点击判定与调试 —— 
@export_range(0.0, 20.0, 0.5) var click_px_threshold: float = 6.0   # 判定“点击”的最大位移（像素）
@export var click_ms_threshold: int = 220                            # 判定“点击”的最大耗时（毫秒）
@export var click_flash_scale: float = 1.06                          # 点击时轻微闪烁的倍率
@export var debug_log_clicks: bool = true                            # 是否打印点击日志
@export var relay_node_name: String = "ClickDebugRelay"              # 2D 根调试中继节点名（可留默认）

# =========================
# —— 信号（标记已用） ——
# =========================
@warning_ignore("UNUSED_SIGNAL")
signal drag_started(card: Card)
@warning_ignore("UNUSED_SIGNAL")
signal drag_moved(card: Card, mouse_global: Vector2)
@warning_ignore("UNUSED_SIGNAL")
signal drag_ended(card: Card)

# ——（新增）点击完成信号（可选对外用）——
@warning_ignore("UNUSED_SIGNAL")
signal clicked(card: Card, click_id: int)

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
var _drag_offset: Vector2 = Vector2.ZERO

var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _interaction_enabled: bool = true
var _pre_drag_global: Vector2 = Vector2.ZERO
var _orig_zrel: bool = true

# 堆信息
var _in_pile: bool = false
var _pile_ref: Node = null

# ——（新增）点击判定运行期状态 —— 
var _press_pos_screen: Vector2 = Vector2.ZERO
var _press_time_ms: int = 0
var _pressing: bool = false
var _last_bridge_click_id: int = 0   # 若装了 ClickDebugRelay，可在按下时尝试同步

# =========================
# —— 生命周期 ——
# =========================
func _ready() -> void:
	_grid = get_node_or_null(grid_manager_path)
	if _grid == null and get_tree().current_scene != null:
		_grid = get_tree().current_scene.get_node_or_null(^"GridManager")
	if _grid == null:
		_grid = get_tree().get_root().find_child("GridManager", true, false)
	if _grid == null:
		_grid = get_node_or_null(^"/root/Grid")

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
	_ensure_anim_on_self()

	_orig_scale = scale
	_orig_z = z_index
	_orig_zrel = z_as_relative

	if _hit_full != null:
		_hit_full.input_event.connect(_on_hit_full_input)
	if _hit_header != null:
		_hit_header.input_event.connect(_on_hit_header_input)

	set_process(true)
	set_process_unhandled_input(true)

# =========================
# —— 拖拽跟随（全局） ——
# =========================
func _process(_delta: float) -> void:
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()
		var target: Vector2 = mouse_g - _drag_offset
		_follow_to(target)
		emit_signal("drag_moved", self, mouse_g)

func _unhandled_input(event: InputEvent) -> void:
	if _dragging and event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_end_drag_and_drop()
		# ===== 追加：点击判定 =====
		if _pressing:
			_pressing = false
			var dt := Time.get_ticks_msec() - _press_time_ms
			var dx := (get_viewport().get_mouse_position() - _press_pos_screen).length()
			if dt <= click_ms_threshold and dx <= click_px_threshold:
				emit_signal("clicked", self, _last_bridge_click_id)
				if debug_log_clicks:
					print("[CARD] CLICKED card=%s id=%d dt=%d dx=%.1f" % [name, _last_bridge_click_id, dt, dx])
				# 通知 2D 根的中继（若存在）
				var relay := get_tree().get_root().find_child(relay_node_name, true, false)
				if relay and relay.has_method("notify_card_clicked"):
					relay.call("notify_card_clicked", name, _last_bridge_click_id)

# =========================
# —— 命中区事件 ——
# =========================
func _on_hit_full_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not _interaction_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# ===== 追加：记录按下用于点击判定 + 尝试同步 click_id =====
		_pressing = true
		_press_pos_screen = get_viewport().get_mouse_position()
		_press_time_ms = Time.get_ticks_msec()
		_try_sync_click_id()
		# ===== 原逻辑：整面按下开始拖拽 =====
		_on_pressed_full()

func _on_hit_header_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not _interaction_enabled:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# ===== 追加：记录按下用于点击判定 + 尝试同步 click_id =====
		_pressing = true
		_press_pos_screen = get_viewport().get_mouse_position()
		_press_time_ms = Time.get_ticks_msec()
		_try_sync_click_id()
		# ===== 原逻辑：点牌眉拖子栈或单卡 =====
		_on_pressed_header()

func _on_pressed_full() -> void:
	if not _interaction_enabled:
		return

	# 在 pile 中：若点的是顶牌整面 → 抽离成单卡拖拽
	if _in_pile and is_instance_valid(_pile_ref):
		var top_index := -1
		if _pile_ref.has_method("get_cards"):
			var cards: Array = _pile_ref.call("get_cards")
			if cards.size() > 0:
				top_index = cards.size() - 1
		var my_index := -1
		if _pile_ref.has_method("index_of_card"):
			my_index = int(_pile_ref.call("index_of_card", self))

		if my_index == top_index:
			if _pile_ref.has_method("extract_from"):
				_pile_ref.call("extract_from", my_index)
			_detach_from_pile_to_world()
			begin_drag(&"single")
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

	# 抬高到最上层（绝对 z）
	z_as_relative = false
	if drag_z >= 0:
		var z_cap := RenderingServer.CANVAS_ITEM_Z_MAX - 1
		z_index = min(drag_z, z_cap)

	var mouse_g: Vector2 = get_global_mouse_position()
	_drag_offset = mouse_g - global_position

	emit_signal("drag_started", self)

func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	_dragging = false
	emit_signal("drag_ended", self)

	var accepted := false

	# 单卡落子：交给 Grid；失败则“回弹 + bump”
	if _drag_mode == &"single" and _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_card"):
		accepted = bool(_grid.call("drop_card", self, global_position))
		if not accepted:
			# 回弹
			if _anim != null and _anim.has_method("tween_to"):
				_anim.call("tween_to", _pre_drag_global, 0.16, 1.0, _orig_z)
				if _anim.has_method("bump"):
					await get_tree().create_timer(0.17).timeout
					_anim.call("bump")
			else:
				global_position = _pre_drag_global

	_restore_visual_post_drop(accepted)

func cancel_drag() -> void:
	if _dragging:
		_dragging = false
		emit_signal("drag_ended", self)
	# 取消视为未被接收
	_restore_visual_post_drop(false)

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

# 关键改动：根据“是否已进入 pile 且被接收”决定是否恢复 z
func _restore_visual_post_drop(accepted: bool) -> void:
	# 无论如何都把缩放恢复
	scale = _orig_scale

	if accepted and _in_pile:
		# ✅ 已进入某个 pile：层级交给 PileManager 管
		# 只需保证相对 z 打开，让 reflow_visuals() 的 per-layer z 生效
		z_as_relative = true
		# 不再改 z_index（避免覆盖 PileManager 刚设的层）
	else:
		# ❌ 未被接收（或不在 pile 中）：恢复成拖拽前的独立层级
		z_index = _orig_z
		z_as_relative = _orig_zrel

# =========================
# —— 辅助 ——
# =========================
func get_dragging() -> bool:
	return _dragging

func get_drag_mode() -> StringName:
	return _drag_mode

func _detach_from_pile_to_world() -> void:
	if not _in_pile or not is_instance_valid(_pile_ref):
		return
	var gp: Vector2 = global_position
	var parent: Node = _pile_ref.get_parent()
	if parent == null:
		parent = get_tree().current_scene
	if parent == null:
		parent = get_tree().get_root()
	_pile_ref.remove_child(self)
	parent.add_child(self)
	global_position = gp
	set_pile(null)

# ===== Card.gd：新增：确保自身有 CardAnimation =====
func _ensure_anim_on_self() -> CardAnimation:
	if _anim != null and is_instance_valid(_anim):
		return _anim
	var a := get_node_or_null(^"CardAnimation") as CardAnimation
	if a == null:
		a = CardAnimation.new()
		a.name = "CardAnimation"
		add_child(a)
	_anim = a
	return a

# =====（新增）帮助函数：尝试从 2D 根中继同步 click_id（可选）=====
func _try_sync_click_id() -> void:
	_last_bridge_click_id = 0
	var relay := get_tree().get_root().find_child(relay_node_name, true, false)
	if relay and relay.has_method("get_last_bridge_click_id"):
		_last_bridge_click_id = int(relay.call("get_last_bridge_click_id"))
