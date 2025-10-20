extends Node2D
class_name GridManager

# =========================
# —— 可在 Inspector 调参 —— 
# =========================
@export var origin: Vector2 = Vector2.ZERO
@export var card_pixel_size: Vector2 = Vector2(47, 64)
@export var visual_scale: float = 1.0
@export var gap: Vector2 = Vector2(8, 8)
@export var cols: int = 8
@export var rows: int = 4

@export_range(0.0, 2.0, 0.01) var snap_radius_ratio: float = 0.25
@export var allow_out_of_bounds: bool = false

# ✅ 禁用格列表（持久化）：你可以在 Inspector 里手动填，或运行时用快捷键切换
@export var forbidden_cells: Array[int] = []

@export var pile_scene: PackedScene

# —— 调试可视化 —— 
@export var show_grid: bool = true
@export var grid_fill: bool = true
@export var grid_outline: bool = true
@export var grid_fill_color: Color = Color(0.25, 0.25, 0.25, 0.12)
@export var grid_outline_color: Color = Color(0.9, 0.9, 0.9, 0.35)
@export_range(0.5, 6.0, 0.5) var grid_outline_width: float = 1.5
@export var show_centers: bool = false
@export var center_color: Color = Color(0.8, 0.2, 0.2, 0.6)

@export var calibrate_from: NodePath

# —— 禁用格的可视化覆盖层 —— 
@export var show_blocked_overlay: bool = true
@export var blocked_fill_color: Color = Color(1, 0.25, 0.25, 0.28)
@export var blocked_outline_color: Color = Color(1, 0.2, 0.2, 0.9)
@export_range(0.5, 6.0, 0.5) var blocked_outline_width: float = 2.0

# —— 开发期快捷切换（仅你用，不给玩家）——
@export var dev_toggle_enabled: bool = true
@export var dev_toggle_requires_alt: bool = true   # Alt+左键 点击切换禁用；关掉则仅左键即可
@export var dev_toggle_mouse_button: MouseButton = MOUSE_BUTTON_LEFT

# =========================
# —— 运行期状态 —— 
# =========================
var _occupancy: Dictionary = {}         # key: cell(int) -> value: PileManager
var _cell_centers: Array[Vector2] = []  # 存“本地中心”

# =========================
# —— 信号 —— 
# =========================
signal card_dropped_to_empty_cell(card: Node2D, cell: int)
signal card_dropped_to_occupied_cell(card: Node2D, cell: int)
signal pile_dropped_to_cell(pile: Node2D, cell: int)
signal drop_rejected(target: Node, reason: String)

# =========================
# —— 生命周期 —— 
# =========================
func _ready() -> void:
	_try_auto_calibrate()
	_precompute_cells()
	_init_occupancy()
	set_process_unhandled_input(true)

func _unhandled_input(event: InputEvent) -> void:
	# 显隐网格
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_G:
		show_grid = not show_grid
		queue_redraw()

	# 开发期：Alt+点击网格，切换该格禁用状态
	if dev_toggle_enabled and event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == dev_toggle_mouse_button:
			if not dev_toggle_requires_alt or (mb.alt_pressed and dev_toggle_requires_alt):
				# ✅ 直接用全局鼠标坐标（无需 canvas transform）
				var world_pos: Vector2 = get_global_mouse_position()
				var cell := _world_to_cell_idx(world_pos)
				if cell != -1:
					toggle_cell(cell)
					queue_redraw()


# =========================
# —— 自动校准 —— 
# =========================
func _try_auto_calibrate() -> void:
	if calibrate_from == NodePath():
		return
	var sp := get_node_or_null(calibrate_from) as Sprite2D
	if sp == null:
		return
	var measured: Vector2 = _sprite_display_size(sp)
	if measured.x > 0.0 and measured.y > 0.0:
		card_pixel_size = measured

func _sprite_display_size(sp: Sprite2D) -> Vector2:
	var base := Vector2.ZERO
	if sp.region_enabled:
		base = sp.region_rect.size
	elif sp.texture != null:
		base = sp.texture.get_size()
	else:
		return Vector2.ZERO
	return base * sp.scale

# =========================
# —— 坐标工具（本地/全局） —— 
# =========================
func _cell_size() -> Vector2:
	return card_pixel_size * Vector2(visual_scale, visual_scale)  # 本地

func _step_size() -> Vector2:
	return _cell_size() + gap  # 本地

func _cell_topleft_local(c: int, r: int) -> Vector2:
	var step: Vector2 = _step_size()
	return origin + Vector2(float(c) * step.x, float(r) * step.y)

func _cell_rect_local(c: int, r: int) -> Rect2:
	return Rect2(_cell_topleft_local(c, r), _cell_size())

func _cell_topleft_global(c: int, r: int) -> Vector2:
	return to_global(_cell_topleft_local(c, r))

func _cell_rect_global(c: int, r: int) -> Rect2:
	var local_rect: Rect2 = _cell_rect_local(c, r)
	return Rect2(to_global(local_rect.position), local_rect.size)

func _idx(c: int, r: int) -> int:
	return r * cols + c

func _rc(cell: int) -> Vector2i:
	var r: int = cell / cols
	var c: int = cell % cols
	return Vector2i(c, r)

# =========================
# —— 预计算/占用 —— 
# =========================
func _precompute_cells() -> void:
	_cell_centers.resize(cols * rows)
	var idx := 0
	for r in range(rows):
		for c in range(cols):
			var rect: Rect2 = _cell_rect_local(c, r)     # 本地矩形
			_cell_centers[idx] = rect.position + rect.size * 0.5  # 存本地中心
			idx += 1

func _init_occupancy() -> void:
	_occupancy.clear()
	for i in range(cols * rows):
		_occupancy[i] = null

# =========================
# —— 公共查询接口 / 禁用接口 —— 
# =========================
func get_cell_pos(cell: int) -> Vector2:
	if cell < 0 or cell >= _cell_centers.size():
		return to_global(origin)
	return to_global(_cell_centers[cell])  # 全局中心

func is_cell_free(cell: int) -> bool:
	return _valid_cell(cell) and _occupancy.get(cell, null) == null

func get_pile(cell: int) -> PileManager:
	return _occupancy.get(cell, null)

func is_cell_forbidden(cell: int) -> bool:
	return forbidden_cells.has(cell)

# —— 新增：编辑/脚本可调用 —— 
func block_cell(cell: int) -> void:
	if _valid_cell(cell) and not forbidden_cells.has(cell):
		forbidden_cells.append(cell)
		queue_redraw()

func unblock_cell(cell: int) -> void:
	if forbidden_cells.has(cell):
		forbidden_cells.erase(cell)
		queue_redraw()

func toggle_cell(cell: int) -> void:
	if forbidden_cells.has(cell):
		forbidden_cells.erase(cell)
	else:
		if _valid_cell(cell):
			forbidden_cells.append(cell)
	queue_redraw()

func block_many(cells: Array[int]) -> void:
	for c in cells:
		if _valid_cell(c) and not forbidden_cells.has(c):
			forbidden_cells.append(c)
	queue_redraw()

func unblock_all() -> void:
	forbidden_cells.clear()
	queue_redraw()

# =========================
# —— 输入：投放（吸附） —— 
# =========================
func drop_card(card: Card, drop_global: Vector2) -> bool:
	var cell: int = _world_to_cell_idx(drop_global)
	if cell == -1:
		cell = _world_to_cell_idx(card.global_position)  # 兜底：卡中心
	if cell == -1 and not allow_out_of_bounds:
		emit_signal("drop_rejected", card, "out_of_bounds")
		return false
	if cell != -1 and is_cell_forbidden(cell):
		emit_signal("drop_rejected", card, "forbidden_cell")
		return false
	if cell == -1 and allow_out_of_bounds:
		emit_signal("drop_rejected", card, "no_snap_region")
		return false

	var dst_pile: PileManager = _ensure_pile(cell)
	dst_pile.add_card(card)
	dst_pile.global_position = get_cell_pos(cell)
	dst_pile.reflow_visuals()
	_occupancy[cell] = dst_pile

	if dst_pile.get_cards().size() == 1:
		emit_signal("card_dropped_to_empty_cell", card, cell)
	else:
		emit_signal("card_dropped_to_occupied_cell", card, cell)
	return true

func drop_pile(pile: PileManager, drop_global: Vector2) -> bool:
	var cell: int = _world_to_cell_idx(drop_global)
	if cell == -1:
		cell = _world_to_cell_idx(pile.global_position)  # 兜底：堆中心
	if cell == -1 and not allow_out_of_bounds:
		emit_signal("drop_rejected", pile, "out_of_bounds")
		return false
	if cell != -1 and is_cell_forbidden(cell):
		emit_signal("drop_rejected", pile, "forbidden_cell")
		return false
	if cell == -1 and allow_out_of_bounds:
		emit_signal("drop_rejected", pile, "no_snap_region")
		return false

	var src_cell: int = _find_cell_by_pile(pile)
	var dst_pile: PileManager = _ensure_pile(cell)
	if dst_pile == null:
		emit_signal("drop_rejected", pile, "forbidden_cell")
		return false

	if dst_pile != pile:
		var cards: Array = pile.get_cards()
		for c in cards:
			dst_pile.add_card(c)
		pile.queue_free()

	dst_pile.global_position = get_cell_pos(cell)
	dst_pile.reflow_visuals()
	_occupancy[cell] = dst_pile
	_vacate_if(src_cell, pile)
	emit_signal("pile_dropped_to_cell", dst_pile, cell)
	return true

# =========================
# —— 私有：堆管理 —— 
# =========================
func _ensure_pile(cell: int) -> PileManager:
	# ✅ 底层硬拦：禁格一律不创建/不返回堆
	if is_cell_forbidden(cell):
		push_warning("[Grid] attempt to ensure pile on forbidden cell: %d — blocked." % cell)
		return null

	var existing: PileManager = get_pile(cell)
	if existing != null:
		return existing

	var pile_node: Node2D
	if pile_scene != null:
		pile_node = pile_scene.instantiate() as Node2D
	else:
		pile_node = Node2D.new()

	add_child(pile_node)
	pile_node.global_position = get_cell_pos(cell)
	var mgr: PileManager = pile_node as PileManager
	if mgr != null:
		mgr.card_pixel_size = card_pixel_size
	_occupancy[cell] = mgr
	return mgr


func _find_cell_by_pile(pile: PileManager) -> int:
	for i in range(cols * rows):
		if _occupancy.get(i, null) == pile:
			return i
	return -1

func _vacate_if(cell: int, pile: PileManager) -> void:
	if cell >= 0 and _occupancy.get(cell, null) == pile:
		_occupancy[cell] = null

# =========================
# —— 坐标换算 & 命中判定 —— 
# =========================
func _world_to_cell_cr(world: Vector2) -> Vector2i:
	var local: Vector2 = to_local(world)
	var step: Vector2 = _step_size()
	var cx: int = int(floor((local.x - origin.x) / step.x))
	var cy: int = int(floor((local.y - origin.y) / step.y))
	return Vector2i(cx, cy)

func _world_to_cell_idx(world: Vector2) -> int:
	var cr: Vector2i = _world_to_cell_cr(world)
	if cr.x < 0 or cr.y < 0 or cr.x >= cols or cr.y >= rows:
		return -1
	var cell: int = _idx(cr.x, cr.y)

	if snap_radius_ratio <= 0.0:
		var rect_g: Rect2 = _cell_rect_global(cr.x, cr.y)
		return cell if rect_g.has_point(world) else -1
	else:
		# 外接圆半径（更宽松）
		var rect_g: Rect2 = _cell_rect_global(cr.x, cr.y)
		var center_g: Vector2 = rect_g.position + rect_g.size * 0.5
		var diag: float = sqrt(rect_g.size.x * rect_g.size.x + rect_g.size.y * rect_g.size.y)
		var radius: float = 0.5 * diag * float(snap_radius_ratio)
		return cell if world.distance_to(center_g) <= radius else -1

func _valid_cell(cell: int) -> bool:
	return cell >= 0 and cell < cols * rows

# =========================
# —— 绘制网格（本地） —— 
# =========================
func _draw() -> void:
	if not show_grid:
		return
	var idx := 0
	for r in range(rows):
		for c in range(cols):
			var rect: Rect2 = _cell_rect_local(c, r)  # 在本地坐标绘制
			# 普通网格
			if grid_fill:
				draw_rect(rect, grid_fill_color, true)
			if grid_outline:
				draw_rect(rect, grid_outline_color, false, grid_outline_width)

			# 禁用格覆盖层
			var cell: int = _idx(c, r)
			if show_blocked_overlay and forbidden_cells.has(cell):
				draw_rect(rect, blocked_fill_color, true)
				draw_rect(rect, blocked_outline_color, false, blocked_outline_width)

			if show_centers:
				draw_circle(_cell_centers[idx], 3.0, center_color)
			idx += 1

func _process(_delta: float) -> void:
	if show_grid:
		queue_redraw()
