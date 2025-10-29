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

func remove_card(card: Card) -> void:
	var i: int = _cards.find(card)
	if i >= 0:
		_cards.remove_at(i)
	card.set_pile(null)
	reflow_visuals()

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

		_ensure_card_shapes_enabled(card)

	emit_signal("pile_changed", self)
	_update_blocked_cells()

func _reflow_after_change() -> void:
	reflow_visuals()

func _set_card_layer(card: Card, z: int) -> void:
	card.z_index = z

func _move_card(card: Card, local_pos: Vector2) -> void:
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

# ---------- 拖拽逻辑 ----------
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
	_kill_rebound()
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
	new_pile._source_pile_ref = weakref(self)
	new_pile._source_insert_index = idx
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

# ---------- 拖拽更新与结束 ----------
func _process(_delta: float) -> void:
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()
		global_position = mouse_g - _drag_offset
		emit_signal("drag_moved", self, mouse_g)

func _unhandled_input(event: InputEvent) -> void:
	if _dragging and event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_end_drag_and_drop()

# ========== 新版拖拽结束函数 ==========
func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	_dragging = false
	emit_signal("drag_ended", self)

	_suspend_anim = false
	scale = _orig_scale

	var restored := false
	var need_rebound := true

	if _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_pile"):
		var ok := bool(_grid.call("drop_pile", self, global_position))
		need_rebound = not ok

	if need_rebound:
		# —— 子堆拖拽失败：把当前所有卡插回源堆（若存在源堆） —— 
		if _source_pile_ref != null:
			var src := _source_pile_ref.get_ref() as PileManager
			if src != null and is_instance_valid(src):
				var cards_back: Array[Card] = get_cards()
				_detach_all_cards_without_reflow()

				var insert_idx: int = _source_insert_index
				if insert_idx < 0:
					insert_idx = src._guess_insert_index_by_position(
						cards_back[0].global_position if cards_back.size() > 0 else global_position
					)

				src._insert_cards_at(cards_back, insert_idx)

				# ① 重排（刷新 full/header 判定与 z）
				src.reflow_visuals()
				

				# ③ 动效 + 刷新禁用格
				if src._cards.size() > 0:
					var top: Card = src._cards[src._cards.size() - 1]
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
		_set_all_cards_interaction(true)
		_pre_drag_parent = null
		_pre_drag_sibling_idx = -1
		_source_pile_ref = null
		_source_insert_index = -1

	if not restored:
		if has_method("_update_blocked_cells"):
			_update_blocked_cells()
			

# ---------- 回弹动画 ----------
func _rebound_to_pre_drag() -> void:
	_kill_rebound()
	_set_all_cards_interaction(true)
	z_index = _orig_z

	# ✅ 关键修复：确保 transform 是最新的
	force_update_transform()

	# ✅ 同步所有卡的 global_position（避免卡片漂移）
	for c in _cards:
		c.global_position = to_global(Vector2(0, card_pixel_size.y * visible_ratio * _cards.find(c)))

	# ✅ 开始回弹前，先手动 reflow 一次确保堆叠顺序
	_suspend_anim = true
	reflow_visuals()
	_suspend_anim = false

	var anim := _ensure_anim_on(self)
	anim.on_finished.connect(func ():
		# 回弹结束后再次 reflow，确保视觉最终一致
		reflow_visuals()
		if _cards.size() > 0:
			var top := _cards[_cards.size() - 1]
			var top_anim := _ensure_anim_on(top)
			top_anim.bump()
		if has_method("_update_blocked_cells"):
			_update_blocked_cells()
	, CONNECT_ONE_SHOT)

	anim.rebound_to(_pre_drag_global, 0.16)



# ---------- 工具与动画 ----------
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

# ====== 动画与模板工具 ======
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

# ====== 插回/回家工具 ======
func _detach_all_cards_without_reflow() -> void:
	for c: Card in _cards:
		c.set_pile(null)
	_cards.clear()

func _insert_cards_at(cards: Array[Card], at_index: int) -> void:
	if cards.is_empty():
		return
	var idx: int = clampi(at_index, 0, _cards.size())
	for c: Card in cards:
		var gp: Vector2 = c.global_position
		if c.get_parent() != null:
			c.get_parent().remove_child(c)
		add_child(c)
		c.global_position = gp
		c.set_pile(self)
		_cards.insert(idx, c)
		idx += 1

func _guess_insert_index_by_position(pos_g: Vector2) -> int:
	if _cards.is_empty():
		return 0
	for i in range(_cards.size()):
		var ci: Card = _cards[i]
		if pos_g.y <= ci.global_position.y:
			return i
	return _cards.size()

func _ensure_card_shapes_enabled(card: Card) -> void:
	if card == null:
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
	if "set_interaction_enabled" in card:
		card.set_interaction_enabled(true)
	if "get_pile" in card:
		if card.get_pile() != self:
			card.set_pile(self)
	else:
		card.set_pile(self)

func _ensure_whole_pile_shapes_enabled() -> void:
	for c: Card in _cards:
		_ensure_card_shapes_enabled(c)

# ---------- 牌眉命中区尺寸/位置调整 ----------
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
