extends Node2D
class_name PileManager

# ========= 可在 Inspector 调参 =========
@export var grid_manager_path: NodePath                 # 可留空，脚本会按名字兜底查找 "GridManager"
@export var visible_ratio: float = 0.15                 # 露出的牌眉比例（0.15=露15%，即覆盖85%）
@export var card_pixel_size: Vector2 = Vector2(47, 64)  # 卡片像素高宽（用于堆内偏移与牌眉尺寸）
@export var z_base: int = 100                           # 底牌 z
@export var per_layer_z: int = 1                        # 每层 z 递增
@export var pickup_scale: float = 1.06                  # 整叠拖拽时视觉提起
@export var drag_z: int = 9000                          # 整叠拖拽置顶
@export var pile_scene: PackedScene                     # 子叠拖拽时临时生成新堆（建议指向你的 Pile.tscn）

# 可选：自动把 hit_header 的 CollisionShape2D 调整到“正好等于牌眉高度”
@export var auto_fit_header: bool = true

# ========= 信号 =========
signal pile_changed(pile: PileManager)
signal drag_started(pile: PileManager)
signal drag_moved(pile: PileManager, mouse_global: Vector2)
signal drag_ended(pile: PileManager)

# ========= 运行时状态 =========
var _grid: Node = null
var _cards: Array[Card] = []            # 顺序：底 -> 顶
var _dragging: bool = false
var _drag_mode: StringName = &"pile"    # "pile"|"substack"
var _drag_offset: Vector2 = Vector2.ZERO
var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0

# ========= 生命周期 =========
func _ready() -> void:
	# 优先 Inspector 路径 → 当前场景名为 GridManager → 全树查找
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
	if card.get_parent() != null:
		card.get_parent().remove_child(card)
	add_child(card)
	card.set_pile(self)
	_cards.append(card)
	_reflow_after_change()

func add_cards(cards: Array[Card]) -> void:
	for c: Card in cards:
		if c.get_parent() != null:
			c.get_parent().remove_child(c)
		add_child(c)
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
	extracted.reverse() # 保持底->顶顺序
	_reflow_after_change()
	return extracted

# ---------- 视觉重排（关键：覆盖85%/露15%） ----------
func reflow_visuals() -> void:
	# step = 牌眉可见高度 = 牌高 * visible_ratio（例如 0.15）
	var step: float = card_pixel_size.y * visible_ratio
	for i in range(_cards.size()):
		var card: Card = _cards[i]
		var target_local: Vector2 = Vector2(0.0, float(i) * step)  # 垂直向下堆
		_set_card_layer(card, z_base + i * per_layer_z)
		_move_card(card, target_local)

		# 命中区：顶牌整张，其余仅牌眉
		var full_enabled: bool = (i == _cards.size() - 1)
		var header_enabled: bool = not full_enabled
		card.set_hit_areas(full_enabled, header_enabled)

		# （可选）自动把命中“牌眉区域”调到与可见高度吻合
		if auto_fit_header and header_enabled:
			_fit_header_hit_area(card, step)

	emit_signal("pile_changed", self)

func _reflow_after_change() -> void:
	reflow_visuals()

func _set_card_layer(card: Card, z: int) -> void:
	card.z_index = z

func _move_card(card: Card, local_pos: Vector2) -> void:
	var target_global: Vector2 = to_global(local_pos)
	var anim: Node = card.get_node_or_null(^"CardAnimation")
	if anim != null and anim.has_method("tween_to"):
		anim.call("tween_to", target_global, 0.12, 1.0, card.z_index)
	else:
		card.global_position = target_global

# 把 hit_header 的 CollisionShape2D 调整到“正好覆盖牌眉 strip”
# 假设：Card 的原点在中心；CollisionShape2D 使用 RectangleShape2D
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
	# 牌眉条在“卡的最上方”露出 strip_h：碰撞矩形高度=strip_h，中心位于最上边中点下方 strip_h/2
	rect.extents = Vector2(card_pixel_size.x * 0.5, maxf(strip_h, 1.0) * 0.5)
	# 原点在中心：上边 y = -card_h/2 ⇒ 牌眉中心 y = -card_h/2 + strip_h/2
	cs.position = Vector2(0.0, -card_pixel_size.y * 0.5 + strip_h * 0.5)

# ---------- 拖拽接管（由 Card 调用）----------
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
	_dragging = true
	_drag_mode = &"pile"
	if pickup_scale > 0.0 and absf(pickup_scale - 1.0) > 0.0001:
		scale = _orig_scale * Vector2(pickup_scale, pickup_scale)
	if drag_z >= 0:
		z_index = drag_z
	_drag_offset = get_global_mouse_position() - global_position   # ✅ 全局
	_set_all_cards_interaction(false)
	emit_signal("drag_started", self)

func _begin_drag_substack(from_card: Card, start_index: int) -> void:
	var idx: int = start_index
	if idx < 0:
		idx = index_of_card(from_card)
	if idx < 0:
		return
	var subset: Array[Card] = extract_from(idx)  # 底->顶
	var new_pile: PileManager = _spawn_new_pile_for_drag(subset)
	if new_pile == null:
		add_cards(subset) # 回退
		return
	new_pile._begin_drag_pile()
	_reflow_after_change()

func _spawn_new_pile_for_drag(cards_to_attach: Array[Card]) -> PileManager:
	var parent_node: Node = get_parent()
	if parent_node == null:
		parent_node = get_tree().get_current_scene()

	var pile_node: Node2D = null
	if pile_scene != null:
		pile_node = pile_scene.instantiate() as Node2D
	else:
		pile_node = Node2D.new()
		pile_node.set_script(load(get_script().resource_path))
	parent_node.add_child(pile_node)
	# 放到鼠标附近（全局）
	pile_node.global_position = get_global_mouse_position()

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
	new_mgr.add_cards(cards_to_attach)
	return new_mgr

# ---------- 拖拽跟随 / 结束（全局坐标） ----------
func _process(_delta: float) -> void:
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()    # ✅ 全局
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
	# 恢复视觉
	z_index = _orig_z
	scale = _orig_scale
	# ✅ 用全局坐标去落子
	if _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_pile"):
		_grid.call("drop_pile", self, global_position)   # ✅ 用堆中心（全局）
	_set_all_cards_interaction(true)

func _set_all_cards_interaction(enabled: bool) -> void:
	for c: Card in _cards:
		c.set_interaction_enabled(enabled)
