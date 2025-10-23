extends Node2D
class_name PileManager

# ========= 可在 Inspector 调参 =========
@export var grid_manager_path: NodePath
@export var visible_ratio: float = 0.15
@export var card_pixel_size: Vector2 = Vector2(47, 64)
@export var z_base: int = 100
@export var per_layer_z: int = 1
@export var pickup_scale: float = 1.06
@export var drag_z: int = 9000
@export var pile_scene: PackedScene
@export var auto_fit_header: bool = true
@export var anim_defaults_path: NodePath   # 可选：指向一个 CardAnimation 节点作为模板

# ========= 信号（标记已用） =========
@warning_ignore("UNUSED_SIGNAL")
signal pile_changed(pile: PileManager)
@warning_ignore("UNUSED_SIGNAL")
signal drag_started(pile: PileManager)
@warning_ignore("UNUSED_SIGNAL")
signal drag_moved(pile: PileManager, mouse_global: Vector2)
@warning_ignore("UNUSED_SIGNAL")
signal drag_ended(pile: PileManager)

# ========= 运行时状态 =========
var _grid: Node = null
var _cards: Array[Card] = []            # 顺序：底 -> 顶
var _dragging: bool = false
var _drag_mode: StringName = &"pile"    # "pile"|"substack"
var _drag_offset: Vector2 = Vector2.ZERO
var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _suspend_anim: bool = false

# 为回弹加动画：记录拖拽前位置
var _pre_drag_global: Vector2 = Vector2.ZERO

# 兼容字段
var _pre_drag_parent: Node = null
var _pre_drag_sibling_idx: int = -1

# 回弹 tween（避免叠加）
var _rebound_tween: Tween = null

func _ready() -> void:
	_grid = get_node_or_null(grid_manager_path)
	if _grid == null and get_tree().current_scene != null:
		_grid = get_tree().current_scene.get_node_or_null(^"GridManager")
	if _grid == null:
		_grid = get_tree().get_root().find_child("GridManager", true, false)

	_orig_scale = scale
	_orig_z = z_index
	set_process(true)
	set_process_unhandled_input(true)

# ---------- 基础接口 ----------
func add_card(card: Card) -> void:
	var gp: Vector2 = card.global_position
	if card.get_parent() != null:
		card.get_parent().remove_child(card)
	add_child(card)
	card.global_position = gp
	card.set_pile(self)
	_cards.append(card)
	_reflow_after_change()

func add_cards(cards: Array[Card]) -> void:
	for c: Card in cards:
		var gp: Vector2 = c.global_position
		if c.get_parent() != null:
			c.get_parent().remove_child(c)
		add_child(c)
		c.global_position = gp
		c.set_pile(self)
		_cards.append(c)
	_reflow_after_change()

func get_cards() -> Array[Card]:
	return _cards.duplicate()

func index_of_card(card: Card) -> int:
	return _cards.find(card)

func extract_from(index: int) -> Array[Card]:
	if index < 0 or index >= _cards.size():
		return []
	var extracted: Array[Card] = []
	while _cards.size() > index:
		extracted.append(_cards.pop_back())
	extracted.reverse()
	_reflow_after_change()
	return extracted

# ---------- 视觉重排 ----------
func reflow_visuals() -> void:
	var step: float = card_pixel_size.y * visible_ratio
	for i in range(_cards.size()):
		var card: Card = _cards[i]
		var target_local: Vector2 = Vector2(0.0, float(i) * step)
		_set_card_layer(card, z_base + i * per_layer_z)
		_move_card(card, target_local)

		var full_enabled: bool = (i == _cards.size() - 1)
		var header_enabled: bool = not full_enabled
		card.set_hit_areas(full_enabled, header_enabled)

		if auto_fit_header and header_enabled:
			_fit_header_hit_area(card, step)

	emit_signal("pile_changed", self)
	_update_blocked_cells()  # 重排后刷新禁用格

func _reflow_after_change() -> void:
	reflow_visuals()

func _set_card_layer(card: Card, z: int) -> void:
	card.z_index = z

func _move_card(card: Card, local_pos: Vector2) -> void:
	var target_global: Vector2 = to_global(local_pos)
	if _suspend_anim or _dragging:
		card.global_position = target_global
		return
	var anim := _ensure_anim_on(card)
	# 使用 -1.0 表示尊重 CardAnimation 的 Inspector 默认时长与不改缩放
	anim.tween_to(target_global, -1.0, -1.0, card.z_index)


# 牌眉命中区尺寸/位置调整
func _fit_header_hit_area(card: Card, strip_h: float) -> void:
	var area: Area2D = card.get_node_or_null(^"hit_header") as Area2D
	if area == null:
		return
	var cs: CollisionShape2D = area.get_node_or_null(^"CollisionShape2D") as CollisionShape2D
	if cs == null:
		return
	var rect := cs.shape as RectangleShape2D
	if rect == null:
		return
	rect.extents = Vector2(card_pixel_size.x * 0.5, maxf(strip_h, 1.0) * 0.5)
	cs.position = Vector2(0.0, -card_pixel_size.y * 0.5 + strip_h * 0.5)

# ---------- 拖拽入口 ----------
func request_drag(from_card: Card, mode: String, start_index: int = -1) -> void:
	if _dragging:
		return
	match mode:
		"pile":
			_begin_drag_pile()
		"substack":
			_begin_drag_substack(from_card, start_index)
		_:
			_begin_drag_pile()

func _begin_drag_pile() -> void:
	# 中断可能存在的回弹
	_kill_rebound()

	_dragging = true
	_suspend_anim = true
	_drag_mode = &"pile"
	_pre_drag_global = global_position

	# 拿起前：解封本堆禁用的所有格
	_release_all_blocked_cells()

	if pickup_scale > 0.0 and absf(pickup_scale - 1.0) > 0.0001:
		scale = _orig_scale * Vector2(pickup_scale, pickup_scale)

	z_as_relative = false
	if drag_z >= 0:
		var z_cap := RenderingServer.CANVAS_ITEM_Z_MAX - 1
		z_index = min(drag_z, z_cap)

	_drag_offset = get_global_mouse_position() - global_position
	_set_all_cards_interaction(false)
	emit_signal("drag_started", self)

func _begin_drag_substack(from_card: Card, start_index: int) -> void:
	var idx: int = start_index
	if idx < 0:
		idx = index_of_card(from_card)
	if idx < 0:
		return

	var subset: Array[Card] = extract_from(idx)
	var origin: Vector2 = from_card.global_position
	var new_pile: PileManager = _spawn_new_pile_for_drag(subset, origin)
	if new_pile == null:
		add_cards(subset)
		return

	new_pile._begin_drag_pile()
	_reflow_after_change()

func _spawn_new_pile_for_drag(cards_to_attach: Array[Card], origin_global: Vector2) -> PileManager:
	var parent_node: Node = get_parent()
	if parent_node == null:
		parent_node = get_tree().get_current_scene()
	if parent_node == null:
		parent_node = get_tree().get_root()

	var pile_node: Node2D = null
	if pile_scene != null:
		pile_node = pile_scene.instantiate() as Node2D
	else:
		pile_node = Node2D.new()
		pile_node.set_script(load(get_script().resource_path))
	parent_node.add_child(pile_node)
	pile_node.global_position = origin_global

	var new_mgr: PileManager = pile_node as PileManager
	# 继承参数
	new_mgr.grid_manager_path = grid_manager_path
	new_mgr.visible_ratio = visible_ratio
	new_mgr.card_pixel_size = card_pixel_size
	new_mgr.z_base = z_base
	new_mgr.per_layer_z = per_layer_z
	new_mgr.pickup_scale = pickup_scale
	new_mgr.drag_z = drag_z
	new_mgr.pile_scene = pile_scene
	new_mgr.auto_fit_header = auto_fit_header

	new_mgr._suspend_anim = true
	new_mgr.add_cards(cards_to_attach)

	return new_mgr

# ---------- 跟随/结束 ----------
func _process(_delta: float) -> void:
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()
		global_position = mouse_g - _drag_offset
		emit_signal("drag_moved", self, mouse_g)

func _unhandled_input(event: InputEvent) -> void:
	if _dragging and event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_end_drag_and_drop()

func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	_dragging = false
	emit_signal("drag_ended", self)

	_suspend_anim = false
	scale = _orig_scale

	var restored := false

	# 若没有 grid 或 drop 失败 → 回弹
	var need_rebound := true
	if _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_pile"):
		var ok := bool(_grid.call("drop_pile", self, global_position))
		need_rebound = not ok

	if need_rebound:
		_rebound_to_pre_drag()
		restored = true
	else:
		# 成功放置：恢复交互、清理
		_set_all_cards_interaction(true)
		_pre_drag_parent = null
		_pre_drag_sibling_idx = -1

	if not restored:
		# 成功落位后，刷新禁用格（grid 内部可能已经做了，这里兜底）
		if has_method("_update_blocked_cells"):
			_update_blocked_cells()

# ---------- 回弹动画 ----------
func _rebound_to_pre_drag() -> void:
	_kill_rebound() # 仅保留“防重复”语义，不再手动建 tween
	_set_all_cards_interaction(true)

	# 回弹前先恢复 z，避免长时间遮挡
	z_index = _orig_z

	var anim := _self_anim()
	# 用一次性连接，避免重复回调（无需 disconnect_all）
	anim.on_finished.connect(func ():
		# 顶牌做一个轻微 bump，反馈“放置无效”
		if _cards.size() > 0:
			var top := _cards[_cards.size() - 1]
			var top_anim := _ensure_anim_on(top)
			top_anim.bump()
		# 回弹后刷新禁用格状态
		if has_method("_update_blocked_cells"):
			_update_blocked_cells()
	, CONNECT_ONE_SHOT)

	# 用统一的 rebound_to（可用默认 0.16 或交给 CardAnimation Inspector）
	anim.rebound_to(_pre_drag_global, 0.16)


func _kill_rebound() -> void:
	if _rebound_tween != null and is_instance_valid(_rebound_tween):
		_rebound_tween.kill()
	_rebound_tween = null

func _set_all_cards_interaction(enabled: bool) -> void:
	for c: Card in _cards:
		c.set_interaction_enabled(enabled)

# ==========================
# —— 自动禁用覆盖格 ——
# ==========================
var _blocked_cells: Array[int] = []

func _update_blocked_cells() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return
	_unblock_previous_cells()

	var cell: int = _grid._world_to_cell_idx(global_position)
	if cell == -1:
		return

	var pile_height: float = card_pixel_size.y * visible_ratio * float(max(_cards.size() - 1, 0))
	if pile_height <= 0.0:
		return

	var step_size: Vector2 = _grid._step_size()
	var rows_covered: int = int(ceil(pile_height / step_size.y))

	var to_block: Array[int] = []
	var rc: Vector2i = _grid._rc(cell)
	for i: int in range(1, rows_covered + 1):
		var below_r: int = rc.y + i
		if below_r >= _grid.rows:
			break
		var below_cell: int = _grid._idx(rc.x, below_r)
		to_block.append(below_cell)

	for b: int in to_block:
		if _grid.get_pile(b) != null:
			_grid.displace_if_needed(self, b, to_block)

	for b2: int in to_block:
		if not _grid.is_cell_forbidden(b2):
			_grid.block_cell(b2)
			_blocked_cells.append(b2)

func _unblock_previous_cells() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return
	for c in _blocked_cells:
		if _grid.is_cell_forbidden(c):
			_grid.unblock_cell(c)
	_blocked_cells.clear()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_unblock_previous_cells()

func owns_blocked_cell(cell: int) -> bool:
	return _blocked_cells.has(cell)

func _release_all_blocked_cells() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return
	for c: int in _blocked_cells:
		if _grid.is_cell_forbidden(c):
			_grid.unblock_cell(c)
	_blocked_cells.clear()

func _restore_pile_parent_if_needed() -> void:
	pass
# ===== PileManager.gd：替换 _ensure_anim_on =====
func _ensure_anim_on(node: Node2D) -> CardAnimation:
	var anim := node.get_node_or_null(^"CardAnimation") as CardAnimation
	if anim == null:
		anim = CardAnimation.new()
		anim.name = "CardAnimation"
		node.add_child(anim)
		var tmpl := _anim_defaults()
		if tmpl != null:
			_copy_anim_defaults(anim, tmpl)
	return anim


func _self_anim() -> CardAnimation:
	return _ensure_anim_on(self)

# ===== PileManager.gd：新增：动画模板工具 =====
func _anim_defaults() -> CardAnimation:
	if anim_defaults_path == NodePath():
		return null
	return get_node_or_null(anim_defaults_path) as CardAnimation

func _copy_anim_defaults(dst: CardAnimation, src: CardAnimation) -> void:
	if dst == null or src == null:
		return
	dst.default_duration = src.default_duration
	dst.default_trans    = src.default_trans
	dst.default_ease     = src.default_ease
	dst.bump_offset      = src.bump_offset
	dst.bump_up_ratio    = src.bump_up_ratio
	dst.bump_total       = src.bump_total
