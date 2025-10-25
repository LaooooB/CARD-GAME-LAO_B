extends Node
class_name Board2DInputBridge

# ====== Inspector 可调 ======
@export var camera_path: NodePath
@export var plane_path: NodePath                 # XZ 平面，本地法线 +Y
@export var board2d_viewport_path: NodePath      # 指向 SubViewport
@export var flip_v: bool = false                 # 你现在习惯不翻转
@export var viewport_size_pixels: Vector2i = Vector2i(1920, 1080)

# 平面尺寸策略（与 to_local 对齐）
@export var use_mesh_local_size: bool = true
@export var plane_size_override: Vector2 = Vector2.ZERO  # 仅自定义网格用

# —— 调试叠加层 —— 
# 0=仅映射点(画在 SubViewport 内)
# 1=仅屏幕点(画在 GUI 根上，永远贴鼠标)
# 2=两者都显示
@export_range(0, 2, 1) var debug_overlay_mode: int = 0
@export var debug_log: bool = false
@export var debug_throttle_ms: int = 80
@export var debug_flash_seconds: float = 0.12    # DOWN/UP 时红点闪烁

# —— 与 2D 根调试中继的联动（可选，但强烈推荐装脚本2）——
@export var relay_node_name: String = "ClickDebugRelay"  # 在 SubViewport 树里查找的节点名

# ====== 运行期 ======
var _camera: Camera3D
var _plane: Node3D
var _vp: SubViewport

var _last_px: Vector2 = Vector2.ZERO
var _has_last: bool = false

var _dbg_dot_vp: Control = null      # SubViewport 内的映射点
var _dbg_dot_screen: Control = null  # 屏幕 GUI 根上的鼠标点
var _last_log_ms: int = 0

# 点击链路调试
var _current_click_id: int = 0
var _relay_cached: Node = null

func _ready() -> void:
	_camera = get_node_or_null(camera_path) as Camera3D
	_plane = get_node_or_null(plane_path) as Node3D
	_vp = get_node_or_null(board2d_viewport_path) as SubViewport

	if _vp:
		_vp.handle_input_locally = true
		_vp.gui_disable_input = false
		if _vp.size == Vector2i.ZERO and viewport_size_pixels != Vector2i.ZERO:
			_vp.size = viewport_size_pixels

	if not _camera or not _plane or not _vp:
		push_warning("Board2DInputBridge: camera/plane/subviewport not assigned.")
		set_process_input(false)
	else:
		set_process_input(true)

	_create_debug_dots()

func _input(event: InputEvent) -> void:
	if _camera == null or _plane == null or _vp == null:
		return
	if not (event is InputEventMouseButton or event is InputEventMouseMotion):
		return

	# 1) 屏幕坐标 → 主相机射线
	var mouse_screen: Vector2 = get_viewport().get_mouse_position()
	var ray_origin: Vector3 = _camera.project_ray_origin(mouse_screen)
	var ray_dir: Vector3 = _camera.project_ray_normal(mouse_screen)

	# 2) 逆转置法线（适配非等比缩放）
	var gtb: Basis = _plane.global_transform.basis
	var normal_world: Vector3 = gtb.inverse().transposed() * Vector3.UP
	normal_world = normal_world.normalized()

	var plane_origin_world: Vector3 = _plane.global_transform.origin

	var denom: float = normal_world.dot(ray_dir)
	if absf(denom) < 1e-6:
		_debug_log_once("no-hit: ray parallel to plane (denom≈0)")
		return
	var t: float = normal_world.dot(plane_origin_world - ray_origin) / denom
	if t < 0.0:
		_debug_log_once("no-hit: plane behind camera (t<0)")
		return

	var hit_world: Vector3 = ray_origin + ray_dir * t
	var hit_local: Vector3 = _plane.to_local(hit_world)

	# 3) 逻辑 W/H（与 to_local 对齐）
	var W: float = 1.0
	var H: float = 1.0
	var mi: MeshInstance3D = _plane as MeshInstance3D
	if use_mesh_local_size and mi and mi.mesh is PlaneMesh:
		var pm: PlaneMesh = mi.mesh as PlaneMesh
		W = pm.size.x  # 通常 2.0
		H = pm.size.y  # 通常 2.0
	elif plane_size_override != Vector2.ZERO:
		W = plane_size_override.x
		H = plane_size_override.y
	else:
		var sx: float = _plane.global_transform.basis.x.length()
		var sz: float = _plane.global_transform.basis.z.length()
		W = max(1e-6, sx)
		H = max(1e-6, sz)

	# 4) 本地 x/z → UV → SubViewport 像素
	var u: float = (hit_local.x + W * 0.5) / W
	var v_raw: float = (hit_local.z + H * 0.5) / H
	var v: float = (1.0 - v_raw) if flip_v else v_raw
	if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
		_has_last = false
		_debug_log_once("out-of-bounds UV: u=%.4f v=%.4f | local=%s W/H=(%.3f,%.3f)" % [u, v, hit_local, W, H])
		return

	var vp_size: Vector2i = (_vp.size if _vp.size != Vector2i.ZERO else viewport_size_pixels)
	var px: Vector2 = Vector2(u * float(vp_size.x), v * float(vp_size.y))

	# ===== 调试覆盖物 =====
	if debug_overlay_mode == 0 or debug_overlay_mode == 2:
		if is_instance_valid(_dbg_dot_vp):
			_dbg_dot_vp.position = px - _dbg_dot_vp.size * 0.5
	if debug_overlay_mode == 1 or debug_overlay_mode == 2:
		if is_instance_valid(_dbg_dot_screen):
			var vis: Rect2 = get_viewport().get_visible_rect()
			_dbg_dot_screen.position = vis.position + mouse_screen - _dbg_dot_screen.size * 0.5

	# ===== 识别 MouseButton（生成 click_id + 红点闪烁 + 日志 + 2D 中继通知）=====
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event as InputEventMouseButton
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				_current_click_id = Time.get_ticks_msec()
				_flash_dbg_dot()
				_debug_log_once("CLICK_DOWN id=%d px=(%.1f,%.1f) u=%.4f v=%.4f" % [_current_click_id, px.x, px.y, u, v])
				_notify_relay_down(_current_click_id, px)
			else:
				_flash_dbg_dot()
				_debug_log_once("CLICK_UP   id=%d px=(%.1f,%.1f)" % [_current_click_id, px.x, px.y])
				_notify_relay_up(_current_click_id, px)

	# 5) 构造并转发事件（SubViewport 像素）
	if event is InputEventMouseMotion:
		var src: InputEventMouseMotion = event as InputEventMouseMotion
		var mm := InputEventMouseMotion.new()
		mm.position = px
		mm.relative = (px - _last_px) if _has_last else Vector2.ZERO
		mm.button_mask = src.button_mask
		mm.ctrl_pressed = src.ctrl_pressed
		mm.shift_pressed = src.shift_pressed
		mm.alt_pressed = src.alt_pressed
		mm.meta_pressed = src.meta_pressed
		_vp.push_input(mm)
		_last_px = px
		_has_last = true

	elif event is InputEventMouseButton:
		var srcb: InputEventMouseButton = event as InputEventMouseButton
		var mb := InputEventMouseButton.new()
		mb.position = px
		mb.button_index = srcb.button_index
		mb.pressed = srcb.pressed
		mb.double_click = srcb.double_click
		mb.factor = srcb.factor
		mb.button_mask = srcb.button_mask
		mb.ctrl_pressed = srcb.ctrl_pressed
		mb.shift_pressed = srcb.shift_pressed
		mb.alt_pressed = srcb.alt_pressed
		mb.meta_pressed = srcb.meta_pressed
		_vp.push_input(mb)

		_debug_log_once("FORWARDED id=%d type=MouseButton pos=(%.1f,%.1f)" % [_current_click_id, px.x, px.y])

	get_viewport().set_input_as_handled()

# ===== 调试辅助 =====
func _create_debug_dots() -> void:
	if is_instance_valid(_dbg_dot_vp):
		_dbg_dot_vp.queue_free()
		_dbg_dot_vp = null
	if is_instance_valid(_dbg_dot_screen):
		_dbg_dot_screen.queue_free()
		_dbg_dot_screen = null

	if debug_overlay_mode == 0 or debug_overlay_mode == 2:
		if _vp != null:
			var a := ColorRect.new()
			a.color = Color(1, 0.25, 0.25, 0.95)  # 红
			a.size = Vector2(10, 10)
			a.mouse_filter = Control.MOUSE_FILTER_IGNORE
			a.name = "BRIDGE_DEBUG_DOT_VP"
			_vp.add_child(a)
			_dbg_dot_vp = a

	if debug_overlay_mode == 1 or debug_overlay_mode == 2:
		var gui_root: Control = get_viewport().gui_get_root() as Control
		if gui_root:
			var b := ColorRect.new()
			b.color = Color(0.25, 0.6, 1.0, 0.95)  # 蓝
			b.size = Vector2(10, 10)
			b.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.name = "BRIDGE_DEBUG_DOT_SCREEN"
			gui_root.add_child(b)
			_dbg_dot_screen = b

func _flash_dbg_dot() -> void:
	if not is_instance_valid(_dbg_dot_vp):
		return
	var tw := _dbg_dot_vp.create_tween()
	tw.tween_property(_dbg_dot_vp, "scale", Vector2(1.6, 1.6), debug_flash_seconds * 0.5)
	tw.tween_property(_dbg_dot_vp, "scale", Vector2.ONE, debug_flash_seconds * 0.5)

func _debug_log_once(msg: String) -> void:
	if not debug_log:
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_log_ms >= debug_throttle_ms:
		var vis: Rect2 = get_viewport().get_visible_rect()
		print("[Bridge] ", msg, " | screen=", vis.size, " vp=", _vp.size, " vis_origin=", vis.position)
		_last_log_ms = now

# ===== 与 2D 根的调试中继联动（可选）=====
func _find_relay() -> Node:
	if is_instance_valid(_relay_cached):
		return _relay_cached
	if _vp:
		# 在 SubViewport 子树里查找（深度优先）
		_relay_cached = _vp.find_child(relay_node_name, true, false)
	return _relay_cached

func _notify_relay_down(id: int, px: Vector2) -> void:
	var relay := _find_relay()
	if relay and relay.has_method("notify_bridge_click_down"):
		relay.call("notify_bridge_click_down", id, px)

func _notify_relay_up(id: int, px: Vector2) -> void:
	var relay := _find_relay()
	if relay and relay.has_method("notify_bridge_click_up"):
		relay.call("notify_bridge_click_up", id, px)
