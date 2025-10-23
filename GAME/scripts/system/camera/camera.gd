extends Camera2D
# 将此脚本挂到 Camera2D 上（需勾选 Current）

@export var screen_size: Vector2 = Vector2(1920, 1080) # 单个画布的尺寸
@export var grid_cols: int = 2                         # 列数（将来可改为 3、4…）
@export var grid_rows: int = 2                         # 行数
@export var start_col: int = 0                         # 初始列（0 到 grid_cols-1）
@export var start_row: int = 0                         # 初始行（0 到 grid_rows-1）

@export_range(0.05, 1.0, 0.01) var tween_duration: float = 0.18
@export var tween_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var tween_ease: Tween.EaseType = Tween.EASE_OUT

# —— 新增：滚轮缩放可调参数 —— 
@export var zoom_min: Vector2 = Vector2(1.01, 1.0)     # 最近（最大放大）
@export var zoom_max: Vector2 = Vector2(5.0, 5.0)      # 最远（最大缩小）
@export_range(0.5, 0.98, 0.01) var wheel_step_in := 0.90   # 下滚：放大倍率（<1，越小放大越快）
@export_range(1.02, 1.50, 0.01) var wheel_step_out := 1.10 # 上滚：缩小倍率（>1，越大缩小越快）
@export_range(0.05, 0.5, 0.01) var zoom_smooth := 0.18     # 丝滑程度（小=更慢更顺；大=更快）

var _col: int
var _row: int
var _tween: Tween
var _is_transitioning: bool = false  # 跟踪是否正在进行过渡

# —— 新增：目标缩放，用于丝滑过渡 —— 
var _target_zoom: Vector2

func _ready() -> void:
	_col = clamp(start_col, 0, grid_cols - 1)
	_row = clamp(start_row, 0, grid_rows - 1)
	_update_camera_position(true)

	# 初始化目标缩放，限制在范围内
	_target_zoom = Vector2(
		clamp(zoom.x, zoom_min.x, zoom_max.x),
		clamp(zoom.y, zoom_min.y, zoom_max.y)
	)
	zoom = _target_zoom

func _unhandled_input(event: InputEvent) -> void:
	if _is_transitioning:  # 如果正在过渡，忽略输入
		return
	
	var moved := false

	if Input.is_action_just_pressed("ui_room_left"):
		_col = max(0, _col - 1); moved = true
	if Input.is_action_just_pressed("ui_room_right"):
		_col = min(grid_cols - 1, _col + 1); moved = true
	if Input.is_action_just_pressed("ui_room_up"):
		_row = max(0, _row - 1); moved = true
	if Input.is_action_just_pressed("ui_room_down"):
		_row = min(grid_rows - 1, _row + 1); moved = true

	if moved:
		_update_camera_position(false)

	# —— 滚轮缩放（下=放大、上=缩小），只设目标值，实际缩放在 _process 中丝滑过渡 —— 
	if event is InputEventMouseButton and event.pressed:
		var BTN_WHEEL_UP := 4      # 上滚：缩小（数值变大）
		var BTN_WHEEL_DOWN := 5    # 下滚：放大（数值变小）

		if event.button_index == BTN_WHEEL_DOWN:
			# —— 定点缩放：在修改 _target_zoom 之前记录鼠标锚点 —— 
			zl_begin_cursor_locked_zoom()
			_target_zoom *= Vector2(wheel_step_in, wheel_step_in)    # 放大
		elif event.button_index == BTN_WHEEL_UP:
			# —— 定点缩放：在修改 _target_zoom 之前记录鼠标锚点 —— 
			zl_begin_cursor_locked_zoom()
			_target_zoom *= Vector2(wheel_step_out, wheel_step_out)  # 缩小
		else:
			return

		# 目标限制在范围内
		_target_zoom.x = clamp(_target_zoom.x, zoom_min.x, zoom_max.x)
		_target_zoom.y = clamp(_target_zoom.y, zoom_min.y, zoom_max.y)

func _process(delta: float) -> void:
	# 指数插值（帧率无关）让缩放更丝滑
	# zoom_smooth：0.05 很慢很顺；0.3-0.4 更快响应
	var k := 1.0 - pow(1.0 - zoom_smooth, delta * 60.0)
	zoom = zoom.lerp(_target_zoom, k)

	# 再次钳制，避免浮点误差越界
	zoom.x = clamp(zoom.x, zoom_min.x, zoom_max.x)
	zoom.y = clamp(zoom.y, zoom_min.y, zoom_max.y)

	# —— 定点缩放每帧修正（保证鼠标处不漂移）——
	zl_update_cursor_locked_zoom()

# —— 始终以“单个画布中心”为目标位置（左上角是(0,0)）——
func _grid_cell_center(col: int, row: int) -> Vector2:
	var w := screen_size.x
	var h := screen_size.y
	return Vector2(col * w + w * 0.5, row * h + h * 0.5)

func _update_camera_position(immediate: bool) -> void:
	var target := _grid_cell_center(_col, _row)

	if immediate:
		global_position = target.round()  # 立即设置时对齐到像素
		return

	if is_instance_valid(_tween):
		_tween.kill()

	_is_transitioning = true
	_tween = create_tween()
	_tween.set_trans(tween_trans).set_ease(tween_ease)
	# 使用回调在每一帧对齐像素
	_tween.tween_method(_set_pixel_perfect_position, global_position, target, tween_duration)
	_tween.tween_callback(_on_transition_completed)

func _set_pixel_perfect_position(pos: Vector2) -> void:
	global_position = pos.round()  # 强制像素对齐

func _on_transition_completed() -> void:
	_is_transitioning = false


# =========================
#  新增：定点缩放（鼠标为锚点）
#  不改现有参数；使用 meta 缓存状态，避免新增顶层变量
# =========================

# 在准备修改 _target_zoom 之前调用：记录锚点（鼠标世界坐标）、起始相机位置与起始缩放
func zl_begin_cursor_locked_zoom() -> void:
	var anchor_world: Vector2 = get_global_mouse_position()
	var cam_pos_start: Vector2 = global_position
	var zoom_start: Vector2 = zoom
	var st: Dictionary = {
		"active": true,
		"anchor_world": anchor_world,
		"cam_pos_start": cam_pos_start,
		"zoom_start": zoom_start
	}
	set_meta("zl_lock", st)

# 在 _process() 里每帧调用：根据当前 zoom 推导新的相机位置，保证锚点不漂移
# 在 _process() 里每帧调用：根据当前 zoom 推导新的相机位置，保证锚点不漂移
func zl_update_cursor_locked_zoom() -> void:
	if not has_meta("zl_lock"):
		return
	var st: Dictionary = get_meta("zl_lock") as Dictionary
	if not st.has("active") or not bool(st["active"]):
		return

	# 若已接近目标缩放就结束锁定（避免轻微抖动）
	var zx: float = float(zoom.x)
	var zy: float = float(zoom.y)
	var tx: float = float(_target_zoom.x)
	var ty: float = float(_target_zoom.y)
	if absf(zx - tx) < 0.0005 and absf(zy - ty) < 0.0005:
		st["active"] = false
		set_meta("zl_lock", st)
		return

	var anchor_world: Vector2 = st["anchor_world"]
	var cam_pos_start: Vector2 = st["cam_pos_start"]
	var zoom_start: Vector2 = st["zoom_start"]

	# cam_new = anchor - (zoom_start / zoom_now) * (anchor - cam_start)
	var rx: float = zoom_start.x / maxf(zx, 0.00001)
	var ry: float = zoom_start.y / maxf(zy, 0.00001)
	var dx: float = anchor_world.x - cam_pos_start.x
	var dy: float = anchor_world.y - cam_pos_start.y
	var cam_new: Vector2 = Vector2(
		anchor_world.x - dx * rx,
		anchor_world.y - dy * ry
	)

	global_position = cam_new.round()
