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
	# —— ① 优先：命中任意 pile → 直接并入（不走格子、不理会禁格） ——
	var pile_hit: PileManager = _pick_pile_at_point(drop_global)
	if pile_hit != null:
		# 并入目标堆
		pile_hit.add_card(card)
		pile_hit.reflow_visuals()
		# 目标堆自身会在 reflow 后刷新禁格（若你已加 _update_blocked_cells）
		return true

	# —— ② 回退：原有的 grid snap 逻辑（含禁格） ——
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
	# —— ① 优先：命中其它 pile → 合并堆（不走格子）——
	var target_pile: PileManager = _pick_pile_at_point(drop_global)
	if target_pile != null and target_pile != pile:
		var src_cell: int = _find_cell_by_pile(pile)
		var cards_to_merge: Array = pile.get_cards()
		for c in cards_to_merge:
			target_pile.add_card(c)
		pile.queue_free()
		_vacate_if(src_cell, pile)

		var dst_pos: Vector2 = target_pile.global_position
		var tw := create_tween()
		tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		tw.tween_property(target_pile, "global_position", dst_pos, 0.12)
		tw.finished.connect(func ():
			target_pile.reflow_visuals()
			if target_pile.has_method("_update_blocked_cells"):
				target_pile.call("_update_blocked_cells")
		)

		emit_signal("pile_dropped_to_cell", target_pile, _find_cell_by_pile(target_pile))
		return true

	# —— ② 常规：按格吸附（含禁格判定）——
	var cell: int = _world_to_cell_idx(drop_global)
	if cell == -1:
		cell = _world_to_cell_idx(pile.global_position)
	if cell == -1 and not allow_out_of_bounds:
		emit_signal("drop_rejected", pile, "out_of_bounds")
		return false
	if cell == -1 and allow_out_of_bounds:
		emit_signal("drop_rejected", pile, "no_snap_region")
		return false

	# 命中禁格：仅当该禁格“归属堆”为本堆时才放行
	var moving_into_own_blocked := false
	if cell != -1 and is_cell_forbidden(cell):
		var owner: PileManager = _owner_of_forbidden_cell(cell)
		if owner == pile:
			moving_into_own_blocked = true
		else:
			emit_signal("drop_rejected", pile, "forbidden_cell")
			return false

	# —— 特例：落在“自己禁的格”上 → 直接把这堆移动到该格（不走 _ensure_pile）——
	if moving_into_own_blocked:
		var src_cell_direct: int = _find_cell_by_pile(pile)
		if src_cell_direct >= 0:
			_vacate_if(src_cell_direct, pile)
		_occupancy[cell] = pile

		var dst_pos_direct: Vector2 = get_cell_pos(cell)
		var twd := create_tween()
		twd.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		twd.tween_property(pile, "global_position", dst_pos_direct, 0.12)
		twd.finished.connect(func ():
			pile.reflow_visuals()
			if pile.has_method("_update_blocked_cells"):
				pile.call("_update_blocked_cells")
		)

		emit_signal("pile_dropped_to_cell", pile, cell)
		return true

	# —— ③ 普通格：确保/合并 + tween —— 
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

	dst_pile2.global_position = get_cell_pos(cell)

	var tw2 := create_tween()
	tw2.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw2.tween_property(dst_pile2, "global_position", get_cell_pos(cell), 0.12)
	tw2.finished.connect(func ():
		dst_pile2.reflow_visuals()
		if dst_pile2.has_method("_update_blocked_cells"):
			dst_pile2.call("_update_blocked_cells")
	)

	_occupancy[cell] = dst_pile2
	_vacate_if(src_cell2, pile)
	emit_signal("pile_dropped_to_cell", dst_pile2, cell)
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
	pass

# —— 收集当前存在的 pile（从占用表提取，去重） ——
func _iter_piles() -> Array[PileManager]:
	var out: Array[PileManager] = []
	var seen: Dictionary = {}
	for i in range(cols * rows):
		var p: PileManager = _occupancy.get(i, null)
		if p != null and is_instance_valid(p) and not seen.has(p):
			seen[p] = true
			out.append(p)
	return out

# —— 命中检测：根据鼠标点挑选命中的 pile（优先 z 较高者） ——
func _pick_pile_at_point(point: Vector2) -> PileManager:
	var best: PileManager = null
	var best_z: int = -1

	for child in get_children():
		var pile := child as PileManager
		if pile == null:
			continue

		if _point_hits_pile_top_card(point, pile):
			# 用顶牌 z 决定“视觉上谁在上面”
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


# —— 用“顶牌的包围盒”近似命中（无需依赖 Area2D API，鲁棒性更好） ——
func _point_hits_pile_top_card(point: Vector2, pile: PileManager) -> bool:
	var cards: Array = pile.get_cards()
	if cards.size() == 0:
		return false

	var top_card := cards[cards.size() - 1] as Node2D
	if top_card == null:
		return false

	# 以像素尺寸 × 节点缩放构造顶牌的 AABB（无旋转假设；若你旋转了卡牌可再升级成变换到局部判断）
	var size_px: Vector2 = pile.card_pixel_size * top_card.scale	# 避免写死
	var half: Vector2 = size_px * 0.5
	var topleft: Vector2 = top_card.global_position - half
	var rect := Rect2(topleft, size_px)

	return rect.has_point(point)

# ==== 挤压逻辑：当某格将被禁用时，把占用者往下（或斜下）推开 ====

# 外部入口：由 PileManager._update_blocked_cells() 调用
# avoid_cells: 当前这个 blocking_pile 即将禁用的格子集合，挤压时避开它们
func displace_if_needed(blocking_pile: PileManager, cell: int, avoid_cells: Array[int]) -> void:
	var victim: PileManager = _occupancy.get(cell, null)
	if victim == null or not is_instance_valid(victim):
		return
	if victim == blocking_pile:
		return
	var visited: Dictionary = {}
	# 计算从该 cell 出发的“首选目的地序列”
	var candidates: Array[int] = _preferred_destinations(cell, avoid_cells)
	_push_chain(victim, candidates, visited, avoid_cells)



# 目的地优先序列生成：
# - 若下方仍在网格内：返回“同一列从下一行直到最底行”的候选列表（避开 avoid_cells）
# - 若已在最底行（下方出界）：返回“同一行的左右”候选（随机左右，避开 avoid_cells）
func _preferred_destinations(from_cell: int, avoid_cells: Array[int]) -> Array[int]:
	var out: Array[int] = []
	var avoid: Dictionary = {}
	for a: int in avoid_cells:
		avoid[a] = true

	var rc: Vector2i = _rc(from_cell)
	var below_r: int = rc.y + 1

	if below_r < rows:
		# 直线向下：同列一路到底（从 rc.y+1 到 rows-1）
		for r: int in range(below_r, rows):
			var cidx: int = _idx(rc.x, r)
			if not avoid.has(cidx) and not is_cell_forbidden(cidx):
				out.append(cidx)
	else:
		# 最底行：改为同一行左右平移
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


# 递归挤压：若目的地被占，先把占用者根据“它自己的优先序列”再往后挤
func _push_chain(pile: PileManager, candidates: Array[int], visited: Dictionary, avoid_cells: Array[int]) -> bool:
	if pile == null or not is_instance_valid(pile):
		return false
	if visited.has(pile):
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

		# 目的地被占：按“该占用者自己的规则”生成它的目的地序列，然后尝试把它先挪开
		var deeper: Array[int] = _preferred_destinations(dest, avoid_cells)
		if _push_chain(occ, deeper, visited, avoid_cells):
			_move_pile_to_cell(pile, dest)
			return true

	return false



# 实际移动：更新占用表 + tween + 触发重排与禁用刷新
func _move_pile_to_cell(pile: PileManager, dest_cell: int) -> void:
	if pile == null or not is_instance_valid(pile):
		return
	if not _valid_cell(dest_cell) or is_cell_forbidden(dest_cell):
		return

	# 源格
	var src_cell: int = _find_cell_by_pile(pile)
	if src_cell == dest_cell:
		return

	# 占用表更新
	if src_cell >= 0:
		_occupancy[src_cell] = null
	_occupancy[dest_cell] = pile

	# 动画移动到格中心
	var dst_pos: Vector2 = get_cell_pos(dest_cell)
	var tw := create_tween()
	tw.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(pile, "global_position", dst_pos, 0.12)
	tw.finished.connect(func ():
		pile.reflow_visuals()
		if pile.has_method("_update_blocked_cells"):
			pile.call("_update_blocked_cells")
	)

# 该格是否被“除 owner 以外的其它堆”标记为禁用
func _is_blocked_by_other_pile(cell: int, owner: PileManager) -> bool:
	for p: PileManager in _iter_piles():
		if p == null or not is_instance_valid(p):
			continue
		if p == owner:
			continue
		if p.has_method("owns_blocked_cell") and bool(p.call("owns_blocked_cell", cell)):
			return true
	return false

# —— 计算某禁用格的“所有者堆”
# 条件：同列向上最近、且其覆盖高度足以包含该格
func _owner_of_forbidden_cell(cell: int) -> PileManager:
	if not is_cell_forbidden(cell):
		return null

	var rc_target: Vector2i = _rc(cell)
	var step_h: float = _step_size().y

	# 从目标格上一行开始向上扫描
	for r in range(rc_target.y - 1, -1, -1):
		var above_cell: int = _idx(rc_target.x, r)
		var p := _occupancy.get(above_cell, null) as PileManager
		if p == null or not is_instance_valid(p):
			continue

		# 该堆的“可见叠高”换算为覆盖的行数
		var cards_count: int = 0
		if p.has_method("get_cards"):
			var arr: Array = p.call("get_cards")
			cards_count = arr.size()

		var visible_ratio: float = 0.15
		if "visible_ratio" in p:
			visible_ratio = float(p.visible_ratio)

		var card_h: float = (p.card_pixel_size.y if "card_pixel_size" in p else card_pixel_size.y)
		var pile_height_px: float = card_h * visible_ratio * float(max(cards_count - 1, 0))
		var rows_covered: int = int(ceil(pile_height_px / max(step_h, 0.0001)))

		# 若该堆覆盖到目标格所在行，则它就是归属者
		var delta_rows: int = rc_target.y - r
		if delta_rows <= rows_covered and rows_covered > 0:
			return p

	return null
