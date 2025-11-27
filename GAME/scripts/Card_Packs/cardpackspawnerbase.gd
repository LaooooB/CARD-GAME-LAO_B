extends Control
class_name cardpackspawnerbase

# —— 你按钮的名字或路径（路径优先）——
@export var button_node_name: StringName = &"SummonCommon"
@export var spawn_button_path: NodePath

# —— 绑定对象 —— 
@export var grid_manager_path: NodePath
@export var camera_path: NodePath

# —— 生成到哪里（兜底） —— 
@export var parent_for_packs: NodePath
@export var spawn_at_mouse: bool = true
@export var spawn_position: Vector2 = Vector2.ZERO

# —— 要检索的卡包名（必须与 JSON 的 PACK_NAME 完全一致）——
@export var pack_name: StringName = &"Common pack"

# —— “相机窗口中心区域”占比（相对于当前相机窗口宽/高）——
@export_range(0.05, 1.0, 0.05) var center_ratio_x: float = 0.5
@export_range(0.05, 1.0, 0.05) var center_ratio_y: float = 0.5

# —— 选格策略 & 防重复 —— 
@export_enum("random", "nearest") var center_pick_mode: int = 0   # 0=random, 1=nearest
@export_range(0, 20, 1) var avoid_repeat_count: int = 3           # 记住最近 N 个生成过的格子并尽量避开（0=不避）

# —— 调试 —— 
@export var debug_log: bool = true

const BLUEPRINT_JSON_PATH: String = "res://GAME/data/card_packs/pack_blueprint.json"

@onready var _btn: BaseButton = null
var _rng: RandomNumberGenerator
var _recent_cells: Array[int] = []

func _ready() -> void:
	# RNG
	_rng = RandomNumberGenerator.new()
	_rng.randomize()

	# 优先用路径找按钮；否则按名字在子树里找
	if not spawn_button_path.is_empty():
		var n_path: Node = get_node_or_null(spawn_button_path)
		if n_path != null and n_path is BaseButton:
			_btn = n_path as BaseButton
	if _btn == null:
		_btn = _find_button_by_name(button_node_name)

	if _btn == null:
		push_error("[cardpackspawnerbase] 找不到按钮，请设置 button_node_name 或 spawn_button_path，并确保按钮在本节点子树中。")
		return

	# 关键：按钮不再接受键盘焦点，空格/回车不会把它当成“按下按钮”
	_btn.focus_mode = Control.FOCUS_NONE

	_btn.pressed.connect(_on_spawn_pressed)


func _find_button_by_name(target: StringName) -> BaseButton:
	var t: String = str(target)
	var n: Node = find_child(t, true, false)
	if n != null and n is BaseButton:
		return n as BaseButton
	var q: Array[Node] = get_children()
	while not q.is_empty():
		var cur: Node = q.pop_back()
		if cur.name == t and cur is BaseButton:
			return cur as BaseButton
		for ch: Node in cur.get_children():
			q.push_front(ch)
	return null

func _on_spawn_pressed() -> void:
	# 1) 从 JSON 找场景
	var scene_path: String = _find_scene_path_by_name(str(pack_name))
	if scene_path.is_empty():
		push_error("[cardpackspawnerbase] JSON 中未找到 PACK_NAME='%s'。" % [str(pack_name)])
		return
	var ps: PackedScene = load(scene_path) as PackedScene
	if ps == null:
		push_error("[cardpackspawnerbase] 加载场景失败：%s" % [scene_path])
		return

	# 2) 取 Grid 与 Camera
	var grid_node: Node = get_node_or_null(grid_manager_path)
	if grid_node == null:
		push_error("[cardpackspawnerbase] 请设置 grid_manager_path 指向 GridManager。")
		return
	var G: GridManager = grid_node as GridManager
	if G == null:
		push_error("[cardpackspawnerbase] grid_manager_path 指向的不是 GridManager。")
		return

	var cam: Camera2D = _get_camera()
	if cam == null:
		push_error("[cardpackspawnerbase] 未找到 Camera2D：请设置 camera_path 或确保 viewport 有当前相机。")
		return

	# 3) 只在“相机窗口中心区域”挑格子（按策略）
	var cell: int = _pick_cell_in_camera_center_region(G, cam)
	var use_grid_spawn: bool = (cell != -1)

	# 4) 实例化并定位
	var parent_node: Node = _get_parent_for_spawn()
	if parent_node == null:
		push_error("[cardpackspawnerbase] 找不到父节点。")
		return

	var inst: Node = ps.instantiate()
	if inst == null:
		push_error("[cardpackspawnerbase] 实例化失败：%s" % [scene_path])
		return
	parent_node.add_child(inst)

	if inst is Node2D:
		var n2d: Node2D = inst as Node2D
		if use_grid_spawn:
			n2d.global_position = G.get_cell_pos(cell)
			# 记录最近使用的 cell（用于避开重复）
			_record_recent_cell(cell)
		else:
			if spawn_at_mouse:
				n2d.global_position = get_global_mouse_position()
			else:
				if parent_node is Node2D:
					n2d.global_position = (parent_node as Node2D).to_global(spawn_position)
				else:
					n2d.global_position = spawn_position

	if debug_log:
		if use_grid_spawn:
			print("[cardpackspawnerbase] 窗口中心区域生成：", str(pack_name), "  cell=", cell)
		else:
			print("[cardpackspawnerbase] 窗口中心区域无可用格，使用兜底生成：", str(pack_name))

# === 只在“当前相机可见窗口”的中心子区域内挑一个空格（支持 random / nearest） ===
func _pick_cell_in_camera_center_region(G: GridManager, cam: Camera2D) -> int:
	var total: int = G.cols * G.rows

	# 1) 相机可见矩形（世界坐标）
	var vp_size: Vector2 = Vector2(get_viewport_rect().size)
	var half: Vector2 = vp_size * 0.5 * cam.zoom
	var vis_center: Vector2 = cam.get_screen_center_position()
	var vis_rect: Rect2 = Rect2(vis_center - half, half * 2.0)
	if vis_rect.size.x <= 0.0 or vis_rect.size.y <= 0.0:
		return -1

	# 2) 窗口中心子区域
	var rx: float = clamp(center_ratio_x, 0.05, 1.0)
	var ry: float = clamp(center_ratio_y, 0.05, 1.0)
	var sub_size: Vector2 = Vector2(vis_rect.size.x * rx, vis_rect.size.y * ry)
	var sub_rect: Rect2 = Rect2(vis_center - sub_size * 0.5, sub_size)

	# 3) 收集候选：空闲且未禁用，且 cell 中心落在 sub_rect 内
	var candidates: Array[int] = []
	for i: int in range(total):
		if not G.is_cell_free(i) or G.is_cell_forbidden(i):
			continue
		var p: Vector2 = G.get_cell_pos(i)
		if sub_rect.has_point(p):
			candidates.append(i)

	if candidates.is_empty():
		return -1

	# 4) 避免最近重复（可选）
	if avoid_repeat_count > 0 and _recent_cells.size() > 0:
		var filtered: Array[int] = []
		for c: int in candidates:
			if not _recent_cells.has(c):
				filtered.append(c)
		if not filtered.is_empty():
			candidates = filtered
		# 如果过滤后空了，就退回 candidates 原集合（允许重复）

	# 5) 根据策略挑选
	if center_pick_mode == 0:
		# random
		var idx: int = _rng.randi_range(0, candidates.size() - 1)
		return candidates[idx]
	else:
		# nearest to window center
		var best: int = candidates[0]
		var best_d2: float = G.get_cell_pos(best).distance_squared_to(vis_center)
		for k: int in range(1, candidates.size()):
			var c: int = candidates[k]
			var d2: float = G.get_cell_pos(c).distance_squared_to(vis_center)
			if d2 < best_d2:
				best = c
				best_d2 = d2
		return best

func _record_recent_cell(cell: int) -> void:
	if avoid_repeat_count <= 0:
		return
	_recent_cells.append(cell)
	# 限制长度
	while _recent_cells.size() > avoid_repeat_count:
		_recent_cells.pop_front()

func _get_camera() -> Camera2D:
	if not camera_path.is_empty():
		var n: Node = get_node_or_null(camera_path)
		if n != null and n is Camera2D:
			return n as Camera2D
	var vp: Viewport = get_viewport()
	if vp != null:
		var c2d: Camera2D = vp.get_camera_2d()
		if c2d != null:
			return c2d
	return null

# === JSON & parent ===
func _find_scene_path_by_name(target_name: String) -> String:
	if not FileAccess.file_exists(BLUEPRINT_JSON_PATH):
		push_error("[cardpackspawnerbase] 蓝图 JSON 不存在：%s" % [BLUEPRINT_JSON_PATH])
		return ""
	var f: FileAccess = FileAccess.open(BLUEPRINT_JSON_PATH, FileAccess.READ)
	if f == null:
		push_error("[cardpackspawnerbase] 无法打开 JSON：%s" % [BLUEPRINT_JSON_PATH])
		return ""
	var raw: String = f.get_as_text()
	f.close()

	var parsed_json: Variant = JSON.parse_string(raw)
	if typeof(parsed_json) != TYPE_ARRAY:
		push_error("[cardpackspawnerbase] JSON 根应为 Array。")
		return ""
	var arr: Array = parsed_json as Array
	for row_any: Variant in arr:
		if typeof(row_any) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_any as Dictionary
		var name: String = str(row.get("PACK_NAME", ""))
		if name == target_name:
			return str(row.get("SCENE_PATH", ""))
	return ""

func _get_parent_for_spawn() -> Node:
	if parent_for_packs.is_empty():
		return get_tree().current_scene
	return get_node_or_null(parent_for_packs)
