extends Node2D
class_name GridManager

# =========================
# —— 常量 —— 
# =========================
const MAX_GRID_SIZE: int = 1000  # 最大行列数，防止溢出
const DEFAULT_VISIBLE_RATIO: float = 0.15  # 默认卡片可见比例
const MAX_RECURSION_DEPTH: int = 100  # 挤压递归最大深度

# =========================
# —— 可在 Inspector 调参 —— 
# =========================
## 网格原点（本地坐标）
@export var origin: Vector2 = Vector2.ZERO
## 卡片像素尺寸
@export var card_pixel_size: Vector2 = Vector2(47, 64)
## 网格视觉缩放比例
@export var visual_scale: float = 1.0
## 格子间距（像素）
@export var gap: Vector2 = Vector2(8, 8)
## 网格列数
@export var cols: int = 8
## 网格行数
@export var rows: int = 4
## 吸附半径比例（相对于格子对角线）
@export_range(0.0, 2.0, 0.01) var snap_radius_ratio: float = 0.25
## 是否允许投放超出网格边界
@export var allow_out_of_bounds: bool = false
## 禁用格列表（键为单元格索引，值无意义）
@export var forbidden_cells: Dictionary = {}
## 卡片堆场景（用于实例化新堆）
@export var pile_scene: PackedScene
## 是否显示网格
@export var show_grid: bool = true
## 是否填充网格
@export var grid_fill: bool = true
## 是否绘制网格边框
@export var grid_outline: bool = true
## 网格填充颜色
@export var grid_fill_color: Color = Color(0.25, 0.25, 0.25, 0.12)
## 网格边框颜色
@export var grid_outline_color: Color = Color(0.9, 0.9, 0.9, 0.35)
## 网格边框宽度
@export_range(0.5, 6.0, 0.5) var grid_outline_width: float = 1.5
## 是否显示格子中心点
@export var show_centers: bool = false
## 中心点颜色
@export var center_color: Color = Color(0.8, 0.2, 0.2, 0.6)
## 用于自动校准的 Sprite2D 节点路径
@export var calibrate_from: NodePath
## 是否显示禁用格覆盖层
@export var show_blocked_overlay: bool = true
## 禁用格填充颜色
@export var blocked_fill_color: Color = Color(1, 0.25, 0.25, 0.28)
## 禁用格边框颜色
@export var blocked_outline_color: Color = Color(1, 0.2, 0.2, 0.9)
## 禁用格边框宽度
@export_range(0.5, 6.0, 0.5) var blocked_outline_width: float = 2.0
## 是否启用开发者切换禁用格功能
@export var dev_toggle_enabled: bool = true
## 是否需要按住 Alt 键切换禁用格
@export var dev_toggle_requires_alt: bool = true
## 切换禁用格的鼠标按键
@export var dev_toggle_mouse_button: MouseButton = MOUSE_BUTTON_LEFT
@export var anim_defaults_path: NodePath   # 可选：指向一个 CardAnimation 节点作为模板

# =========================
# —— 运行期状态 —— 
# =========================
var _occupancy: Dictionary = {}         # 单元格占用表：key: cell(int) -> value: PileManager
var _cell_centers: Array[Vector2] = []  # 存储格子本地中心
var _cached_cell_size: Vector2          # 缓存格子尺寸
var _cached_step_size: Vector2          # 缓存格子步进尺寸

# =========================
# —— 信号 —— 
# =========================
## 当卡片被投放到空单元格时发出
signal card_dropped_to_empty_cell(card: Node2D, cell: int)
## 当卡片被投放到已占用单元格时发出
signal card_dropped_to_occupied_cell(card: Node2D, cell: int)
## 当堆被投放到单元格时发出
signal pile_dropped_to_cell(pile: Node2D, cell: int)
## 当投放被拒绝时发出
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
	## 处理键盘输入：按 G 键切换网格显示
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_G:
		show_grid = not show_grid
		queue_redraw()
	## 处理鼠标输入：开发者模式下切换禁用格
	if dev_toggle_enabled and event is InputEventMouseButton and event.pressed:
		var mb := event as InputEventMouseButton
		if mb.button_index == dev_toggle_mouse_button:
			if not dev_toggle_requires_alt or (mb.alt_pressed and dev_toggle_requires_alt):
				var world_pos: Vector2 = get_global_mouse_position()
				var cell := _world_to_cell_idx(world_pos)
				if cell != -1:
					toggle_cell(cell)
					queue_redraw()

# =========================
# —— 自动校准 —— 
# =========================
## 尝试根据指定 Sprite2D 自动校准卡片尺寸
func _try_auto_calibrate() -> void:
	if calibrate_from == NodePath():
		return
	var sp := get_node_or_null(calibrate_from) as Sprite2D
	if sp == null:
		push_warning("Calibration sprite not found at path: %s" % calibrate_from)
		return
	var measured: Vector2 = _sprite_display_size(sp)
	if measured.x > 0.0 and measured.y > 0.0:
		card_pixel_size = measured
		_update_cached_sizes()

## 计算 Sprite2D 的显示尺寸
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
# —— 坐标工具 —— 
# =========================
## 更新缓存的格子尺寸和步进尺寸
func _update_cached_sizes() -> void:
	_cached_cell_size = card_pixel_size * Vector2(visual_scale, visual_scale)
	_cached_step_size = _cached_cell_size + gap

## 获取格子尺寸（本地）
func _cell_size() -> Vector2:
	return _cached_cell_size

## 获取格子步进尺寸（本地）
func _step_size() -> Vector2:
	return _cached_step_size

## 获取指定格子的本地矩形
func _cell_rect(c: int, r: int, is_global: bool = false) -> Rect2:
	var pos: Vector2 = origin + Vector2(float(c) * _step_size().x, float(r) * _step_size().y)
	var size: Vector2 = _cell_size()
	var rect := Rect2(pos, size)
	return Rect2(to_global(pos), size) if is_global else rect

## 将行列索引转换为单元格索引
func _idx(c: int, r: int) -> int:
	return r * cols + c

## 将单元格索引转换为行列坐标
func _rc(cell: int) -> Vector2i:
	var r: int = cell / cols
	var c: int = cell % cols
	return Vector2i(c, r)

# =========================
# —— 预计算/占用 —— 
# =========================
## 预计算所有格子的中心点
func _precompute_cells() -> void:
	if cols <= 0 or rows <= 0 or cols > MAX_GRID_SIZE or rows > MAX_GRID_SIZE:
		push_error("Invalid grid size: cols=%d, rows=%d" % [cols, rows])
		return
	_update_cached_sizes()
	_cell_centers.resize(cols * rows)
	var idx := 0
	for r in range(rows):
		for c in range(cols):
			var rect: Rect2 = _cell_rect(c, r)
			_cell_centers[idx] = rect.position + rect.size * 0.5
			idx += 1

## 初始化占用表
func _init_occupancy() -> void:
	_occupancy.clear()
	for i in range(cols * rows):
		_occupancy[i] = null

# =========================
# —— 公共查询接口 / 禁用接口 —— 
# =========================
## 获取单元格的全局中心位置
func get_cell_pos(cell: int) -> Vector2:
	if not _valid_cell(cell):
		return to_global(origin)
	return to_global(_cell_centers[cell])

## 检查单元格是否空闲
func is_cell_free(cell: int) -> bool:
	return _valid_cell(cell) and _occupancy.get(cell, null) == null

## 获取单元格上的堆
func get_pile(cell: int) -> PileManager:
	return _occupancy.get(cell, null)

## 检查单元格是否被禁用
func is_cell_forbidden(cell: int) -> bool:
	return forbidden_cells.has(cell)

## 禁用指定单元格
func block_cell(cell: int) -> void:
	if _valid_cell(cell) and not forbidden_cells.has(cell):
		forbidden_cells[cell] = true
		queue_redraw()

## 取消禁用指定单元格
func unblock_cell(cell: int) -> void:
	if forbidden_cells.has(cell):
		forbidden_cells.erase(cell)
		queue_redraw()

## 切换单元格禁用状态
func toggle_cell(cell: int) -> void:
	if forbidden_cells.has(cell):
		forbidden_cells.erase(cell)
	else:
		if _valid_cell(cell):
			forbidden_cells[cell] = true
	queue_redraw()

## 禁用多个单元格
func block_many(cells: Array[int]) -> void:
	for c in cells:
		if _valid_cell(c) and not forbidden_cells.has(c):
			forbidden_cells[c] = true
	queue_redraw()

## 取消所有禁用格
func unblock_all() -> void:
	forbidden_cells.clear()
	queue_redraw()

# =========================
# —— 输入：投放（吸附） —— 
# =========================
## 投放卡片到指定位置
func drop_card(card: Card, drop_global: Vector2) -> bool:
	var pile_hit: PileManager = _pick_pile_at_point(drop_global)
	if pile_hit != null:
		pile_hit.add_card(card)
		pile_hit.reflow_visuals()
		return true

	var cell: int = _world_to_cell_idx(drop_global)
	if cell == -1:
		cell = _world_to_cell_idx(card.global_position)
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
	if dst_pile == null:
		return false
	dst_pile.add_card(card)
	_animate_pile_to_position(dst_pile, cell)
	_occupancy[cell] = dst_pile

	if dst_pile.get_cards().size() == 1:
		emit_signal("card_dropped_to_empty_cell", card, cell)
	else:
		emit_signal("card_dropped_to_occupied_cell", card, cell)
	return true

## 投放堆到指定位置
func drop_pile(pile: PileManager, drop_global: Vector2) -> bool:
	var target_pile: PileManager = _pick_pile_at_point(drop_global)
	if target_pile != null and target_pile != pile:
		var src_cell: int = _find_cell_by_pile(pile)
		var cards_to_merge: Array = pile.get_cards()
		for c in cards_to_merge:
			target_pile.add_card(c)
		pile.queue_free()
		_vacate_if(src_cell, pile)
		_animate_pile_to_position(target_pile, _find_cell_by_pile(target_pile))
		emit_signal("pile_dropped_to_cell", target_pile, _find_cell_by_pile(target_pile))
		return true

	var cell: int = _world_to_cell_idx(drop_global)
	if cell == -1:
		cell = _world_to_cell_idx(pile.global_position)
	if cell == -1 and not allow_out_of_bounds:
		emit_signal("drop_rejected", pile, "out_of_bounds")
		return false
	if cell == -1 and allow_out_of_bounds:
		emit_signal("drop_rejected", pile, "no_snap_region")
		return false

	var moving_into_own_blocked := false
	if cell != -1 and is_cell_forbidden(cell):
		var owner: PileManager = _owner_of_forbidden_cell(cell)
		if owner == pile:
			moving_into_own_blocked = true
		else:
			emit_signal("drop_rejected", pile, "forbidden_cell")
			return false

	if moving_into_own_blocked:
		var src_cell_direct: int = _find_cell_by_pile(pile)
		if src_cell_direct >= 0:
			_vacate_if(src_cell_direct, pile)
		_occupancy[cell] = pile
		_animate_pile_to_position(pile, cell)
		emit_signal("pile_dropped_to_cell", pile, cell)
		return true

	var src_cell2: int = _find_cell_by_pile(pile)
	var dst_pile2: PileManager = _ensure_pile(cell)
	if dst_pile2 == null:
		emit_signal("drop_rejected", pile, "forbidden_cell")
		return false

	if dst_pile2 != pile:
		var cards2: Array = pile.get_cards()
		for c2 in cards2:
			dst_pile2.add_card(c2)
		pile.queue_free()

	_animate_pile_to_position(dst_pile2, cell)
	_occupancy[cell] = dst_pile2
	_vacate_if(src_cell2, pile)
	emit_signal("pile_dropped_to_cell", dst_pile2, cell)
	return true

# =========================
# —— 私有：堆管理 —— 
# =========================
## 确保单元格上有堆，若无则创建
func _ensure_pile(cell: int) -> PileManager:
	if is_cell_forbidden(cell):
		push_error("Cannot ensure pile on forbidden cell: %d" % cell)
		return null
	var existing: PileManager = get_pile(cell)
	if existing != null:
		return existing
	if pile_scene == null:
		push_error("No pile scene specified for instantiation")
		return null
	var pile_node: Node2D = pile_scene.instantiate() as Node2D
	if not pile_node:
		push_error("Failed to instantiate pile scene")
		return null
	add_child(pile_node)
	pile_node.global_position = get_cell_pos(cell)
	var mgr: PileManager = pile_node as PileManager
	if mgr != null:
		mgr.card_pixel_size = card_pixel_size
	_occupancy[cell] = mgr
	return mgr

## 查找堆所在的单元格
func _find_cell_by_pile(pile: PileManager) -> int:
	for i in range(cols * rows):
		if _occupancy.get(i, null) == pile:
			return i
	return -1

## 清理指定单元格的占用记录
func _vacate_if(cell: int, pile: PileManager) -> void:
	if cell >= 0 and _occupancy.get(cell, null) == pile:
		_occupancy[cell] = null

# =========================
# —— 坐标换算 & 命中判定 —— 
# =========================
## 将全局坐标转换为行列坐标
func _world_to_cell_cr(world: Vector2) -> Vector2i:
	var local: Vector2 = to_local(world)
	var cx: int = int(floor((local.x - origin.x) / _step_size().x))
	var cy: int = int(floor((local.y - origin.y) / _step_size().y))
	return Vector2i(cx, cy)

## 将全局坐标转换为单元格索引
func _world_to_cell_idx(world: Vector2) -> int:
	var cr: Vector2i = _world_to_cell_cr(world)
	if cr.x < 0 or cr.y < 0 or cr.x >= cols or cr.y >= rows:
		return -1
	var cell: int = _idx(cr.x, cr.y)
	var rect_g: Rect2 = _cell_rect(cr.x, cr.y, true)
	var center_g: Vector2 = rect_g.position + rect_g.size * 0.5
	var diag: float = rect_g.size.length()
	var radius: float = 0.5 * diag * clamp(snap_radius_ratio, 0.0, 2.0)
	return cell if world.distance_to(center_g) <= radius else -1

## 检查单元格索引是否有效
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
			var rect: Rect2 = _cell_rect(c, r)
			if grid_fill:
				draw_rect(rect, grid_fill_color, true)
			if grid_outline:
				draw_rect(rect, grid_outline_color, false, grid_outline_width)
			var cell: int = _idx(c, r)
			if show_blocked_overlay and forbidden_cells.has(cell):
				draw_rect(rect, blocked_fill_color, true)
				draw_rect(rect, blocked_outline_color, false, blocked_outline_width)
			if show_centers:
				draw_circle(_cell_centers[idx], 3.0, center_color)
			idx += 1

# =========================
# —— 堆命中检测 —— 
# =========================
## 收集当前存在的堆（去重）
func _iter_piles() -> Array[PileManager]:
	var out: Array[PileManager] = []
	var seen: Dictionary = {}
	for i in range(cols * rows):
		var p: PileManager = _occupancy.get(i, null)
		if p != null and is_instance_valid(p) and not seen.has(p):
			seen[p] = true
			out.append(p)
	return out

## 在指定点挑选命中的堆（优先 z 最高者）
func _pick_pile_at_point(point: Vector2) -> PileManager:
	var cr: Vector2i = _world_to_cell_cr(point)
	var candidates: Array[PileManager] = []
	for r in range(max(0, cr.y - 1), min(rows, cr.y + 2)):
		for c in range(max(0, cr.x - 1), min(cols, cr.x + 2)):
			var cell: int = _idx(c, r)
			var pile := _occupancy.get(cell, null) as PileManager
			if pile != null and is_instance_valid(pile):
				candidates.append(pile)

	var best: PileManager = null
	var best_z: int = -1
	for pile in candidates:
		if _point_hits_pile_top_card(point, pile):
			var z_top: int = 0
			var cards: Array = pile.get_cards()
			if cards.size() > 0:
				var top_card := cards[cards.size() - 1] as Node2D
				if top_card != null:
					z_top = top_card.z_index
			if z_top >= best_z:
				best_z = z_top
				best = pile
	return best

## 检查点是否命中堆的顶牌
func _point_hits_pile_top_card(point: Vector2, pile: PileManager) -> bool:
	var cards: Array = pile.get_cards()
	if cards.size() == 0:
		return false
	var top_card := cards[cards.size() - 1] as Node2D
	if top_card == null:
		return false
	var size_px: Vector2 = pile.card_pixel_size * top_card.scale
	var half: Vector2 = size_px * 0.5
	var topleft: Vector2 = top_card.global_position - half
	var rect := Rect2(topleft, size_px)
	return rect.has_point(point)

# =========================
# —— 挤压逻辑 —— 
# =========================
## 挤压被占用的单元格
func displace_if_needed(blocking_pile: PileManager, cell: int, avoid_cells: Array[int]) -> void:
	var victim: PileManager = _occupancy.get(cell, null)
	if victim == null or not is_instance_valid(victim) or victim == blocking_pile:
		return
	var visited: Dictionary = {}
	var candidates: Array[int] = _preferred_destinations(cell, avoid_cells)
	_push_chain(victim, candidates, visited, avoid_cells, 0)

## 生成首选目的地序列
func _preferred_destinations(from_cell: int, avoid_cells: Array[int]) -> Array[int]:
	var out: Array[int] = []
	var avoid: Dictionary = {}
	for a: int in avoid_cells:
		avoid[a] = true
	var rc: Vector2i = _rc(from_cell)
	var below_r: int = rc.y + 1
	if below_r < rows:
		for r: int in range(below_r, rows):
			var cidx: int = _idx(rc.x, r)
			if not avoid.has(cidx) and not is_cell_forbidden(cidx):
				out.append(cidx)
	else:
		var dirs: Array[int] = [-1, 1]
		if randi() % 2 == 1:
			dirs = [1, -1]
		for dx: int in dirs:
			var cx: int = rc.x + dx
			if cx >= 0 and cx < cols:
				var cidx2: int = _idx(cx, rc.y)
				if not avoid.has(cidx2) and not is_cell_forbidden(cidx2):
					out.append(cidx2)
	return out

## 递归挤压堆
func _push_chain(pile: PileManager, candidates: Array[int], visited: Dictionary, avoid_cells: Array[int], depth: int) -> bool:
	if depth > MAX_RECURSION_DEPTH:
		push_warning("Max recursion depth reached in _push_chain")
		return false
	if pile == null or not is_instance_valid(pile) or visited.has(pile):
		return false
	visited[pile] = true
	for dest: int in candidates:
		if dest < 0 or not _valid_cell(dest) or is_cell_forbidden(dest):
			continue
		var occ: PileManager = _occupancy.get(dest, null)
		if occ == null or not is_instance_valid(occ):
			_move_pile_to_cell(pile, dest)
			return true
		if occ == pile:
			continue
		var deeper: Array[int] = _preferred_destinations(dest, avoid_cells)
		if _push_chain(occ, deeper, visited, avoid_cells, depth + 1):
			_move_pile_to_cell(pile, dest)
			return true
	return false

## 移动堆到指定单元格
func _move_pile_to_cell(pile: PileManager, dest_cell: int) -> void:
	if pile == null or not is_instance_valid(pile) or not _valid_cell(dest_cell) or is_cell_forbidden(dest_cell):
		return
	var src_cell: int = _find_cell_by_pile(pile)
	if src_cell == dest_cell:
		return
	if src_cell >= 0:
		_occupancy[src_cell] = null
	_occupancy[dest_cell] = pile
	_animate_pile_to_position(pile, dest_cell)

## 动画移动堆到指定单元格
func _animate_pile_to_position(pile: PileManager, cell: int) -> void:
	var dst_pos: Vector2 = get_cell_pos(cell)
	if pile == null or not is_instance_valid(pile):
		return

	var anim := _ensure_anim_on(pile)

	# 一次性连接，避免重复，无需手动断开
	anim.on_finished.connect(func ():
		if is_instance_valid(pile):
			pile.reflow_visuals()
			if pile.has_method("_update_blocked_cells"):
				pile.call("_update_blocked_cells")
	, CONNECT_ONE_SHOT)

	# 时长/曲线走 CardAnimation 的 Inspector（dur=-1 表示用默认）
	anim.tween_to(dst_pos, -1.0, -1.0)


## 检查单元格是否被其他堆禁用
func _is_blocked_by_other_pile(cell: int, owner: PileManager) -> bool:
	for p: PileManager in _iter_piles():
		if p == null or not is_instance_valid(p) or p == owner:
			continue
		if p.has_method("owns_blocked_cell") and bool(p.call("owns_blocked_cell", cell)):
			return true
	return false

## 获取禁用格的所有者堆
func _owner_of_forbidden_cell(cell: int) -> PileManager:
	if not is_cell_forbidden(cell):
		return null
	var rc_target: Vector2i = _rc(cell)
	var step_h: float = _step_size().y
	for r in range(rc_target.y - 1, -1, -1):
		var above_cell: int = _idx(rc_target.x, r)
		var p := _occupancy.get(above_cell, null) as PileManager
		if p == null or not is_instance_valid(p):
			continue
		var cards_count: int = p.get_cards().size() if p.has_method("get_cards") else 0
		var visible_ratio: float = p.visible_ratio if "visible_ratio" in p else DEFAULT_VISIBLE_RATIO
		var card_h: float = p.card_pixel_size.y if "card_pixel_size" in p else card_pixel_size.y
		var pile_height_px: float = card_h * visible_ratio * float(max(cards_count - 1, 0))
		var rows_covered: int = int(ceil(pile_height_px / max(step_h, 0.0001)))
		var delta_rows: int = rc_target.y - r
		if delta_rows <= rows_covered and rows_covered > 0:
			return p
	return null

# ===== GridManager.gd：替换 _ensure_anim_on =====
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


# ===== GridManager.gd：新增：动画模板工具 =====
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
