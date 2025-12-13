extends Node2D
class_name WorkUnitBase

# =========================
# —— 可在 Inspector 调参 —— 
# =========================
@export var grid_manager_path: NodePath
@export var sprite_path: NodePath = ^"Sprite2D"
@export var hit_full_path: NodePath = ^"hit_full"

@export var pickup_scale: float = 1.06		# 保留字段，不用于点击放大
@export var drag_z: int = 4094
@export var job_open_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var job_open_ease: Tween.EaseType = Tween.EASE_OUT

@export var job_close_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var job_close_ease: Tween.EaseType = Tween.EASE_IN

# —— 拖拽顶层容器（一次赋值，反复使用）——
@export var drag_layer_path: NodePath = ^"/root/DragLayer"	# 建议是一个 CanvasLayer 作为拖拽顶层

# —— work_unit_job 弹窗接入 —— 
@export var work_unit_job_scene: PackedScene
@export var work_unit_job_parent_path: NodePath
@export var work_unit_job_instance_path: NodePath
@export var job_popup_z_index: int = 400

# —— 右侧定位 —— 
@export var job_offset_right: Vector2 = Vector2(12, -8)
@export_enum("Right","Left","Top","Bottom","TopRight","TopLeft","BottomRight","BottomLeft","Custom")
var job_anchor_mode: int = 0

@export var job_custom_offset: Vector2 = Vector2.ZERO
@export var job_use_anchor_mode: bool = true

# —— 弹窗动画参数 —— 
@export_range(0.05, 0.8, 0.01) var job_open_duration: float = 0.16
@export_range(0.05, 0.8, 0.01) var job_close_duration: float = 0.12
@export var job_open_scale: Vector2 = Vector2(0.94, 0.94)
@export var job_close_scale: Vector2 = Vector2(0.94, 0.94)

# =========================
# —— 运行期状态 —— 
# =========================
@export var footprint_cols: int = 2
@export var footprint_rows: int = 2
var _blocked_cells: Array[int] = []	# 当前由本 WorkUnit 占用（禁用）的格子

var _grid: Node = null
var _sprite: Sprite2D = null
var _hit_full: Area2D = null

var _pressing_left: bool = false
var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _pre_drag_global: Vector2 = Vector2.ZERO

var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _orig_zrel: bool = true

# —— 拖拽换父缓存 —— 
var _drag_layer: Node = null
var _pre_drag_parent: Node = null
var _pre_drag_sibling_idx: int = -1

var _scale_tw: Tween = null

# —— 弹窗实例缓存 —— 
var _job_popup: Node = null
var _job_popup_ci: CanvasItem = null
var _popup_tw: Tween = null

# =========================
# —— 生命周期 —— 
# =========================
func _ready() -> void:
	# 找 Grid（多种兜底）
	_grid = get_node_or_null(grid_manager_path)
	if _grid == null and get_tree().current_scene != null:
		_grid = get_tree().current_scene.get_node_or_null(^"GridManager")
	if _grid == null:
		_grid = get_tree().get_root().find_child("GridManager", true, false)
	if _grid == null:
		_grid = get_node_or_null(^"/root/Grid")

	_sprite = get_node_or_null(sprite_path) as Sprite2D
	_hit_full = get_node_or_null(hit_full_path) as Area2D
	if _sprite == null:
		_sprite = find_child("Sprite2D", true, false) as Sprite2D
	if _hit_full == null:
		_hit_full = find_child("hit_full", true, false) as Area2D

	_orig_scale = scale
	_orig_z = z_index
	_orig_zrel = z_as_relative

	if _hit_full != null:
		_hit_full.input_event.connect(_on_hit_full_input)

	# 默认不跑帧逻辑；拖拽时再打开
	set_process(false)

	# 拖拽顶层容器
	_drag_layer = get_node_or_null(drag_layer_path)

	# —— 初次进入场景，按当前位置封 2×2 脚印 —— 
	_refresh_footprint()

	# —— 向 JobSlotManager 注册自己（供 snap 用） —— 
	var jsm: Node = get_node_or_null(^"/root/JobSlotManager")
	if jsm != null:
		jsm.call("register_work_unit", self)


func _exit_tree() -> void:
	var jsm: Node = get_node_or_null(^"/root/JobSlotManager")
	if jsm != null:
		jsm.call("unregister_work_unit", self)

# =========================
# —— 帧逻辑（拖拽跟随 + 兜底结束） —— 
# =========================
func _process(_dt: float) -> void:
	# 拖拽中：跟随鼠标，并同步弹窗位置
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()
		global_position = mouse_g - _drag_offset

		# 拖动时同步弹窗位置
		_update_job_popup_position_to_right_if_visible()

		# —— 兜底：如果左键已经弹起，但因为事件时序没有走到结束逻辑，强制收尾 —— 
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_end_drag_and_drop()
	else:
		# 不在拖拽，但弹窗是开着的（比如正在被 Grid 的 Tween 吸附移动）
		if _is_popup_visible():
			_update_job_popup_position_to_right_if_visible()

# =========================
# —— 命中区事件 —— 
# =========================
func _on_hit_full_input(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	# 左键：按下/抬起
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing_left = true
			# 不在这里直接开始拖拽，等待鼠标移动触发，避免纯点击也被视为拖拽
			return
		else:
			# 鼠标抬起时，无论是否拖拽中，都要清理状态；若正在拖拽，直接结束
			_pressing_left = false
			if _dragging:
				_end_drag_and_drop()
			return

	# 鼠标移动：在左键按住时才开始拖拽
	if event is InputEventMouseMotion and _pressing_left and not _dragging:
		_begin_drag()
		return

	# 右键：开/关弹窗（在“松开”时触发）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and not event.pressed:
		_toggle_work_unit_job()
		return

# =========================
# —— 开始/结束拖拽 —— 
# =========================
func _begin_drag() -> void:
	if _dragging:
		return
	_dragging = true
	_pre_drag_global = global_position

	# 以前这里会强制关闭 job 弹窗：
	# _hide_work_unit_job(true)
	# 现在改成：拖拽 WorkUnit 时，不自动收回弹窗，让玩家自己右键关

	# —— 开始拖拽前释放旧脚印（避免移动途中仍占用旧 2×2） —— 
	_unblock_footprint()

	# 一次性换父到拖拽顶层（若存在）
	_pre_drag_parent = get_parent()
	_pre_drag_sibling_idx = _pre_drag_parent.get_children().find(self) if _pre_drag_parent != null else -1

	if is_instance_valid(_drag_layer):
		var gp: Vector2 = global_position
		reparent(_drag_layer)
		global_position = gp
	else:
		# 兜底（没有 DragLayer 时）——只做一次安全抬高
		z_as_relative = false
		var z_cap: int = RenderingServer.CANVAS_ITEM_Z_MAX - 1
		z_index = min(drag_z, z_cap)

	# 拖拽偏移
	var mouse_g: Vector2 = get_global_mouse_position()
	_drag_offset = mouse_g - global_position

	# 状态统一交给 _update_process_state 控制
	_update_process_state()


func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	_dragging = false

	# 目标位置：默认是当前松手位置
	var target_pos: Vector2 = global_position

	# 若有 GridManager，则吸附到最近单元格中心
	if _grid != null and is_instance_valid(_grid) and _grid.has_method("world_to_cell_center"):
		@warning_ignore("shadowed_global_identifier")
		var snapped: Vector2 = _grid.call("world_to_cell_center", global_position)
		target_pos = snapped

	# —— 使用和 GridManager 里堆一样的 CardAnimation 动画去移动 —— 
	_animate_snap_to(target_pos)

	# 放回原父
	_restore_parent_if_needed()

	# 视觉恢复（缩放 / z-index）
	_restore_visual_post_drop()

	# 根据最终目标格刷新 2×2 占格
	_refresh_footprint()

	# 决定还要不要跑 _process：
	# 如果弹窗还开着，就继续跑（跟随 Tween）；
	# 如果弹窗关了且不在拖拽，就停掉。
	_update_process_state()

	# 保险：立刻对齐一次位置，避免第一帧 tween 前出现轻微错位
	_update_job_popup_position_to_right_if_visible()

func _animate_snap_to(target_pos: Vector2) -> void:
	# 优先走 GridManager 的 CardAnimation 工具，保证和堆的动画风格一致
	if _grid != null and is_instance_valid(_grid) and _grid.has_method("_ensure_anim_on"):
		var anim_variant: Variant = _grid.call("_ensure_anim_on", self)
		var anim: CardAnimation = anim_variant as CardAnimation
		if anim != null:
			# dur=-1, trans=-1：使用 CardAnimation Inspector 里的默认参数
			anim.tween_to(target_pos, -1.0, -1.0)
			return

	# —— 兜底：没有 CardAnimation 的情况下，用一个简单 Tween —— 
	var tw: Tween = create_tween()
	tw.tween_property(self, "global_position", target_pos, 0.16)

# =========================
# —— 弹窗：创建/切换/定位/动画 —— 
# =========================
func _ensure_job_popup() -> Node:
	# 已经有实例就直接用
	if _job_popup != null and is_instance_valid(_job_popup):
		return _job_popup

	# 若在某个场景里真的给 instance_path 赋值过，就优先用那个实例
	if work_unit_job_instance_path != NodePath(""):
		var inst: Node = get_node_or_null(work_unit_job_instance_path)
		if inst != null:
			_job_popup = inst
			if "z_index" in _job_popup:
				_job_popup.set("z_index", job_popup_z_index)
			_job_popup_ci = _job_popup as CanvasItem
			if _job_popup_ci != null:
				_job_popup_ci.visible = false
			return _job_popup

	# 否则：必须有 PackedScene，才能自己实例化一个
	if work_unit_job_scene == null:
		push_warning("[WorkUnitBase] work_unit_job_scene 未设置，且未提供现有实例路径。")
		return null

	# 决定挂到哪个父节点（不强依赖 Inspector 的 NodePath）
	var parent: Node = null

	# 1）如果在某个实例上填了 work_unit_job_parent_path，就优先用
	if work_unit_job_parent_path != NodePath(""):
		parent = get_node_or_null(work_unit_job_parent_path)

	# 2）没填的话，尝试在整棵树里找一个叫 "PopupUILayer" 的节点，当作 UI 层
	if parent == null:
		parent = get_tree().root.find_child("PopupUILayer", true, false)

	# 3）还找不到就退回 current_scene
	if parent == null:
		parent = get_tree().current_scene if get_tree().current_scene != null else get_tree().root

	# 实例化弹窗
	_job_popup = work_unit_job_scene.instantiate()
	parent.add_child(_job_popup)

	if "z_index" in _job_popup:
		_job_popup.set("z_index", job_popup_z_index)

	_job_popup_ci = _job_popup as CanvasItem
	if _job_popup_ci != null:
		_job_popup_ci.visible = false

	return _job_popup


func _toggle_work_unit_job() -> void:
	var popup: Node = _ensure_job_popup()
	if popup == null:
		return

	if _is_popup_visible():
		_hide_work_unit_job(true)
	else:
		_position_job_popup_to_right(popup)
		_show_work_unit_job(true)

func _show_work_unit_job(animated: bool) -> void:
	if _job_popup_ci == null:
		_job_popup_ci = _job_popup as CanvasItem
	if _job_popup_ci == null:
		if _job_popup != null:
			_job_popup.visible = true
		_update_process_state()   # ← 新增：弹窗开了，需要跑 _process
		return

	_kill_popup_tween()

	_job_popup_ci.visible = true
	var start_col: Color = _job_popup_ci.modulate
	var end_col: Color = Color(start_col.r, start_col.g, start_col.b, 1.0)
	var start_scale: Vector2 = job_open_scale
	var end_scale: Vector2 = Vector2.ONE

	_job_popup_ci.modulate = Color(start_col.r, start_col.g, start_col.b, 0.0)
	_job_popup_ci.scale = start_scale

	if animated:
		_popup_tw = create_tween()
		_popup_tw.set_trans(job_open_trans).set_ease(job_open_ease)
		_popup_tw.tween_property(_job_popup_ci, "modulate", end_col, job_open_duration)
		_popup_tw.parallel().tween_property(_job_popup_ci, "scale", end_scale, job_open_duration)
	else:
		_job_popup_ci.modulate = end_col
		_job_popup_ci.scale = end_scale

	_update_process_state()       # ← 新增：弹窗开了，需要跑 _process



func _hide_work_unit_job(animated: bool) -> void:
	if not _is_popup_visible():
		return

	if _job_popup_ci == null:
		_job_popup_ci = _job_popup as CanvasItem
	if _job_popup_ci == null:
		if _job_popup != null:
			_job_popup.visible = false
		_update_process_state()   # ← 弹窗直接关了
		return

	_kill_popup_tween()

	var start_col: Color = _job_popup_ci.modulate
	var end_col: Color = Color(start_col.r, start_col.g, start_col.b, 0.0)
	var end_scale: Vector2 = job_close_scale

	if animated:
		_popup_tw = create_tween()
		_popup_tw.set_trans(job_close_trans).set_ease(job_close_ease)
		_popup_tw.tween_property(_job_popup_ci, "modulate", end_col, job_close_duration)
		_popup_tw.parallel().tween_property(_job_popup_ci, "scale", end_scale, job_close_duration)
		_popup_tw.finished.connect(func() -> void:
			if is_instance_valid(_job_popup_ci):
				_job_popup_ci.visible = false
			_update_process_state()   # ← 动画结束时再关 process
		)
	else:
		_job_popup_ci.modulate = end_col
		_job_popup_ci.scale = end_scale
		_job_popup_ci.visible = false
		_update_process_state()       # ← 立即关 process（如果不在拖）

func _is_popup_visible() -> bool:
	if _job_popup_ci != null:
		return _job_popup_ci.visible
	if _job_popup != null:
		return _job_popup.visible
	return false


func _kill_popup_tween() -> void:
	if _popup_tw != null and _popup_tw.is_running():
		_popup_tw.kill()
		_popup_tw = null


func _update_job_popup_position_to_right_if_visible() -> void:
	if _is_popup_visible():
		var popup: Node = _ensure_job_popup()
		if popup != null:
			_position_job_popup_to_right(popup)


func _position_job_popup_to_right(popup: Node) -> void:
	var pos: Vector2 = _calc_right_anchor_global()
	if popup.has_method("show_at"):
		popup.call("show_at", pos)
		return
	if popup.has_method("toggle_at"):
		popup.call("toggle_at", pos)
		return
	if "global_position" in popup:
		popup.set("global_position", pos)


func _calc_right_anchor_global() -> Vector2:
	var w: float = 64.0
	var h: float = 64.0
	if _sprite != null and _sprite.texture != null:
		var tex_w: float = float(_sprite.texture.get_width())
		var tex_h: float = float(_sprite.texture.get_height())
		var sx: float = abs(scale.x * _sprite.scale.x)
		var sy: float = abs(scale.y * _sprite.scale.y)
		if sx <= 0.0:
			sx = 1.0
		if sy <= 0.0:
			sy = 1.0
		w = tex_w * sx
		h = tex_h * sy

	var half_w: float = w * 0.5
	var half_h: float = h * 0.5

	var base: Vector2 = global_position + Vector2(half_w, 0.0)	# 默认 Right

	if job_use_anchor_mode:
		match job_anchor_mode:
			0:
				base = global_position + Vector2(half_w, 0.0)		# Right
			1:
				base = global_position + Vector2(-half_w, 0.0)	# Left
			2:
				base = global_position + Vector2(0.0, -half_h)	# Top
			3:
				base = global_position + Vector2(0.0, half_h)	# Bottom
			4:
				base = global_position + Vector2(half_w, -half_h)	# TopRight
			5:
				base = global_position + Vector2(-half_w, -half_h)	# TopLeft
			6:
				base = global_position + Vector2(half_w, half_h)	# BottomRight
			7:
				base = global_position + Vector2(-half_w, half_h)	# BottomLeft
			8:
				base = global_position								# Custom（以卡中心为锚）
	else:
		base = global_position + Vector2(half_w, 0.0)

	return base + job_offset_right + job_custom_offset

# =========================
# —— Job 槽：转发到 work_unit_job —— 
# =========================
func _try_snap_card(card: Node2D, drop_global: Vector2) -> bool:
	# JobSlotManager 会遍历所有 WorkUnitBase 调用这个
	if card == null or not is_instance_valid(card):
		return false
	if not _is_popup_visible():
		return false

	var popup: Node = _ensure_job_popup()
	if popup == null or not is_instance_valid(popup):
		return false

	if popup.has_method("_try_snap_card"):
		return bool(popup.call("_try_snap_card", card, drop_global))

	return false


func _on_card_begin_drag(card: Node2D) -> void:
	if card == null or not is_instance_valid(card):
		return
	if _job_popup != null and is_instance_valid(_job_popup) and _job_popup.has_method("_on_card_begin_drag"):
		_job_popup.call("_on_card_begin_drag", card)

# =========================
# —— 占格（2×2）工具 —— 
# =========================
func _cells_footprint_at(base_cell: int) -> Array[int]:
	var out: Array[int] = []
	if _grid == null or base_cell < 0:
		return out

	# 读取网格行列：优先用 getter；否则尝试属性；再不济用 get()
	var total_cols: int = 0
	var total_rows: int = 0
	if _grid.has_method("get_cols"):
		total_cols = int(_grid.call("get_cols"))
	else:
		if "cols" in _grid:
			total_cols = int(_grid.cols)
		else:
			total_cols = int(_grid.get("cols"))
	if _grid.has_method("get_rows"):
		total_rows = int(_grid.call("get_rows"))
	else:
		if "rows" in _grid:
			total_rows = int(_grid.rows)
		else:
			total_rows = int(_grid.get("rows"))

	if total_cols <= 0 or total_rows <= 0:
		return out

	@warning_ignore("integer_division")
	var r: int = base_cell / total_cols
	var c: int = base_cell % total_cols

	for dy: int in range(footprint_rows):
		for dx: int in range(footprint_cols):
			var cc: int = c + dx
			var rr: int = r + dy
			if cc >= 0 and rr >= 0 and cc < total_cols and rr < total_rows:
				out.append(rr * total_cols + cc)

	return out


func _unblock_footprint() -> void:
	if _grid == null or _blocked_cells.is_empty():
		_blocked_cells.clear()
		return

	if _grid.has_method("unblock_many"):
		_grid.call("unblock_many", _blocked_cells)
	else:
		for c: int in _blocked_cells:
			if _grid.has_method("unblock_cell"):
				_grid.call("unblock_cell", c)

	_blocked_cells.clear()


func _refresh_footprint() -> void:
	if _grid == null:
		return

	var base_cell: int = -1
	if _grid.has_method("world_to_cell_idx"):
		base_cell = int(_grid.call("world_to_cell_idx", global_position))
	if base_cell == -1:
		return

	_unblock_footprint()

	var cells: Array[int] = _cells_footprint_at(base_cell)
	for c: int in cells:
		if _grid.has_method("block_cell"):
			_grid.call("block_cell", c)

	_blocked_cells = cells

# =========================
# —— 辅助 —— 
# =========================
func _restore_parent_if_needed() -> void:
	if _pre_drag_parent == null or not is_instance_valid(_pre_drag_parent):
		_pre_drag_parent = null
		_pre_drag_sibling_idx = -1
		return

	if get_parent() != _pre_drag_parent:
		var gp: Vector2 = global_position
		reparent(_pre_drag_parent)
		if _pre_drag_sibling_idx >= 0 and _pre_drag_sibling_idx < _pre_drag_parent.get_child_count():
			_pre_drag_parent.move_child(self, _pre_drag_sibling_idx)
		global_position = gp

	_pre_drag_parent = null
	_pre_drag_sibling_idx = -1


func _restore_visual_post_drop() -> void:
	if not scale.is_equal_approx(_orig_scale):
		_tween_scale_to(_orig_scale, 0.10, Tween.TRANS_QUAD, Tween.EASE_OUT)
	z_index = _orig_z
	z_as_relative = _orig_zrel


@warning_ignore("shadowed_global_identifier")
func _tween_scale_to(target: Vector2, dur: float = 0.12, trans: Tween.TransitionType = Tween.TRANS_QUAD, ease: Tween.EaseType = Tween.EASE_OUT) -> void:
	if _scale_tw != null and _scale_tw.is_running():
		_scale_tw.kill()
	_scale_tw = create_tween()
	_scale_tw.set_trans(trans).set_ease(ease)
	_scale_tw.tween_property(self, "scale", target, dur)

func _update_process_state() -> void:
	# 只要“在拖拽”或者“弹窗是打开的”，就需要跑 _process
	var should_process: bool = _dragging or _is_popup_visible()
	set_process(should_process)
