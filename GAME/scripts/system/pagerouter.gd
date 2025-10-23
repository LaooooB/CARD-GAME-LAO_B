extends Node
class_name PageRouter

@export var camera_path: NodePath
@export var page_main_root: NodePath
@export var page_shop_root: NodePath
@export var page_storage_root: NodePath
@export var page_secret_root: NodePath

@export var start_cell_x: int = 0
@export var start_cell_y: int = 0
@export var background_node_name: String = "Background"

# —— 平滑移动参数 —— #
@export var tween_enabled: bool = true
@export_range(0.05, 3.0, 0.01) var tween_duration: float = 0.35
@export var tween_transition: Tween.TransitionType = Tween.TRANS_QUAD
@export var tween_ease: Tween.EaseType = Tween.EASE_OUT_IN   # 开头快 → 中间慢

# —— 冲突仲裁设置 —— #
# 同时按多方向时，是否以“最后按下”的为准；否则遇到冲突就不动
@export var prefer_last_pressed_when_conflict: bool = true

var _cam: Camera2D = null
var _grid: Dictionary = {}                # Vector2i -> Node (page root)
var _current_cell: Vector2i = Vector2i(0, 0)
var _move_tween: Tween = null
var _is_moving: bool = false              # 动画期间 true，锁住输入

# —— 输入缓冲：动画中玩家的新方向会缓存在这里 —— #
var _queued_dir: Vector2i = Vector2i.ZERO

# 方向键最近按下时间（毫秒），用于“最后按下优先”的仲裁
var _stamp_left: int = -1
var _stamp_right: int = -1
var _stamp_up: int = -1
var _stamp_down: int = -1

func _ready() -> void:
	_cam = get_node_or_null(camera_path) as Camera2D
	if _cam == null:
		push_error("[PageRouter] camera_path 未设置或不是 Camera2D")
		return
	_cam.make_current()

	var main_root  := get_node_or_null(page_main_root)
	var shop_root  := get_node_or_null(page_shop_root)
	var store_root := get_node_or_null(page_storage_root)
	var secret_root:= get_node_or_null(page_secret_root)

	if main_root != null:   _grid[Vector2i(0, 0)] = main_root
	if shop_root != null:   _grid[Vector2i(1, 0)] = shop_root
	if store_root != null:  _grid[Vector2i(0, 1)] = store_root
	if secret_root != null: _grid[Vector2i(1, 1)] = secret_root

	var start := Vector2i(start_cell_x, start_cell_y)
	if not _grid.has(start):
		if _grid.has(Vector2i(0,0)):
			start = Vector2i(0,0)
		elif _grid.size() > 0:
			for k in _grid.keys():
				start = k
				break
	_current_cell = start

	_cam.global_position = _page_center_for_cell(_current_cell)

func _unhandled_input(_event: InputEvent) -> void:
	if _cam == null:
		return

	# 记录刚按下的时间戳（用于“最后按下优先”）
	var now_ms := Time.get_ticks_msec()
	if Input.is_action_just_pressed("ui_room_left"):
		_stamp_left = now_ms
	if Input.is_action_just_pressed("ui_room_right"):
		_stamp_right = now_ms
	if Input.is_action_just_pressed("ui_room_up"):
		_stamp_up = now_ms
	if Input.is_action_just_pressed("ui_room_down"):
		_stamp_down = now_ms

	# 只在有“just_pressed”时解析一次方向（避免长按反复触发）
	if Input.is_action_just_pressed("ui_room_left") \
	or Input.is_action_just_pressed("ui_room_right") \
	or Input.is_action_just_pressed("ui_room_up") \
	or Input.is_action_just_pressed("ui_room_down"):
		var dir := _resolve_direction_single_axis()
		if dir == Vector2i.ZERO:
			return

		if _is_moving:
			# 动画中：把新意图缓存为“下一步”
			if _dir_is_valid(dir):
				_queued_dir = dir   # 只保留最后一次意图，避免排长队
			return
		else:
			# 非动画：立即执行
			_try_move_to(_current_cell + dir)

func _resolve_direction_single_axis() -> Vector2i:
	# 读取当前按住状态（为防止松开后误触）
	var horiz := 0
	if Input.is_action_pressed("ui_room_left"):
		horiz -= 1
	if Input.is_action_pressed("ui_room_right"):
		horiz += 1

	var vert := 0
	if Input.is_action_pressed("ui_room_up"):
		vert -= 1
	if Input.is_action_pressed("ui_room_down"):
		vert += 1

	# 同时有横纵，做仲裁
	if horiz != 0 and vert != 0:
		if prefer_last_pressed_when_conflict:
			# 拿“最近 just_pressed”的那个轴/方向
			var best_stamp := -1
			var best_dir := Vector2i.ZERO
			if horiz < 0 and _stamp_left > best_stamp:
				best_dir = Vector2i(-1, 0); best_stamp = _stamp_left
			if horiz > 0 and _stamp_right > best_stamp:
				best_dir = Vector2i(1, 0);  best_stamp = _stamp_right
			if vert < 0 and _stamp_up > best_stamp:
				best_dir = Vector2i(0, -1); best_stamp = _stamp_up
			if vert > 0 and _stamp_down > best_stamp:
				best_dir = Vector2i(0, 1);  best_stamp = _stamp_down
			return best_dir
		else:
			# 冲突直接丢弃（不走斜线）
			return Vector2i.ZERO

	# 只有一个轴时，直接用该轴
	if horiz != 0:
		return Vector2i(horiz, 0)
	if vert != 0:
		return Vector2i(0, vert)
	return Vector2i.ZERO

func _dir_is_valid(dir: Vector2i) -> bool:
	if dir == Vector2i.ZERO:
		return false
	var target_cell := _current_cell + dir
	return _cell_exists(target_cell)

func _cell_exists(cell: Vector2i) -> bool:
	# 目前是 2x2，可扩展：只要 _grid 里存在就算有效
	return _grid.has(cell)

func _try_move_to(target_cell: Vector2i) -> void:
	# 边界 / 存在性
	if not _grid.has(target_cell):
		return

	_current_cell = target_cell
	var target_pos := _page_center_for_cell(_current_cell)

	if tween_enabled:
		# 开始动画：上锁
		if _move_tween != null and is_instance_valid(_move_tween):
			_move_tween.kill()
		_is_moving = true
		_move_tween = create_tween()
		_move_tween.set_trans(tween_transition).set_ease(tween_ease)
		_move_tween.tween_property(_cam, "global_position", target_pos, tween_duration)
		_move_tween.finished.connect(_on_tween_finished)
	else:
		_cam.global_position = target_pos
		# 没动画也支持立即执行队列（如果玩家超快连按）
		_consume_queue_if_any()

func _on_tween_finished() -> void:
	_is_moving = false
	_move_tween = null
	# 动画结束后，若期间有新的方向输入，立刻执行下一步
	_consume_queue_if_any()

func _consume_queue_if_any() -> void:
	if _queued_dir != Vector2i.ZERO:
		var dir := _queued_dir
		_queued_dir = Vector2i.ZERO
		# 再次确认存在性，避免越界
		if _dir_is_valid(dir):
			_try_move_to(_current_cell + dir)

func _page_center_for_cell(cell: Vector2i) -> Vector2:
	if not _grid.has(cell):
		return Vector2.ZERO

	var root := _grid[cell] as Node
	var bg: Sprite2D = null
	if root != null:
		bg = (root as Node).find_child(background_node_name, true, false) as Sprite2D

	if bg != null and bg.texture != null:
		var tex_size: Vector2 = bg.texture.get_size()
		var scl: Vector2 = bg.scale.abs()
		var size: Vector2 = tex_size * scl
		var top_left: Vector2 = bg.global_position
		if bg.centered:
			top_left -= size * 0.5
		top_left -= bg.offset * scl
		return top_left + size * 0.5
	else:
		var n2d := root as Node2D
		if n2d != null:
			return n2d.global_position
		else:
			return Vector2.ZERO
