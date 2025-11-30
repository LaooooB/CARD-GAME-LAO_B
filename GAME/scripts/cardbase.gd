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
@export var drag_z: int = 4094

# —— 拖拽顶层容器（一次赋值，反复使用）——
@export var drag_layer_path: NodePath = ^"/root/DragLayer"	# 建议放一个 CanvasLayer 作为拖拽顶层

# ——（新增）卡内 UI 相对层级（按顺序 0,1,2… 设置）——
# 写节点“名字”（不是路径）。会递归查找同名 CanvasItem 并统一设置相对 z。
@export var internal_z_names: Array[String] = ["Sprite2D", "NameLabel"]	# 需要就增删，顺序决定 z

# —— 点击判定与调试 ——
@export_range(0.0, 20.0, 0.5) var click_px_threshold: float = 6.0
@export var click_ms_threshold: int = 220
@export var click_flash_scale: float = 1.06
@export var debug_log_clicks: bool = true
@export var relay_node_name: String = "ClickDebugRelay"

# =========================
# —— 信号（标记已用） —— 
# =========================
@warning_ignore("UNUSED_SIGNAL")
signal drag_started(card: Card)
@warning_ignore("UNUSED_SIGNAL")
signal drag_moved(card: Card, mouse_global: Vector2)
@warning_ignore("UNUSED_SIGNAL")
signal drag_ended(card: Card)
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
var _drag_mode: StringName = &"single"	# "single"|"pile"|"substack"
var _drag_offset: Vector2 = Vector2.ZERO

var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _orig_zrel: bool = true
var _interaction_enabled: bool = true
var _pre_drag_global: Vector2 = Vector2.ZERO

# —— 拖拽换父缓存 —— 
var _drag_layer: Node = null
var _pre_drag_parent: Node = null
var _pre_drag_sibling_idx: int = -1

# 堆信息
var _in_pile: bool = false
var _pile_ref: Node = null

# —— 点击判定运行期状态 —— 
var _press_pos_screen: Vector2 = Vector2.ZERO
var _press_time_ms: int = 0
var _pressing: bool = false
var _last_bridge_click_id: int = 0

var _scale_tw: Tween

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

	# 默认不跑帧逻辑；拖拽时再打开
	set_process(false)
	set_process_unhandled_input(true)

	# 拖拽顶层容器
	_drag_layer = get_node_or_null(drag_layer_path)

	# 初始化一次卡内相对层级
	_apply_internal_z_order()

# =========================
# —— 拖拽跟随 —— 
# =========================
func _process(_dt: float) -> void:
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()
		var target: Vector2 = mouse_g - _drag_offset
		_follow_to(target)
		emit_signal("drag_moved", self, mouse_g)

func _unhandled_input(event: InputEvent) -> void:
	if _dragging and event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_end_drag_and_drop()

	# —— 点击判定 —— 
	if _pressing:
		_pressing = false
		var dt := Time.get_ticks_msec() - _press_time_ms
		var dx := (get_viewport().get_mouse_position() - _press_pos_screen).length()
		if dt <= click_ms_threshold and dx <= click_px_threshold:
			emit_signal("clicked", self, _last_bridge_click_id)
			if debug_log_clicks:
				print("[CARD] CLICKED card=%s id=%d dt=%d dx=%.1f" % [name, _last_bridge_click_id, dt, dx])
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
		_pressing = true
		_press_pos_screen = get_viewport().get_mouse_position()
		_press_time_ms = Time.get_ticks_msec()
		_try_sync_click_id()
		_on_pressed_full()

func _on_hit_header_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if not _interaction_enabled:
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_pressing = true
		_press_pos_screen = get_viewport().get_mouse_position()
		_press_time_ms = Time.get_ticks_msec()
		_try_sync_click_id()
		_on_pressed_header()

func _on_pressed_full() -> void:
	if not _interaction_enabled:
		return

	# 在 pile 中：若点顶牌整面 → 抽离成单卡拖拽
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

	# ★ 新增：通知 JobSlotManager，这张卡已从任何 job 槽中被拿起
	var job_slot_manager := get_node_or_null(^"/root/JobSlotManager")
	if job_slot_manager != null:
		job_slot_manager.call("on_card_begin_drag", self)

	# 视觉放大（用 tween，避免与 hover 收回的直接赋值互相抢写）
	if pickup_scale > 0.0 and absf(pickup_scale - 1.0) > 0.0001:
		_tween_scale_to(_orig_scale * Vector2(pickup_scale, pickup_scale), 0.10, Tween.TRANS_QUAD, Tween.EASE_OUT)

	# —— 一次性换父到拖拽顶层 —— 
	_pre_drag_parent = get_parent()
	_pre_drag_sibling_idx = _pre_drag_parent.get_children().find(self) if _pre_drag_parent else -1

	if is_instance_valid(_drag_layer):
		var gp := global_position
		reparent(_drag_layer)
		global_position = gp
	else:
		# 兜底（没有 DragLayer 时）——只做一次安全抬高
		z_as_relative = false
		var z_cap: int = RenderingServer.CANVAS_ITEM_Z_MAX - 1	# 通常 4095
		var headroom: int = 3	# 0=卡面, 1=高亮, 2=名字
		var safe_parent_top: int = max(0, z_cap - headroom)	# 父最多 4092
		if drag_z >= 0:
			z_index = clamp(drag_z, 0, safe_parent_top)

	# —— 应用卡内相对层级（基于 internal_z_names 的顺序） —— 
	_apply_internal_z_order()

	# 拖拽偏移
	var mouse_g: Vector2 = get_global_mouse_position()
	_drag_offset = mouse_g - global_position

	# 仅拖拽时跑 _process
	set_process(true)

	# 把自己加入“正在拖拽”组
	if not is_in_group("dragging_cards"):
		add_to_group("dragging_cards", true)

	# 用 deferred 广播
	get_tree().call_group_flags(SceneTree.GROUP_CALL_DEFERRED, "card_controllers", "on_global_drag_started")

	emit_signal(&"drag_started", self)

func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	_dragging = false
	emit_signal("drag_ended", self)

	# ★ 新增：优先尝试丢进 WorkUnit 的 job 槽
	var job_slot_manager := get_node_or_null(^"/root/JobSlotManager")
	if job_slot_manager != null:
		var snapped: bool = bool(job_slot_manager.call("try_snap_card", self, global_position))
		if snapped:
			# 成功 snap 到某个 workunit 的槽里：
			# 不再回原父，而是维持 WorkUnitBase._try_snap_card 已经设置好的 parent/position
			_restore_visual_post_drop(true)
			set_process(false)
			if is_in_group("dragging_cards"):
				remove_from_group("dragging_cards")
			return

	var accepted := false

	# 单卡落子：交给 Grid；失败则“回弹 + bump”
	if _drag_mode == &"single" and _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_card"):
		accepted = bool(_grid.call("drop_card", self, global_position))

	if not accepted:
		if _anim != null and _anim.has_method("tween_to"):
			_anim.call("tween_to", _pre_drag_global, 0.16, 1.0, _orig_z)
			if _anim.has_method("bump"):
				await get_tree().create_timer(0.17).timeout
				_anim.call("bump")
		else:
			global_position = _pre_drag_global

	# 放回原父
	_restore_parent_if_needed()
	_restore_visual_post_drop(accepted)

	# 拖拽结束关闭 _process
	set_process(false)
	if is_in_group("dragging_cards"):
		remove_from_group("dragging_cards")

func cancel_drag() -> void:
	if _dragging:
		_dragging = false
		emit_signal("drag_ended", self)
		# 取消视为未被接收
		_restore_parent_if_needed()
		_restore_visual_post_drop(false)
		set_process(false)
		if is_in_group("dragging_cards"):
			remove_from_group("dragging_cards")

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

# 落子后视觉恢复
func _restore_visual_post_drop(accepted: bool) -> void:
	# 用 Tween 缩回，而不是直接 scale = _orig_scale（会掐死动画）
	if not scale.is_equal_approx(_orig_scale):
		var tw := create_tween()
		tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(self, "scale", _orig_scale, 0.12)

	if accepted and _in_pile:
		# 已进入某个 pile：层级交给 PileManager 管
		z_as_relative = true
	else:
		# 未被接收或不在 pile 中：恢复原层级
		z_index = _orig_z
		z_as_relative = _orig_zrel

# —— 把节点放回拖拽前父节点/兄弟序号 —— 
func _restore_parent_if_needed() -> void:
	if _pre_drag_parent == null or not is_instance_valid(_pre_drag_parent):
		_pre_drag_parent = null
		_pre_drag_sibling_idx = -1
		return

	if get_parent() != _pre_drag_parent:
		var gp := global_position
		reparent(_pre_drag_parent)
		if _pre_drag_sibling_idx >= 0 and _pre_drag_sibling_idx < _pre_drag_parent.get_child_count():
			_pre_drag_parent.move_child(self, _pre_drag_sibling_idx)
		global_position = gp

	_pre_drag_parent = null
	_pre_drag_sibling_idx = -1

# =========================
# —— 辅助 —— 
# =========================
func get_dragging() -> bool:
	return _dragging

func get_drag_mode() -> StringName:
	return _drag_mode

# —— 解析“世界层”父节点：优先 GridManager/Cards -> CardRoot -> GridManager 本体 —— 
func _resolve_world_card_parent() -> Node:
	if _grid != null and is_instance_valid(_grid):
		var n := (_grid as Node)
		var cards := n.get_node_or_null(^"Cards")
		if cards != null:
			return cards
		var card_root := n.get_node_or_null(^"CardRoot")
		if card_root != null:
			return card_root
		return n

	# 兜底：当前场景 / 根
	if get_tree().current_scene != null:
		return get_tree().current_scene
	return get_tree().get_root()

# —— 安全地把卡从 pile 中摘出来放回世界层（一次 reparent，保持全局变换）—— 
func _detach_from_pile_to_world() -> void:
	if not _in_pile or not is_instance_valid(_pile_ref):
		return

	var target := _resolve_world_card_parent()
	if target == null or not is_instance_valid(target):
		return

	if get_parent() == target:
		# 已经在世界层，无需操作
		set_pile(null)
		return

	var gp := global_position
	reparent(target, true)
	global_position = gp
	set_pile(null)

# ===== 确保自身有 CardAnimation =====
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

# =====（可选）从 2D 根中继同步 click_id =====
func _try_sync_click_id() -> void:
	_last_bridge_click_id = 0
	var relay := get_tree().get_root().find_child(relay_node_name, true, false)
	if relay and relay.has_method("get_last_bridge_click_id"):
		_last_bridge_click_id = int(relay.call("get_last_bridge_click_id"))

# =========================
# —— 按列表名应用内部 UI 相对层级 —— 
# =========================
func _apply_internal_z_order() -> void:
	# 例：["Sprite2D","Glow","NameLabel"] -> 分别设置 z=0,1,2
	var z := 0
	for n in internal_z_names:
		if n.is_empty():
			continue
		# 递归匹配名字为 n 的 CanvasItem（可同时命中多个同名节点）
		var matches: Array = find_children(n, "CanvasItem", true, false)
		var any := false
		for node in matches:
			if node.name == n:
				var ci := node as CanvasItem
				if ci != null:
					ci.z_as_relative = true
					ci.z_index = z
					ci.show_behind_parent = false
					any = true
		if any:
			z += 1	# 只有在至少命中一个时才推进层级

func _tween_scale_to(target: Vector2, dur: float = 0.12, trans := Tween.TRANS_QUAD, ease := Tween.EASE_OUT) -> void:
	if _scale_tw and _scale_tw.is_running():
		_scale_tw.kill()
	_scale_tw = create_tween()
	_scale_tw.set_trans(trans).set_ease(ease)
	_scale_tw.tween_property(self, "scale", target, dur)
