extends Node2D
class_name living

# =========================
# —— 可在 Inspector 调参 —— 
# =========================

@export var grid_manager_path: NodePath
@export var sprite_path: NodePath = ^"Sprite2D"
@export var hit_full_path: NodePath = ^"hit_full"

@export var pickup_scale: float = 1.06
@export var drag_z: int = 4094
@export var drag_layer_path: NodePath = ^"/root/DragLayer"

# —— footprint：在 Grid 上占用多少格（默认 2×2）——
@export var footprint_cols: int = 2
@export var footprint_rows: int = 2

# =========================
# —— Upkeep / 维护费参数 —— 
# =========================

@export var upkeep_enabled: bool = true
@export_range(0.1, 600.0, 0.1) var time_spent: float = 5.0  # 一个周期的时间（秒）
@export var cost_money: int = 1                             # 每周期扣多少钱
@export var coin_model_path: NodePath
@export var obey_time_pause: bool = true   # 若有 GameTimeManager 可选择跟随暂停

# =========================
# —— 运行期状态 —— 
# =========================

var _grid: Node = null
var _drag_layer: Node = null
var _sprite: Node2D = null
var _hit_full: Area2D = null

var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _orig_z_as_relative: bool = true

var _dragging: bool = false
var _pressing_left: bool = false
var _drag_offset: Vector2 = Vector2.ZERO

var _pre_drag_parent: Node = null
var _pre_drag_sibling_idx: int = -1
var _pre_drag_global: Vector2 = Vector2.ZERO

var _blocked_cells: Array[int] = []

var _coin_model: CoinModel = null
var _upkeep_timer_accum: float = 0.0
var _last_pay_success: bool = true


func _ready() -> void:
	_find_grid_manager()
	_find_sprite_and_hit()
	
	_orig_scale = scale
	_orig_z = z_index
	_orig_z_as_relative = z_as_relative
	
	_refresh_coin_model()
	_refresh_footprint()
	_update_process_state()


func _exit_tree() -> void:
	_unblock_footprint()


func _process(delta: float) -> void:
	# —— 拖拽跟随 —— 
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()
		global_position = mouse_g - _drag_offset
		
		# 兜底：若左键已抬起但还在拖拽状态，强制结束
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_end_drag_and_drop()
	
	# —— 周期扣费 —— 
	if upkeep_enabled:
		_process_upkeep(delta)


# =========================
# —— Upkeep 逻辑 —— 
# =========================

func _refresh_coin_model() -> void:
	_coin_model = null
	
	# 1）优先用 Inspector 指定路径
	if coin_model_path != NodePath(""):
		var node_from_path: Node = get_node_or_null(coin_model_path)
		if node_from_path != null:
			var cm_from_path: CoinModel = node_from_path as CoinModel
			if cm_from_path != null:
				_coin_model = cm_from_path
				return
			else:
				push_warning("living: coin_model_path 指向的节点不是 CoinModel。")
	
	# 2）否则在场景树里自动搜索第一个 CoinModel
	var root: Node = get_tree().get_root()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is CoinModel:
			_coin_model = n as CoinModel
			return
		for c in n.get_children():
			stack.append(c)
	
	if _coin_model == null:
		push_warning("living: 未找到 CoinModel，维护费功能将不会生效。")


func _process_upkeep(delta: float) -> void:
	if _coin_model == null or not is_instance_valid(_coin_model):
		return
	
	var effective_dt: float = delta
	
	if obey_time_pause:
		var root: Node = get_tree().get_root()
		var gtm: Node = root.get_node_or_null("GameTimeManager")
		if gtm != null:
			if gtm.has_method("is_paused"):
				var paused1: bool = bool(gtm.call("is_paused"))
				if paused1:
					effective_dt = 0.0
			elif gtm.has_method("is_time_paused"):
				var paused2: bool = bool(gtm.call("is_time_paused"))
				if paused2:
					effective_dt = 0.0
	
	if effective_dt <= 0.0:
		return
	
	if time_spent <= 0.0:
		time_spent = 0.1
	
	_upkeep_timer_accum += effective_dt
	
	while _upkeep_timer_accum >= time_spent:
		_upkeep_timer_accum -= time_spent
		_do_upkeep_tick()


func _do_upkeep_tick() -> void:
	if _coin_model == null or not is_instance_valid(_coin_model):
		return
	
	if cost_money <= 0:
		_last_pay_success = true
		return
	
	var current: int = _coin_model.get_amount()
	if current < cost_money:
		# 钱不够，这一轮扣费失败，但不销毁 / 不自动关闭
		_last_pay_success = false
		return
	
	var ok: bool = _coin_model.pay(cost_money)
	_last_pay_success = ok


# =========================
# —— 拖拽输入 —— 
# =========================

func _on_hit_full_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event as InputEventMouseButton
		
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressing_left = true
			else:
				if _dragging:
					_end_drag_and_drop()
				_pressing_left = false
		
		# living 不再处理右键（不弹任何弹窗）
	
	elif event is InputEventMouseMotion:
		if _pressing_left and not _dragging:
			_begin_drag()


# =========================
# —— 拖拽开始/结束 —— 
# =========================

func _begin_drag() -> void:
	if _dragging:
		return
	
	_dragging = true
	_unblock_footprint()
	
	_pre_drag_global = global_position
	_pre_drag_parent = get_parent()
	_pre_drag_sibling_idx = _pre_drag_parent.get_children().find(self)
	
	# 拖拽层：优先使用 drag_layer_path，找不到就挂到根节点（Window）下
	if _drag_layer == null:
		if drag_layer_path != NodePath(""):
			var candidate: Node = get_node_or_null(drag_layer_path)
			if candidate != null:
				_drag_layer = candidate
		if _drag_layer == null:
			_drag_layer = get_tree().get_root()
	
	if _drag_layer != null and get_parent() != _drag_layer:
		var gp: Vector2 = global_position
		_pre_drag_parent.remove_child(self)
		_drag_layer.add_child(self)
		global_position = gp
	
	# 提高 z，缩放
	_orig_z = z_index
	_orig_z_as_relative = z_as_relative
	
	z_as_relative = false
	z_index = drag_z
	scale = _orig_scale * pickup_scale
	
	var mouse_g: Vector2 = get_global_mouse_position()
	_drag_offset = mouse_g - global_position
	
	_update_process_state()


func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	
	_dragging = false
	
	var target_pos: Vector2 = global_position
	
	# 若有 GridManager，则吸附到最近单元格中心
	if _grid != null and is_instance_valid(_grid) and _grid.has_method("world_to_cell_center"):
		var snapped_v: Variant = _grid.call("world_to_cell_center", global_position)
		if snapped_v is Vector2:
			target_pos = snapped_v as Vector2
	
	_restore_parent_if_needed()
	_restore_visual_post_drop()
	
	# 先按目标位置刷新 footprint，再播放动画
	var original_pos: Vector2 = global_position
	global_position = target_pos
	_refresh_footprint()
	global_position = original_pos
	
	_animate_snap_to(target_pos)
	_update_process_state()


func _restore_parent_if_needed() -> void:
	if _pre_drag_parent == null or not is_instance_valid(_pre_drag_parent):
		return
	
	if get_parent() == _pre_drag_parent:
		return
	
	var gp: Vector2 = global_position
	get_parent().remove_child(self)
	_pre_drag_parent.add_child(self)
	
	if _pre_drag_sibling_idx >= 0 and _pre_drag_sibling_idx < _pre_drag_parent.get_child_count():
		_pre_drag_parent.move_child(self, _pre_drag_sibling_idx)
	
	global_position = gp


func _restore_visual_post_drop() -> void:
	scale = _orig_scale
	z_as_relative = _orig_z_as_relative
	z_index = _orig_z


func _update_process_state() -> void:
	var should_process: bool = _dragging or upkeep_enabled
	set_process(should_process)


# =========================
# —— Grid footprint 相关 —— 
# =========================

func _unblock_footprint() -> void:
	if _grid == null or not is_instance_valid(_grid):
		_blocked_cells.clear()
		return
	
	if _blocked_cells.is_empty():
		return
	
	# 优先一次性解锁
	if _grid.has_method("unblock_many"):
		_grid.call("unblock_many", _blocked_cells)
	elif _grid.has_method("unblock_cell"):
		for c in _blocked_cells:
			_grid.call("unblock_cell", c)
	
	_blocked_cells.clear()


func _refresh_footprint() -> void:
	_unblock_footprint()
	
	if _grid == null or not is_instance_valid(_grid):
		return
	
	if not _grid.has_method("world_to_cell_idx"):
		return
	
	var base_v: Variant = _grid.call("world_to_cell_idx", global_position)
	var base_cell: int = int(base_v)
	if base_cell < 0:
		return
	
	var cells: Array[int] = _cells_footprint_at(base_cell)
	if cells.is_empty():
		return
	
	# 优先一次性 block
	if _grid.has_method("block_many"):
		_grid.call("block_many", cells)
	elif _grid.has_method("block_cell"):
		for c in cells:
			_grid.call("block_cell", c)
	
	_blocked_cells = cells


func _cells_footprint_at(base_cell: int) -> Array[int]:
	var result: Array[int] = []
	
	if _grid == null or not is_instance_valid(_grid):
		return result
	
	var total_cols: int = 0
	var total_rows: int = 0
	
	if "cols" in _grid and "rows" in _grid:
		total_cols = int(_grid.cols)
		total_rows = int(_grid.rows)
	else:
		return result
	
	if total_cols <= 0 or total_rows <= 0:
		return result
	
	var base_row: int = base_cell / total_cols
	var base_col: int = base_cell % total_cols
	
	for r in range(footprint_rows):
		for c in range(footprint_cols):
			var rr: int = base_row + r
			var cc: int = base_col + c
			
			if cc >= 0 and rr >= 0 and cc < total_cols and rr < total_rows:
				var idx: int = rr * total_cols + cc
				result.append(idx)
	
	return result


# =========================
# —— Snap 动画 —— 
# =========================

func _animate_snap_to(target_pos: Vector2) -> void:
	# 优先走 GridManager 的 CardAnimation 动画
	if _grid != null and is_instance_valid(_grid) and _grid.has_method("_ensure_anim_on"):
		var anim_variant: Variant = _grid.call("_ensure_anim_on", self)
		var anim: CardAnimation = anim_variant as CardAnimation
		if anim != null:
			# 传 -1.0 使用 CardAnimation Inspector 里配置的默认参数
			anim.tween_to(target_pos, -1.0, -1.0)
			return
	
	# 兜底 Tween：若没有 CardAnimation 或 GridManager
	var tw: Tween = create_tween()
	tw.tween_property(self, "global_position", target_pos, 0.15) \
		.set_trans(Tween.TransitionType.TRANS_QUAD) \
		.set_ease(Tween.EaseType.EASE_OUT)


# =========================
# —— 初始化辅助 —— 
# =========================

func _find_grid_manager() -> void:
	_grid = null
	
	# 1）优先用 Inspector 指定路径
	if grid_manager_path != NodePath(""):
		var gm_from_path: Node = get_node_or_null(grid_manager_path)
		if gm_from_path != null:
			_grid = gm_from_path
			return
	
	# 2）否则在场景树里自动搜索，找第一个有 Grid 方法的节点
	var root: Node = get_tree().get_root()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n != self and n.has_method("world_to_cell_center") and n.has_method("world_to_cell_idx"):
			_grid = n
			return
		for c in n.get_children():
			stack.append(c)


func _find_sprite_and_hit() -> void:
	if sprite_path != NodePath(""):
		var s: Node = get_node_or_null(sprite_path)
		if s != null and s is Node2D:
			_sprite = s as Node2D
	
	if hit_full_path != NodePath(""):
		var h: Node = get_node_or_null(hit_full_path)
		if h != null and h is Area2D:
			_hit_full = h as Area2D
			_hit_full.input_event.connect(_on_hit_full_input)


# =========================
# —— 对表盘暴露的接口 —— 
# =========================

func get_time_spent() -> float:
	return time_spent


func get_cycle_progress() -> float:
	# 读条进度：0.0 ~ 1.0，对应当前这一轮 time_spent 的时间比例
	if not upkeep_enabled:
		return 0.0
	if time_spent <= 0.0:
		return 0.0
	
	var ratio: float = _upkeep_timer_accum / time_spent
	return clamp(ratio, 0.0, 1.0)
