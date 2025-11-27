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
var _cards: Array[Node2D] = []           # 顺序：底 -> 顶；仅保存有效 Node2D（Card）
var _dragging: bool = false
var _drag_mode: StringName = &"pile"     # "pile"|"substack"
var _drag_offset: Vector2 = Vector2.ZERO
var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _suspend_anim: bool = false
var _current_pile_hover_start_idx: int = -1

# 为回弹加动画：记录拖拽前位置
var _pre_drag_global: Vector2 = Vector2.ZERO

# 兼容字段
var _pre_drag_parent: Node = null
var _pre_drag_sibling_idx: int = -1

# 回弹 tween（避免叠加）
var _rebound_tween: Tween = null

# —— 子堆回滚需要记录源堆与插回位置 —— 
var _source_pile_ref: WeakRef = null     # 原堆弱引用（防止悬空）
var _source_insert_index: int = -1       # 原始起始插入索引（extract_from时的index）

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

# ================= 工具：安全判断与清理 =================
func _is_valid_obj(o: Variant) -> bool:
	return o != null and typeof(o) == TYPE_OBJECT and is_instance_valid(o)

func _cards_clean() -> void:
	var cleaned: Array[Node2D] = []
	for v in _cards:
		if _is_valid_obj(v):
			cleaned.append(v as Node2D)
	_cards = cleaned

func _dup_cards_clean() -> Array:
	_cards_clean()
	return _cards.duplicate()

# ================= 基础接口 =================
# —— 安全 add：过滤非法对象、保持全局位置、统一入栈与重排 —— 
func add_card(card: Node2D) -> void:
	if not _is_valid_obj(card):
		return

	var gp: Vector2 = card.global_position
	var parent := card.get_parent()
	if parent != null:
		parent.remove_child(card)
	add_child(card)
	card.global_position = gp

	if card.has_method("set_pile"):
		card.call("set_pile", self)

	if _cards.find(card) == -1:
		_cards.append(card)

	_reflow_after_change()

func add_cards(cards: Array) -> void:
	if cards == null or cards.is_empty():
		return
	for c in cards:
		if not _is_valid_obj(c):
			continue
		var n2d: Node2D = c as Node2D
		if n2d == null:
			continue
		var gp: Vector2 = n2d.global_position
		var p := n2d.get_parent()
		if p != null:
			p.remove_child(n2d)
		add_child(n2d)
		n2d.global_position = gp
		if n2d.has_method("set_pile"):
			n2d.call("set_pile", self)
		if _cards.find(n2d) == -1:
			_cards.append(n2d)
	_reflow_after_change()

func remove_card(card: Node2D) -> void:
	if not _is_valid_obj(card):
		# 已释放/无效：从数组剔除影子引用
		_cards = _dup_cards_clean()
		return
	var i: int = _cards.find(card)
	if i >= 0:
		_cards.remove_at(i)
	if card.has_method("set_pile"):
		card.call("set_pile", null)
	reflow_visuals()

func get_cards() -> Array:
	return _dup_cards_clean()

func index_of_card(card: Node2D) -> int:
	_cards_clean()
	return _cards.find(card)

func extract_from(index: int) -> Array:
	_cards_clean()
	if index < 0 or index >= _cards.size():
		return []
	var extracted: Array = []
	while _cards.size() > index:
		extracted.append(_cards.pop_back())
	extracted.reverse()
	_reflow_after_change()
	return extracted

# ================= 视觉重排 =================
func reflow_visuals() -> void:
	_cards_clean()
	var step: float = card_pixel_size.y * visible_ratio
	for i in range(_cards.size()):
		var card_n: Node2D = _cards[i]
		if not _is_valid_obj(card_n):
			continue
		var target_local: Vector2 = Vector2(0.0, float(i) * step)
		_set_card_layer(card_n, z_base + i * per_layer_z)
		_move_card(card_n, target_local)

		# 命中区 & 头/全身切换（若有这些方法）
		var header_enabled: bool = false
		if card_n.has_method("set_hit_areas"):
			var full_enabled: bool = (i == _cards.size() - 1)
			header_enabled = not full_enabled
			card_n.call("set_hit_areas", full_enabled, header_enabled)
			if auto_fit_header and header_enabled:
				_fit_header_hit_area(card_n, step)

		_ensure_card_shapes_enabled(card_n)

		# —— 根据 header 是否启用，挂/卸载牌眉 hover 信号 —— 
		_update_header_hover_signals(card_n, header_enabled)

	emit_signal("pile_changed", self)
	_update_blocked_cells()

func _reflow_after_change() -> void:
	reflow_visuals()

func _set_card_layer(card: Node2D, z: int) -> void:
	if not _is_valid_obj(card):
		return
	card.z_index = z

func _move_card(card: Node2D, local_pos: Vector2) -> void:
	if not _is_valid_obj(card):
		return
	var target_global: Vector2 = to_global(local_pos)
	if _suspend_anim or _dragging:
		card.global_position = target_global
		return
	var pile_defs := _snap_defaults_from_pile()
	var card_anim := _ensure_anim_on(card)
	card_anim.tween_to(
		target_global,
		pile_defs["dur"],
		-1.0,
		card.z_index,
		pile_defs["trans"],
		pile_defs["ease"]
	)

# ================= 拖拽逻辑 =================
func request_drag(from_card: Node2D, mode: String, start_index: int = -1) -> void:
	if _dragging:
		return

	# 拖拽前清空所有堆叠 hover
	_clear_all_pile_hover()

	match mode:
		"pile":
			_begin_drag_pile()
		"substack":
			_begin_drag_substack(from_card, start_index)
		_:
			_begin_drag_pile()

func _begin_drag_pile() -> void:
	_kill_rebound()
	_cards_clean()
	_dragging = true
	_suspend_anim = true
	_drag_mode = &"pile"
	_pre_drag_global = global_position
	_release_all_blocked_cells()

	if pickup_scale > 0.0 and absf(pickup_scale - 1.0) > 0.0001:
		scale = _orig_scale * Vector2(pickup_scale, pickup_scale)

	z_as_relative = false
	if drag_z >= 0:
		var z_cap := RenderingServer.CANVAS_ITEM_Z_MAX - 1
		z_index = min(drag_z, z_cap)

	_drag_offset = get_global_mouse_position() - global_position
	_set_all_cards_interaction(true, false)  # 先确保卡都可交互（有些卡在别处被禁用了）
	_set_all_cards_interaction(false, true)  # 拖拽中禁用交互
	emit_signal("drag_started", self)

func _begin_drag_substack(from_card: Node2D, start_index: int) -> void:
	if not _is_valid_obj(from_card):
		return
	var idx: int = start_index
	if idx < 0:
		idx = index_of_card(from_card)
	if idx < 0:
		return
	var subset: Array = extract_from(idx)
	var origin: Vector2 = from_card.global_position

	var new_pile: PileManager = _spawn_new_pile_for_drag(subset, origin)
	if new_pile == null:
		add_cards(subset)
		return
	new_pile._source_pile_ref = weakref(self)
	new_pile._source_insert_index = idx
	new_pile._begin_drag_pile()
	_reflow_after_change()

func _spawn_new_pile_for_drag(cards_to_attach: Array, origin_global: Vector2) -> PileManager:
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

# ================= 拖拽更新与结束 =================
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

	var restored: bool = false
	var need_rebound: bool = true

	if _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_pile"):
		var ok := bool(_grid.call("drop_pile", self, global_position))
		need_rebound = not ok

	if need_rebound:
		# —— 子堆拖拽失败：把当前所有卡插回源堆（若存在源堆） —— 
		if _source_pile_ref != null:
			var src := _source_pile_ref.get_ref() as PileManager
			if src != null and is_instance_valid(src):
				var cards_back: Array = get_cards()
				_detach_all_cards_without_reflow()
				var insert_idx: int = _source_insert_index
				if insert_idx < 0:
					insert_idx = src._guess_insert_index_by_position(
						cards_back[0].global_position if cards_back.size() > 0 else global_position
					)
				src._insert_cards_at(cards_back, insert_idx)
				src.reflow_visuals()

				if src._cards.size() > 0 and _is_valid_obj(src._cards[src._cards.size() - 1]):
					var top := src._cards[src._cards.size() - 1]
					var top_anim := _ensure_anim_on(top)
					top_anim.bump()
				if src.has_method("_update_blocked_cells"):
					src.call("_update_blocked_cells")

				queue_free()
				restored = true
			else:
				_rebound_to_pre_drag()
				restored = true
		else:
			# 整堆拖拽失败 → 原位回弹
			_rebound_to_pre_drag()
			restored = true
	else:
		# 成功落位：恢复交互、清理“回家”信息
		_set_all_cards_interaction(true, true)
		_pre_drag_parent = null
		_pre_drag_sibling_idx = -1
		_source_pile_ref = null
		_source_insert_index = -1

	if not restored and has_method("_update_blocked_cells"):
		_update_blocked_cells()

# ================= 回弹动画 =================
func _rebound_to_pre_drag() -> void:
	_kill_rebound()
	_set_all_cards_interaction(true, true)
	z_index = _orig_z

	force_update_transform()

	# 同步所有卡的位置到各自层目标（避免漂移）
	var step: float = card_pixel_size.y * visible_ratio
	for i in range(_cards.size()):
		var c := _cards[i]
		if _is_valid_obj(c):
			c.global_position = to_global(Vector2(0.0, float(i) * step))

	_suspend_anim = true
	reflow_visuals()
	_suspend_anim = false

	var anim := _ensure_anim_on(self)
	anim.on_finished.connect(func () -> void:
		reflow_visuals()
		if _cards.size() > 0 and _is_valid_obj(_cards[_cards.size() - 1]):
			var top := _cards[_cards.size() - 1]
			var top_anim := _ensure_anim_on(top)
			top_anim.bump()
		if has_method("_update_blocked_cells"):
			_update_blocked_cells()
	, CONNECT_ONE_SHOT)

	# 轻微回弹
	anim.rebound_to(_pre_drag_global, 0.16)

# ================= 工具与动画 =================
func _kill_rebound() -> void:
	if _rebound_tween != null and is_instance_valid(_rebound_tween):
		_rebound_tween.kill()
	_rebound_tween = null

func _set_all_cards_interaction(enable_before: bool, enable_now: bool) -> void:
	# 为了避免“在禁用时正好对象被销毁”，这里每次都清理再设置
	_cards_clean()
	for c in _cards:
		if _is_valid_obj(c) and c.has_method("set_interaction_enabled"):
			# 如果需要，先开一次再关（或反之）来重置外部状态机
			if enable_before != enable_now:
				c.call("set_interaction_enabled", enable_before)
			c.call("set_interaction_enabled", enable_now)

# ================= 自动禁用覆盖格 =================
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
		_clear_all_pile_hover()

func owns_blocked_cell(cell: int) -> bool:
	return _blocked_cells.has(cell)

func _release_all_blocked_cells() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return
	for c: int in _blocked_cells:
		if _grid.is_cell_forbidden(c):
			_grid.unblock_cell(c)
	_blocked_cells.clear()

# ================= 动画与模板工具 =================
func _ensure_anim_on(node: Node2D) -> CardAnimation:
	var anim := _find_card_anim(node)
	if anim != null:
		return anim
	var named := node.get_node_or_null(^"CardAnimation")
	if named != null and not (named is CardAnimation):
		named.name = "CardAnimation_Legacy"
	anim = CardAnimation.new()
	anim.name = "CardAnimation"
	node.add_child(anim)
	var tmpl := _anim_defaults()
	if tmpl != null:
		_copy_anim_defaults(anim, tmpl)
	return anim

func _self_anim() -> CardAnimation:
	for child in get_children():
		if child is CardAnimation:
			return child
	return _ensure_anim_on(self)

func _snap_defaults_from_pile() -> Dictionary:
	var a := _self_anim()
	return {
		"dur":  a.default_duration,
		"trans": a.default_trans,
		"ease": a.default_ease
	}

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

func _find_card_anim(node: Node) -> CardAnimation:
	for child in node.get_children():
		if child is CardAnimation:
			return child
	return null

# ================= 插回/回家工具 =================
func _detach_all_cards_without_reflow() -> void:
	_cards_clean()
	for c in _cards:
		if _is_valid_obj(c) and c.has_method("set_pile"):
			c.call("set_pile", null)
	_cards.clear()

func _insert_cards_at(cards: Array, at_index: int) -> void:
	if cards == null or cards.is_empty():
		return
	var idx: int = clampi(at_index, 0, _cards.size())
	for v in cards:
		if not _is_valid_obj(v):
			continue
		var c: Node2D = v as Node2D
		var gp: Vector2 = c.global_position
		var par := c.get_parent()
		if par != null:
			par.remove_child(c)
		add_child(c)
		c.global_position = gp
		if c.has_method("set_pile"):
			c.call("set_pile", self)
		_cards.insert(idx, c)
		idx += 1

func _guess_insert_index_by_position(pos_g: Vector2) -> int:
	_cards_clean()
	if _cards.is_empty():
		return 0
	for i in range(_cards.size()):
		var ci := _cards[i]
		if _is_valid_obj(ci) and pos_g.y <= ci.global_position.y:
			return i
	return _cards.size()

func _ensure_card_shapes_enabled(card: Node2D) -> void:
	if not _is_valid_obj(card):
		return
	var full := card.get_node_or_null(^"hit_full") as Area2D
	if full != null:
		var csf := full.get_node_or_null(^"CollisionShape2D") as CollisionShape2D
		if csf != null:
			csf.set_deferred("disabled", false)
	var header := card.get_node_or_null(^"hit_header") as Area2D
	if header != null:
		var csh := header.get_node_or_null(^"CollisionShape2D") as CollisionShape2D
		if csh != null:
			csh.set_deferred("disabled", false)
	if card.has_method("set_interaction_enabled"):
		card.call("set_interaction_enabled", true)
	if card.has_method("get_pile") and card.has_method("set_pile"):
		if card.call("get_pile") != self:
			card.call("set_pile", self)
	elif card.has_method("set_pile"):
		card.call("set_pile", self)

# ---------- 牌眉命中区尺寸/位置调整 ----------
func _fit_header_hit_area(card: Node2D, strip_h: float) -> void:
	if not _is_valid_obj(card):
		return
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

# ================== SellingArea 钩子 ==================
func on_node_will_be_sold(n: Node2D) -> void:
	if n == null:
		return
	# 单个节点将被卖出：如果在本堆中，先移除它，避免后续继续引用
	remove_card(n)

func on_pile_will_be_sold(n: Node2D) -> void:
	if n == self:
		_cards.clear() # 动画/释放由 SellingArea 完成

func on_cards_sold(nodes: Array) -> void:
	if nodes == null:
		return
	var to_remove: Array = []
	for c in _cards:
		if nodes.find(c) != -1:
			to_remove.append(c)
	for r in to_remove:
		remove_card(r)

# =====================================================
#          牌眉 Hover 联动 CardController 放大
# =====================================================

func _update_header_hover_signals(card: Node2D, header_enabled: bool) -> void:
	if not _is_valid_obj(card):
		return
	var area: Area2D = card.get_node_or_null(^"hit_header") as Area2D
	if area == null:
		return

	var enter_call := Callable(self, "_on_header_mouse_entered").bind(card)
	var exit_call := Callable(self, "_on_header_mouse_exited").bind(card)

	if header_enabled:
		if not area.is_connected("mouse_entered", enter_call):
			area.connect("mouse_entered", enter_call)
		if not area.is_connected("mouse_exited", exit_call):
			area.connect("mouse_exited", exit_call)
	else:
		if area.is_connected("mouse_entered", enter_call):
			area.disconnect("mouse_entered", enter_call)
		if area.is_connected("mouse_exited", exit_call):
			area.disconnect("mouse_exited", exit_call)

func _on_header_mouse_entered(card: Node2D) -> void:
	if not _is_valid_obj(card):
		return
	var idx: int = index_of_card(card)
	if idx < 0:
		return

	# 如果还是同一张牌的牌眉，别重复改，避免抖
	if idx == _current_pile_hover_start_idx:
		return

	# 先把之前那段 pile hover 清掉
	if _current_pile_hover_start_idx >= 0:
		_clear_pile_hover_from(_current_pile_hover_start_idx)

	# 从这张牌开始，往上的所有牌都触发 hover
	_apply_pile_hover_from(idx)
	_current_pile_hover_start_idx = idx


func _on_header_mouse_exited(card: Node2D) -> void:
	if not _is_valid_obj(card):
		return
	var idx: int = index_of_card(card)
	if idx < 0:
		return

	# 只有正在生效的那一段需要清
	if idx != _current_pile_hover_start_idx:
		return

	_clear_pile_hover_from(idx)
	_current_pile_hover_start_idx = -1


func _apply_pile_hover_from(start_idx: int) -> void:
	_cards_clean()
	if start_idx < 0:
		start_idx = 0
	for i in range(start_idx, _cards.size()):
		_set_card_pile_hover(_cards[i], true)


func _clear_pile_hover_from(start_idx: int) -> void:
	_cards_clean()
	if start_idx < 0:
		start_idx = 0
	for i in range(start_idx, _cards.size()):
		_set_card_pile_hover(_cards[i], false)

func _clear_all_pile_hover() -> void:
	_cards_clean()
	for c in _cards:
		_set_card_pile_hover(c, false)
	_current_pile_hover_start_idx = -1


func _set_card_pile_hover(card: Node2D, active: bool) -> void:
	if not _is_valid_obj(card):
		return
	# 假设 CardController 挂在 Card 根下面某个子节点
	# 优先按名字找，其次按类型找
	var ctrl_node: Node = card.get_node_or_null(^"CardController")
	if ctrl_node == null:
		for child in card.get_children():
			if child is CardController:
				ctrl_node = child
				break
	if ctrl_node == null:
		return
	if ctrl_node.has_method("set_pile_hover"):
		ctrl_node.call("set_pile_hover", active)
