extends Node2D
class_name GridSnapManager

# —— 基本设置 —— 
@export var background: NodePath
@export_range(0.0, 0.45, 0.01) var edge_exclude_ratio := 0.10
@export var margin_left := 0.0
@export var margin_right := 0.0
@export var margin_top := 0.0
@export var margin_bottom := 0.0

# 卡面与缩放
@export var card_pixel_size := Vector2(47, 64)
@export_range(0.1, 3.0, 0.05) var global_card_scale := 0.5

# 槽间距
@export var gap_x := 8.0
@export var gap_y := 8.0

# 堆叠：上层覆盖 85% → 下层仅露 15%
@export_range(0.05, 0.4, 0.01) var visible_ratio := 0.15

# 每堆最大层数
@export_range(1, 99, 1) var max_stack_size := 30

# 调试
@export var debug_show_grid := true
@export var debug_line_alpha := 0.25
@export var debug_show_blocked := true

# 子堆跟随“丝滑”系数（这里保留开关，不做插值）
@export_range(0.0, 1.0, 0.01) var group_follow_lerp := 0.45

# —— 合并策略 —— 
# true  = 来者在下、旧堆在上 → incoming + existing（AB + C → A,B,C；C 最顶）
# false = 来者在上、旧堆在下 → existing + incoming（C + AB → C,A,B；C 最底）
@export var place_incoming_below_existing: bool = false

# 悬停期间覆盖层级（确保拖拽组永远盖住目标堆）
@export var drag_overlay_z_base: int = 20000

const INVALID_CELL := Vector2i(-9999, -9999)

var _bg_sprite: Sprite2D = null

# Vector2i -> Array[Node2D]
var _occupied: Dictionary = {}
# Vector2i -> true
var _blocked: Dictionary = {}

# 组拖拽
var _group_leader: Node2D = null
var _group_cards: Array[Node2D] = []
var _group_from_grid: Vector2i = INVALID_CELL
var _group_offsets: Array[Vector2] = []
var _group_active: bool = false

# 拖拽中是否允许子堆逐帧跟随
var _group_follow_enabled: bool = true

# 还原信息（跟随牌）
# card -> { "parent":Node, "index":int, "top_level":bool, "z":int, "zrel":bool, "used_drag_layer":bool }
var _followers_restore: Dictionary = {}

# 拖拽中的“相对 z”缓存：card -> rel_z（以该组最小原z为 0）
var _drag_rel_z: Dictionary = {}

# 拖拽结束时是否恢复旧 z（成功吸附时为 false；失败回弹为 true）
var _restore_z_after_drag: bool = true

func _ready() -> void:
	add_to_group("snap_manager")
	if background != NodePath():
		_bg_sprite = get_node_or_null(background) as Sprite2D
	_sanitize_params()
	set_process(true)
	queue_redraw()

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		queue_redraw()

func _sanitize_params() -> void:
	edge_exclude_ratio = clamp(edge_exclude_ratio, 0.0, 0.45)
	gap_x = max(gap_x, 0.0)
	gap_y = max(gap_y, 0.0)
	visible_ratio = clamp(visible_ratio, 0.05, 0.4)
	max_stack_size = clamp(max_stack_size, 1, 99)

# —— 便捷：找到动画总控（当前无动画，仅占位）—— 
func _anim() -> Node:
	return get_tree().get_first_node_in_group("anim_orchestrator")

# ========== Drag 权限 ==========
func can_drag(card: Node2D) -> bool:
	if card == _group_leader and _group_cards.size() >= 1:
		return true
	if card.has_meta("is_snapping") and card.get_meta("is_snapping") == true:
		return false
	var g: Vector2i = _get_card_grid(card)
	if g == INVALID_CELL: return true
	if not _occupied.has(g): return true
	var stack: Array = _occupied[g]
	return (not stack.is_empty() and stack.back() == card)

func is_group_active_for(card: Node2D) -> bool:
	return _group_active and _group_leader == card and _group_cards.size() >= 1

# ========== 点击拾取（顶牌整张、下层仅牌眉） ==========
func pick_card_at(point: Vector2) -> Node2D:
	var rect: Rect2 = _calc_snap_rect()
	var cell: Vector2 = _cell_size()
	var pitch: Vector2 = _pitch_size()
	var cols: int = int(floor((rect.size.x + gap_x) / pitch.x))
	var rows: int = int(floor((rect.size.y + gap_y) / pitch.y))
	if cols <= 0 or rows <= 0:
		return null
	return _pick_card_by_point(point, rect, cell, pitch)

func _pick_card_by_point(point: Vector2, rect: Rect2, cell: Vector2, pitch: Vector2) -> Node2D:
	var best_card: Node2D = null
	var best_z: int = -2147483648
	for key in _occupied.keys():
		var g: Vector2i = key
		var stack: Array = _occupied[g]
		if stack.is_empty(): continue
		var center: Vector2 = rect.position + Vector2(
			g.x * pitch.x + pitch.x * 0.5,
			g.y * pitch.y + pitch.y * 0.5
		)
		var layer_offset: Vector2 = Vector2(0, cell.y * visible_ratio)
		var base_z: int = 100 + g.y * 10
		for i in range(stack.size() - 1, -1, -1):
			var c: Node2D = stack[i]
			var card_pos: Vector2 = center + layer_offset * i
			var tl: Vector2 = card_pos - cell * 0.5

			var click_rect: Rect2
			if i == stack.size() - 1:
				click_rect = Rect2(tl, cell)  # 顶牌整张可点
			else:
				var header_h: float = cell.y * visible_ratio
				click_rect = Rect2(tl, Vector2(cell.x, header_h))  # 下层仅牌眉

			if click_rect.has_point(point):
				var z_here: int = base_z + i
				if z_here > best_z:
					best_z = z_here
					best_card = c
	return best_card

# ========== 吸附（单卡/子堆） ==========
func try_snap(card: Node2D, original_pos: Vector2) -> bool:
	_sanitize_params()

	var rect: Rect2 = _calc_snap_rect()
	var cell: Vector2 = _cell_size()
	var pitch: Vector2 = _pitch_size()
	var cols: int = int(floor((rect.size.x + gap_x) / pitch.x))
	var rows: int = int(floor((rect.size.y + gap_y) / pitch.y))
	if cols <= 0 or rows <= 0:
		_fail_return(card, original_pos); return false

	var drop_point: Vector2 = card.global_position
	var grid_bounds: Rect2 = _grid_bounds(rect, cell, pitch, cols, rows)
	if not grid_bounds.has_point(drop_point):
		_fail_return(card, original_pos); return false

	var use_group := (_group_active and _group_leader == card and _group_cards.size() >= 1)
	var group_cards: Array[Node2D] = []
	if use_group:
		for c in _group_cards: group_cards.append(c)
	else:
		group_cards.append(card)
	var incoming_count := group_cards.size()

	# 1) 目标格
	var local: Vector2 = drop_point - rect.position
	var gx: int = int(floor(local.x / pitch.x))
	var gy: int = int(floor(local.y / pitch.y))
	gx = clamp(gx, 0, cols - 1)
	gy = clamp(gy, 0, rows - 1)
	var g: Vector2i = Vector2i(gx, gy)

	# 2) 命中堆 → 指向底格
	var forced_stack_grid: Vector2i = _find_stack_base_by_point(drop_point, rect, cell, pitch)
	var force_stack: bool = (forced_stack_grid != INVALID_CELL)
	if force_stack: g = forced_stack_grid

	# 容量预检
	if _occupied.has(g):
		var s_pre_arr: Array = _occupied[g]
		var place_same_grid := (_get_card_grid(card) == g)
		var same_grid_no_growth := false
		if place_same_grid and use_group:
			var k := incoming_count
			if k <= s_pre_arr.size():
				var ok := true
				for i in range(k):
					if s_pre_arr[s_pre_arr.size() - 1 - i] != group_cards[k - 1 - i]:
						ok = false; break
				same_grid_no_growth = ok
		if (not same_grid_no_growth) and (s_pre_arr.size() + incoming_count > max_stack_size):
			_fail_return(card, original_pos); return false

	# 被遮挡预检（含“上移解除遮挡”特例）
	if (not force_stack) and _is_blocked(g):
		var allow_unblock_move := false
		var old_grid_for_block: Vector2i = _get_card_grid(card)
		if old_grid_for_block != INVALID_CELL:
			if old_grid_for_block.x == g.x and old_grid_for_block.y + 1 == g.y:
				if _occupied.has(old_grid_for_block):
					var size_before: int = (_occupied[old_grid_for_block] as Array).size()
					var need := (incoming_count if use_group else 1)
					var size_after: int = max(0, size_before - need)
					var total_h_after: float = 0.0
					if size_after >= 1:
						total_h_after = cell.y + float(size_after - 1) * (cell.y * visible_ratio)
					var overhang_after: float = total_h_after - (cell.y + gap_y)
					if overhang_after <= 0.0:
						allow_unblock_move = true
		if not allow_unblock_move:
			_fail_return(card, original_pos); return false

	# 让位计算
	var old_grid: Vector2i = _get_card_grid(card)
	var stack_here_size: int = ( (_occupied[g] as Array).size() if _occupied.has(g) else 0 )
	var place_same_grid := (old_grid == g)
	var same_grid_no_growth := false
	if place_same_grid and _occupied.has(g) and use_group:
		var s_tmp: Array = _occupied[g]
		if incoming_count <= s_tmp.size():
			var ok2 := true
			for i in range(incoming_count):
				if s_tmp[s_tmp.size() - 1 - i] != group_cards[incoming_count - 1 - i]:
					ok2 = false; break
			same_grid_no_growth = ok2

	var new_layers: int = stack_here_size + (0 if same_grid_no_growth else incoming_count)
	if new_layers <= 0: new_layers = 1

	var total_h: float = cell.y + float(new_layers - 1) * (cell.y * visible_ratio)
	var overhang: float = total_h - (cell.y + gap_y)
	var extra_rows: int = 0
	if overhang > 0.0:
		extra_rows = int(ceil(overhang / pitch.y))

	var planned_moves: Array = []
	if extra_rows > 0:
		var old_will_empty := false
		if old_grid != INVALID_CELL and _occupied.has(old_grid):
			var old_st_pre: Array = _occupied[old_grid]
			var need_move := (incoming_count if use_group else 1)
			old_will_empty = (old_st_pre.size() == need_move)
		var first_safe_y: int = g.y + extra_rows + 1
		var reserved: Dictionary = {}
		for k in range(1, extra_rows + 1):
			var gy2: int = g.y + k
			if gy2 >= rows: break
			var below: Vector2i = Vector2i(g.x, gy2)
			if _occupied.has(below):
				if below == old_grid and old_will_empty: continue
				var start_search_y: int = max(first_safe_y, gy2)
				var target_y: int = _find_first_free_in_column(g.x, start_search_y, rows, reserved)
				if target_y == -1:
					_fail_return(card, original_pos); return false
				var to_g2: Vector2i = Vector2i(g.x, target_y)
				reserved[to_g2] = true
				planned_moves.append([below, to_g2])

	# 执行让位 + 合并
	if not same_grid_no_growth:
		for c_rm in group_cards: _safe_remove_from_stack(c_rm)
	for pair in planned_moves: _move_stack_to(pair[0], pair[1], rect, cell, pitch)

	if not _occupied.has(g):
		var empty_stack: Array[Node2D] = []
		_occupied[g] = empty_stack

	# —— 合并 —— 
	if not same_grid_no_growth:
		var existing: Array = _occupied[g]
		var new_stack: Array[Node2D] = []
		if place_incoming_below_existing:
			for c_in in group_cards: new_stack.append(c_in)
			for c_ex in existing:   new_stack.append(c_ex)
		else:
			for c_ex in existing:   new_stack.append(c_ex)
			for c_in in group_cards: new_stack.append(c_in)
		_occupied[g] = new_stack
		for c_all in new_stack: _set_card_grid(c_all, g)

	# —— 落位：暂停跟随，统一落位（瞬移） —— 
	if use_group: _group_follow_enabled = false

	_update_stack_visual(g, [])  # 直接瞬移
	_rebuild_blocked(cols, rows, rect, cell, pitch)

	# ✅ 成功吸附：不要恢复旧 z，交由 _update_stack_visual 的新 z 生效
	_restore_z_after_drag = false

	# 直接结束组拖（无动画延迟）
	end_group_drag(card)

	return true

# ========== 失败统一回弹（瞬移） ==========
func _fail_return(card: Node2D, original_pos: Vector2) -> void:
	_restore_z_after_drag = true
	if _group_active and _group_leader == card and _group_cards.size() > 1:
		_group_return(original_pos)
		end_group_drag(card)
	else:
		_animate_back_to(card, original_pos)
		end_group_drag(card)

func _group_return(leader_original_pos: Vector2) -> void:
	if _group_cards.size() <= 1:
		if _group_leader: _animate_back_to(_group_leader, leader_original_pos)
		return
	if _group_leader: _animate_back_to(_group_leader, leader_original_pos)
	for i in range(_group_cards.size()):
		var c: Node2D = _group_cards[i]
		if c == _group_leader: continue
		var target: Vector2 = leader_original_pos + _group_offsets[i]
		_animate_back_to(c, target)

# ========== 组拖拽 ==========
func prepare_drag_group(card: Node2D, _click_pos_global: Vector2) -> void:
	_group_clear()
	_drag_rel_z.clear()
	_group_follow_enabled = true
	_restore_z_after_drag = true

	var g: Vector2i = _get_card_grid(card)
	if g == INVALID_CELL:
		_group_leader = card
		_group_cards.clear(); _group_cards.append(card)
		_group_from_grid = INVALID_CELL
		_group_offsets.clear(); _group_offsets.append(Vector2.ZERO)
		return

	if not _occupied.has(g): return
	var stack: Array = _occupied[g]
	if stack.is_empty(): return

	var start_index: int = stack.find(card)
	if start_index == -1: return

	_group_cards.clear()
	for i in range(start_index, stack.size()):
		_group_cards.append(stack[i])

	_group_leader = stack[start_index]
	_group_from_grid = g

	_group_offsets.clear()
	_group_offsets.append(Vector2.ZERO)
	var leader_pos: Vector2 = _group_leader.global_position
	for i in range(1, _group_cards.size()):
		var c: Node2D = _group_cards[i]
		_group_offsets.append(c.global_position - leader_pos)

	var min_z: int = 1 << 30
	for c in _group_cards:
		if c.z_index < min_z: min_z = c.z_index
	for c in _group_cards:
		_drag_rel_z[c] = int(c.z_index - min_z)

func begin_group_drag(card: Node2D) -> void:
	if _group_leader != card or _group_cards.size() <= 1: return
	_group_active = true
	_followers_restore.clear()
	var drag_layer: CanvasLayer = _get_drag_layer()
	for i in range(_group_cards.size()):
		var c: Node2D = _group_cards[i]
		c.set_meta("group_dragging", true)
		var info: Dictionary = {
			"parent": c.get_parent(),
			"index": int(c.get_index()),
			"top_level": bool(c.top_level),
			"z": int(c.z_index),
			"zrel": bool(c.z_as_relative),
			"used_drag_layer": false
		}
		_followers_restore[c] = info
		if drag_layer != null:
			var gp: Vector2 = c.global_position
			c.reparent(drag_layer)
			c.global_position = gp
			info["used_drag_layer"] = true
			_followers_restore[c] = info
		else:
			c.top_level = true
		var rel_z: int = int(_drag_rel_z.get(c, 0))
		c.z_as_relative = false
		c.z_index = drag_overlay_z_base + rel_z

# 外部可能会在鼠标松手后立刻调到这里；（无动画延迟，直接收尾）
func end_group_drag(_card: Node2D) -> void:
	_really_end_group_drag()

func _really_end_group_drag() -> void:
	for c in _followers_restore.keys():
		var info: Dictionary = _followers_restore[c]
		if info.has("used_drag_layer") and info["used_drag_layer"]:
			var parent: Node = info["parent"]
			var idx: int = info["index"]
			if is_instance_valid(parent):
				if idx > parent.get_child_count(): idx = parent.get_child_count()
				var gp: Vector2 = c.global_position
				c.reparent(parent, idx)
				c.global_position = gp
		else:
			c.top_level = bool(info["top_level"])

		# ✅ 仅在需要时恢复 z；成功吸附则保持新 z（由 _update_stack_visual 设置）
		if _restore_z_after_drag:
			c.z_as_relative = bool(info["zrel"])
			c.z_index = int(info["z"])

		if c.has_meta("group_dragging"):
			c.set_meta("group_dragging", false)

	_followers_restore.clear()
	_drag_rel_z.clear()
	_group_clear()

func _group_clear() -> void:
	_group_leader = null
	_group_cards.clear()
	_group_from_grid = INVALID_CELL
	_group_offsets.clear()
	_group_active = false

# —— 子堆拖拽跟随（立即跟随，不再插值） —— 
func _process(_delta: float) -> void:
	if _group_active and _group_follow_enabled and _group_leader != null and _group_cards.size() > 1:
		var lp: Vector2 = _group_leader.global_position
		for i in range(_group_cards.size()):
			var c: Node2D = _group_cards[i]
			if c == _group_leader: continue
			var target: Vector2 = lp + _group_offsets[i]
			c.global_position = target

# ========== 工具 ==========
func _get_drag_layer() -> CanvasLayer:
	var best: CanvasLayer = null
	for n in get_tree().get_nodes_in_group("drag_layer"):
		if n is CanvasLayer:
			if best == null or (n as CanvasLayer).layer > best.layer:
				best = n as CanvasLayer
	return best

func _find_first_free_in_column(col_x: int, start_y: int, rows: int, reserved: Dictionary) -> int:
	var y_start: int = max(0, start_y)
	for yy in range(y_start, rows):
		var key: Vector2i = Vector2i(col_x, yy)
		var occupied_now: bool = _occupied.has(key)
		var reserved_now: bool = reserved.has(key)
		if not occupied_now and not reserved_now:
			return yy
	return -1

func _move_stack_to(from_g: Vector2i, to_g: Vector2i, rect: Rect2, cell: Vector2, pitch: Vector2) -> void:
	if from_g == to_g: return
	if not _occupied.has(from_g): return
	if _occupied.has(to_g): return
	var stack: Array = _occupied[from_g]
	_occupied.erase(from_g)
	_occupied[to_g] = stack
	var center: Vector2 = rect.position + Vector2(
		to_g.x * pitch.x + pitch.x * 0.5,
		to_g.y * pitch.y + pitch.y * 0.5
	)
	var layer_offset: Vector2 = Vector2(0, cell.y * visible_ratio)
	var base_z: int = 100 + to_g.y * 10
	for i in range(stack.size()):
		var c: Node2D = stack[i]
		_set_card_grid(c, to_g)
		c.z_index = base_z + i
		var target: Vector2 = center + layer_offset * i
		# 直接瞬移
		c.global_position = target
		if c.has_meta("is_snapping"): c.set_meta("is_snapping", false)

func _find_stack_base_by_point(point: Vector2, rect: Rect2, cell: Vector2, pitch: Vector2) -> Vector2i:
	var best_grid: Vector2i = INVALID_CELL
	var best_z: int = -1
	for key in _occupied.keys():
		var g: Vector2i = key
		var stack: Array = _occupied[g]
		if stack.is_empty(): continue
		var center: Vector2 = rect.position + Vector2(
			g.x * pitch.x + pitch.x * 0.5,
			g.y * pitch.y + pitch.y * 0.5
		)
		var layer_offset: Vector2 = Vector2(0, cell.y * visible_ratio)
		var base_z: int = 100 + g.y * 10
		for i in range(stack.size() - 1, -1, -1):
			var card_pos: Vector2 = center + layer_offset * i
			var tl: Vector2 = card_pos - cell * 0.5
			var r: Rect2 = Rect2(tl, cell)
			if r.has_point(point):
				var z_here: int = base_z + i
				if z_here > best_z:
					best_z = z_here
					best_grid = g
				break
	return best_grid

# ========== 栈与阻塞 ==========
func _get_card_grid(card: Node2D) -> Vector2i:
	if card.has_meta("grid"):
		var v: Variant = card.get_meta("grid")
		if typeof(v) == TYPE_VECTOR2I: return v
	return INVALID_CELL

func _set_card_grid(card: Node2D, g: Vector2i) -> void:
	card.set_meta("grid", g)

func _safe_remove_from_stack(card: Node2D) -> void:
	var g: Vector2i = _get_card_grid(card)
	if g == INVALID_CELL: return
	if _occupied.has(g):
		var stack: Array = _occupied[g]
		var idx: int = stack.find(card)
		if idx != -1:
			stack.remove_at(idx)
			if stack.is_empty(): _occupied.erase(g)
			else: _occupied[g] = stack
			_update_stack_visual(g, [])  # 重排（瞬移）
	card.set_meta("grid", null)

func _stack_push(g: Vector2i, card: Node2D) -> void:
	var stack: Array = []
	if _occupied.has(g): stack = _occupied[g]
	stack.append(card)
	_occupied[g] = stack
	_set_card_grid(card, g)

# —— 统一落位展示（瞬移；animate_cards 参数忽略） —— 
func _update_stack_visual(g: Vector2i, _animate_cards: Array = []) -> void:
	var rect: Rect2 = _calc_snap_rect()
	var cell: Vector2 = _cell_size()
	var pitch: Vector2 = _pitch_size()
	var cols: int = int(floor((rect.size.x + gap_x) / pitch.x))
	var rows: int = int(floor((rect.size.y + gap_y) / pitch.y))
	if cols <= 0 or rows <= 0: return
	if g.x < 0 or g.y < 0: return
	if not _occupied.has(g): return

	var center: Vector2 = rect.position + Vector2(g.x * pitch.x + pitch.x * 0.5, g.y * pitch.y + pitch.y * 0.5)
	var stack: Array = _occupied[g]
	var layer_offset: Vector2 = Vector2(0, cell.y * visible_ratio)
	var base_z: int = 100 + g.y * 10

	for i in range(stack.size()):
		var c: Node2D = stack[i]
		var target: Vector2 = center + layer_offset * i
		c.z_index = base_z + i
		_set_card_grid(c, g)
		# 直接瞬移
		c.global_position = target
		if c.has_meta("is_snapping"): c.set_meta("is_snapping", false)

func _rebuild_blocked(cols: int, rows: int, rect: Rect2, cell: Vector2, pitch: Vector2) -> void:
	_blocked.clear()
	for key in _occupied.keys():
		var g: Vector2i = key
		var stack: Array = _occupied[g]
		if stack.is_empty(): continue

		var layers: int = stack.size()
		var total_h: float = cell.y + float(layers - 1) * (cell.y * visible_ratio)
		var overhang: float = total_h - (cell.y + gap_y)
		if overhang <= 0.0: continue

		var extra_rows: int = int(ceil(overhang / pitch.y))
		for k in range(1, extra_rows + 1):
			var gy: int = g.y + k
			if gy >= rows: break
			_blocked[Vector2i(g.x, gy)] = true
	queue_redraw()

func _is_blocked(g: Vector2i) -> bool:
	return _blocked.has(g)

# ========== 动画（已改为瞬移实现） ==========
func _animate_back_to(card: Node2D, target: Vector2) -> void:
	card.global_position = target
	if card.has_meta("is_snapping"): card.set_meta("is_snapping", false)

# ========== 绘制 / 几何 ==========
func _draw() -> void:
	if not debug_show_grid: return
	var rect: Rect2 = _calc_snap_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0: return

	var cell: Vector2 = _cell_size()
	var pitch: Vector2 = _pitch_size()
	if pitch.x <= 0.0 or pitch.y <= 0.0: return

	var cols: int = int(floor((rect.size.x + gap_x) / pitch.x))
	var rows: int = int(floor((rect.size.y + gap_y) / pitch.y))
	if cols <= 0 or rows <= 0: return

	var grid_bounds: Rect2 = _grid_bounds(rect, cell, pitch, cols, rows)
	draw_rect(grid_bounds, Color(1,1,1,debug_line_alpha * 0.8), false, 1.0)

	var color := Color(1,1,1,debug_line_alpha)
	for y in range(rows):
		for x in range(cols):
			var center: Vector2 = rect.position + Vector2(
				x * pitch.x + pitch.x * 0.5,
				y * pitch.y + pitch.y * 0.5
			)
			var top_left: Vector2 = center - cell * 0.5
			draw_rect(Rect2(top_left, cell), color, false, 1.0)

	if debug_show_blocked and _blocked.size() > 0:
		var blocked_color := Color(1, 0, 0, debug_line_alpha * 0.5)
		for key in _blocked.keys():
			var g: Vector2i = key
			var center_b: Vector2 = rect.position + Vector2(g.x * pitch.x + pitch.x * 0.5, g.y * pitch.y + pitch.y * 0.5)
			var tl: Vector2 = center_b - cell * 0.5
			draw_rect(Rect2(tl, cell), blocked_color, false, 2.0)

func _grid_bounds(rect: Rect2, cell: Vector2, pitch: Vector2, cols: int, rows: int) -> Rect2:
	var top_left: Vector2 = rect.position + Vector2(gap_x * 0.5, gap_y * 0.5)
	var bottom_right: Vector2 = rect.position + Vector2(cols * pitch.x - gap_x * 0.5, rows * pitch.y - gap_y * 0.5)
	return Rect2(top_left, bottom_right - top_left)

func _calc_snap_rect() -> Rect2:
	var bg_rect: Rect2 = _background_rect()
	if bg_rect.size.x <= 0.0 or bg_rect.size.y <= 0.0: return Rect2()
	var inset_x: float = bg_rect.size.x * edge_exclude_ratio
	var inset_y: float = bg_rect.size.y * edge_exclude_ratio
	var pos: Vector2 = bg_rect.position + Vector2(inset_x, inset_y)
	var size: Vector2 = bg_rect.size - Vector2(inset_x * 2.0, inset_y * 2.0)
	pos.x += margin_left
	pos.y += margin_top
	size.x -= (margin_left + margin_right)
	size.y -= (margin_top + margin_bottom)
	if size.x < 0.0: size.x = 0.0
	if size.y < 0.0: size.y = 0.0
	return Rect2(pos, size)

# 背景矩形（考虑 centered / offset / scale；无背景时以世界原点为中心）
func _background_rect() -> Rect2:
	if _bg_sprite != null and _bg_sprite.texture != null:
		var tex_size: Vector2 = _bg_sprite.texture.get_size()
		var scl: Vector2 = _bg_sprite.scale.abs()
		var size: Vector2 = tex_size * scl
		var top_left: Vector2 = _bg_sprite.global_position
		if _bg_sprite.centered:
			top_left -= size * 0.5
		top_left -= _bg_sprite.offset * scl
		return Rect2(top_left, size)
	var size_fallback: Vector2 = Vector2(1920, 1080)
	var top_left_fallback: Vector2 = -size_fallback * 0.5
	return Rect2(top_left_fallback, size_fallback)

func _cell_size() -> Vector2:
	return card_pixel_size * global_card_scale

func _pitch_size() -> Vector2:
	return _cell_size() + Vector2(gap_x, gap_y)
