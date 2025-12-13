# CardPack.gd —— 自动找 GridManager、自动命中区、拖拽/点击
# 点击后：从 card_blueprints.json 随机生成若干张卡牌（按 spawn_card_names 过滤），成功再消失（可调 Tween）
extends Node2D
class_name CardPack


@export var sprite_path: NodePath = ^"Sprite2D"
@export var hit_full_path: NodePath = ^"hit_full"

# —— 拖拽/点击基础 —— 
@export var pickup_scale: float = 1.06
@export var drag_z: int = 8999
@export_range(0.0, 20.0, 0.5) var click_px_threshold: float = 6.0
@export var click_ms_threshold: int = 220
@export var debug_log: bool = false

# —— 数据文件路径（严格字段名，但结构更宽松）——
@export var registry_path: String = "res://GAME/data/cards/card_registry.json"
@export var blueprints_path: String = "res://GAME/data/cards/card_blueprints.json"

# —— 生成配置（严格按 CARD_NAME 过滤；大小写不敏感）——
@export_range(1, 999, 1) var spawn_count: int = 5
@export var spawn_card_names: PackedStringArray = []
@export_range(0.0, 256.0, 1.0) var spawn_scatter: float = 40.0
@export_range(0.01, 1.0, 0.01) var spawn_tween_duration: float = 0.18

# 与 spawn_card_names 一一对应的概率（0~1）；留空或长度不匹配会自动均分
@export var spawn_card_weights: PackedFloat32Array = []

# 启动时把概率正规化到和为 1（true 更稳；false 则仅给出警告，不改你的输入）
@export var normalize_weights_on_start: bool = true

@export var spawn_tween_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var spawn_tween_ease: Tween.EaseType = Tween.EASE_OUT

# —— 点击后消失 Tween ——（只有生成成功才消失）——
@export var vanish_on_click: bool = true
@export_range(0.01, 2.0, 0.01) var vanish_duration: float = 0.18
@export var vanish_transition: Tween.TransitionType = Tween.TRANS_QUAD
@export var vanish_ease: Tween.EaseType = Tween.EASE_OUT
@export_range(0.2, 1.5, 0.01) var vanish_end_scale: float = 0.85
@export_range(0.0, 1.0, 0.01) var vanish_end_alpha: float = 0.0

# —— 回弹到原格子 的动效参数 —— 
@export_range(0.05, 1.0, 0.01) var bounce_back_duration: float = 0.20
@export var bounce_trans: Tween.TransitionType = Tween.TRANS_BACK
@export var bounce_ease: Tween.EaseType = Tween.EASE_OUT

signal drag_started(pack: CardPack)
signal drag_moved(pack: CardPack, mouse_global: Vector2)
signal drag_ended(pack: CardPack)

var _grid: Node = null
var _sprite: Sprite2D = null
var _hit_full: Area2D = null
var _anim: Node = null

var _dragging: bool = false
var _drag_offset: Vector2 = Vector2.ZERO
var _orig_scale: Vector2 = Vector2.ONE
var _orig_z: int = 0
var _orig_zrel: bool = true
var _interaction_enabled: bool = true

var _press_pos_screen: Vector2 = Vector2.ZERO
var _press_time_ms: int = 0
var _pressing: bool = false

# —— 索引：CARD_NAME(lower) → row(dict，含 SCENE_PATH 等) —— 
var _by_card_name: Dictionary = {}   # key: String(lowercase), value: Dictionary
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_normalize_or_warn_weights()

	_grid = _find_grid_manager()

	_sprite = get_node_or_null(sprite_path) as Sprite2D
	if _sprite == null:
		_sprite = find_child("Sprite2D", true, false) as Sprite2D

	_hit_full = get_node_or_null(hit_full_path) as Area2D
	if _hit_full == null:
		_hit_full = find_child("hit_full", true, false) as Area2D
	if _hit_full == null:
		_hit_full = _ensure_hit_area_from_sprite()

	_anim = find_child("CardAnimation", true, false)

	_orig_scale = scale
	_orig_z = z_index
	_orig_zrel = z_as_relative

	if _hit_full:
		_hit_full.input_event.connect(_on_hit_full_input)
		_hit_full.input_pickable = true
		_hit_full.monitoring = true

	modulate.a = 1.0

	_build_blueprint_index()

	if debug_log:
		print("[CardPack] indexed entries: ", _by_card_name.size())

	set_process(true)
	set_process_input(true)
	set_process_unhandled_input(false)


# ---------- 自动查找 GridManager ----------

func _find_grid_manager() -> Node:
	var cs: Node = get_tree().current_scene
	if cs:
		var n: Node = cs.get_node_or_null(^"GridManager")
		if n != null and _is_valid_grid(n):
			return n
		n = cs.find_child("GridManager", true, false)
		if n != null and _is_valid_grid(n):
			return n

	for g in ["grid_manager", "snap_manager"]:
		for node in get_tree().get_nodes_in_group(g):
			if _is_valid_grid(node):
				return node

	var root: Viewport = get_tree().get_root()
	var cand: Node = root.find_child("GridManager", true, false)
	if cand != null and _is_valid_grid(cand):
		return cand

	var q: Node = _dfs_find_by_method(root, "drop_pack")
	if q != null:
		return q

	return null


func _is_valid_grid(n: Node) -> bool:
	return n != null and is_instance_valid(n) and (n.has_method("drop_pack") or n.has_method("drop_card"))


func _dfs_find_by_method(start: Node, method_name: String) -> Node:
	if start != null and start.has_method(method_name):
		return start
	for i in range(start.get_child_count()):
		var c: Node = start.get_child(i)
		var r: Node = _dfs_find_by_method(c, method_name)
		if r != null:
			return r
	return null


# ---------- 命中区自动创建 ----------

func _ensure_hit_area_from_sprite() -> Area2D:
	var a: Area2D = Area2D.new()
	a.name = "hit_full"
	add_child(a)

	var shape: CollisionShape2D = CollisionShape2D.new()
	a.add_child(shape)

	var rect: RectangleShape2D = RectangleShape2D.new()
	var size_px: Vector2 = Vector2(64, 64)
	if _sprite != null and _sprite.texture != null:
		var tex_size: Vector2 = _sprite.texture.get_size()
		var scl: Vector2 = _sprite.scale
		size_px = tex_size * scl

	rect.size = size_px
	shape.shape = rect
	shape.position = Vector2.ZERO

	a.input_pickable = true
	a.monitoring = true
	return a


# ---------- 交互开关 ----------

func set_interaction_enabled(enabled: bool) -> void:
	_interaction_enabled = enabled
	if not enabled and _dragging:
		cancel_drag()


func set_hit_area_enabled(full_enabled: bool) -> void:
	if _hit_full:
		_hit_full.monitoring = full_enabled
		_hit_full.input_pickable = full_enabled
		_hit_full.visible = full_enabled


# ---------- 主循环 ----------

func _process(_delta: float) -> void:
	if _dragging:
		var mouse_g: Vector2 = get_global_mouse_position()
		var target: Vector2 = mouse_g - _drag_offset
		_follow_to(target)
		emit_signal("drag_moved", self, mouse_g)


func _input(event: InputEvent) -> void:
	# 鼠标抬起：结束拖拽 + 点击 → 生成 → 成功后消失
	if event is InputEventMouseButton \
	and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
	and not (event as InputEventMouseButton).pressed:
		if _dragging:
			_end_drag_and_drop()
		if _pressing:
			var dt: int = Time.get_ticks_msec() - _press_time_ms
			var dx: float = (get_viewport().get_mouse_position() - _press_pos_screen).length()
			_pressing = false
			if vanish_on_click and dt <= click_ms_threshold and dx <= click_px_threshold:
				await _spawn_then_vanish_if_success()
		return

	# 兜底命中（没有 hit_full 时）
	if _hit_full == null \
	and event is InputEventMouseButton \
	and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
	and (event as InputEventMouseButton).pressed:
		if _is_mouse_over_sprite():
			_pressing = true
			_press_pos_screen = get_viewport().get_mouse_position()
			_press_time_ms = Time.get_ticks_msec()
			begin_drag()


func _on_hit_full_input(_vp: Node, event: InputEvent, _shape_idx: int) -> void:
	if not _interaction_enabled:
		return
	if event is InputEventMouseButton \
	and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT \
	and (event as InputEventMouseButton).pressed:
		_pressing = true
		_press_pos_screen = get_viewport().get_mouse_position()
		_press_time_ms = Time.get_ticks_msec()
		begin_drag()


# ---------- 拖拽 ----------

func begin_drag() -> void:
	if _dragging or not _interaction_enabled:
		return
	_dragging = true

	# 记录：拖拽前位置 + 当前格中心（供 SellingArea 回弹用）
	set_meta("pre_drag_global_pos", global_position)
	var __cell_center: Vector2 = _get_current_cell_center_global()
	set_meta("pre_drag_cell_center", __cell_center)

	if pickup_scale != 0.0 and absf(pickup_scale - 1.0) > 0.0001:
		scale = _orig_scale * Vector2(pickup_scale, pickup_scale)

	z_as_relative = false
	if drag_z >= 0:
		var z_cap: int = RenderingServer.CANVAS_ITEM_Z_MAX - 1
		z_index = min(drag_z, z_cap)

	var mouse_g: Vector2 = get_global_mouse_position()
	_drag_offset = mouse_g - global_position

	if debug_log:
		print("[CardPack] drag_started")
	emit_signal("drag_started", self)


func _end_drag_and_drop() -> void:
	if not _dragging:
		return
	_dragging = false
	emit_signal("drag_ended", self)

	var accepted: bool = false
	if _grid != null and is_instance_valid(_grid) and _grid.has_method("drop_pack"):
		accepted = bool(_grid.call("drop_pack", self, global_position))

	if accepted:
		await _snap_to_grid_center()
	_restore_visual_post_drop(accepted)

	if debug_log:
		print("[CardPack] drop accepted? ", accepted)


func cancel_drag() -> void:
	if _dragging:
		_dragging = false
		emit_signal("drag_ended", self)
	_restore_visual_post_drop(false)


func _follow_to(target_global: Vector2) -> void:
	if _anim != null and _anim.has_method("follow_immediate"):
		_anim.call("follow_immediate", self, target_global)
	else:
		global_position = target_global


func _restore_visual_post_drop(_accepted: bool) -> void:
	scale = _orig_scale
	z_index = _orig_z
	z_as_relative = _orig_zrel


# =========================
# ===== 生成 & 消失 ======
# =========================

func _spawn_then_vanish_if_success() -> void:
	set_interaction_enabled(false)

	var requested: int = spawn_count
	var allowed: int = requested

	var limit_mgr: Node = _get_card_limit_manager()
	if limit_mgr != null:
		# —— 先算还能放几张 —— 
		var free: int = 0
		if limit_mgr.has_method("get_free_slots"):
			free = int(limit_mgr.call("get_free_slots"))
		elif limit_mgr.has_method("can_spawn"):
			# 退一步：只能全有全无
			if not bool(limit_mgr.call("can_spawn", requested)):
				free = 0
			else:
				free = requested

		free = max(free, 0)
		allowed = min(requested, free)

	if allowed <= 0:
		# 容量满了：不生成，也不消失
		set_interaction_enabled(true)
		if debug_log:
			push_warning("[CardPack] capacity full, no cards spawned.")
		return

	# —— 实际生成 allowed 张 —— 
	var spawned: int = _spawn_cards_from_blueprints(allowed, spawn_card_names)
	if spawned <= 0:
		set_interaction_enabled(true)
		if debug_log:
			push_warning("[CardPack] spawn failed; check blueprints, CARD_NAME filter, or SCENE_PATH.")
		return

	# —— 生成成功：把本次 +spawned 记入 CardLimitManager —— 
	if limit_mgr != null and spawned > 0 and limit_mgr.has_method("add_cards"):
		limit_mgr.call("add_cards", spawned)

	if debug_log and spawned < requested:
		print("[CardPack] spawned ", spawned, "/", requested, " due to capacity limit.")

	await _vanish_now()


func _vanish_now() -> void:
	var target_scale: Vector2 = _orig_scale * Vector2(vanish_end_scale, vanish_end_scale)
	var tw: Tween = create_tween()
	tw.set_trans(vanish_transition)
	tw.set_ease(vanish_ease)
	tw.tween_property(self, "scale", target_scale, vanish_duration)
	tw.parallel().tween_property(self, "modulate:a", vanish_end_alpha, vanish_duration)
	await tw.finished
	queue_free()


# 返回成功生成的数量
func _spawn_cards_from_blueprints(count: int, allowed_names: PackedStringArray) -> int:
	if _by_card_name.is_empty():
		if debug_log:
			push_warning("[CardPack] blueprint index empty; file missing/parse empty?")
		return 0

	# —— 构造候选与权重 —— 
	var cw: Dictionary = _build_candidates_and_weights(allowed_names)
	var candidates: Array[String] = cw["names"]
	var weights: Array[float] = cw["weights"]

	if candidates.is_empty():
		if debug_log:
			push_warning("[CardPack] no candidates after filter.")
		return 0

	var ok: int = 0
	for i in count:
		var pick_idx: int = _pick_weighted(weights)
		var pick: String = candidates[pick_idx]
		var row: Dictionary = _by_card_name[pick]
		var scene_path: String = str(row.get("SCENE_PATH", ""))
		if scene_path == "":
			if debug_log:
				push_warning("[CardPack] empty SCENE_PATH for CARD_NAME=" + pick)
			continue
		if _spawn_one_card(scene_path, i, count, row):
			ok += 1

	if debug_log:
		print("[CardPack] spawned=", ok, "/", count, "  candidates=", candidates, "  weights=", weights)
	return ok


# ========= 关键：按 row + CARD_NAME 生成单张卡，并配合新版 CardFactory =========

func _spawn_one_card(scene_path: String, idx: int, total: int, row: Dictionary) -> bool:
	var ps: Resource = load(scene_path)
	if ps == null or not (ps is PackedScene):
		if debug_log:
			push_warning("[CardPack] load failed: %s" % scene_path)
		return false

	var inst: Node = (ps as PackedScene).instantiate()
	if inst == null:
		return false

	var card_name: String = str(row.get("CARD_NAME", "")).strip_edges()
	if card_name == "":
		if debug_log:
			push_warning("[CardPack] row missing CARD_NAME for SCENE_PATH=" + scene_path)
		return false

	# —— 先在进树之前，把名字和 row 写到 meta（配合新版 CardFactory 的 _resolve_row_for_node 优先级）——
	inst.set_meta("CARD_NAME", card_name)
	inst.set_meta("card_row", row)
	inst.name = card_name

	# 加入场景树（这一步会触发 CardFactory.auto_apply_on_node_added → apply_to）
	get_parent().add_child(inst)

	# 设置位置（散射）
	if inst is Node2D:
		var angle: float = TAU * (float(idx) / max(1.0, float(total))) + _rng.randf_range(-0.5, 0.5)
		var offset: Vector2 = Vector2(cos(angle), sin(angle)) * spawn_scatter
		(inst as Node2D).global_position = global_position + offset

	# 再显式调用一次按名字贴数据，确保与 CardFactory 保持一致（即使 auto_apply 关闭也能正常）
	var cf: Node = _get_card_factory()
	if cf != null and card_name != "":
		if debug_log:
			print("[CardPack] apply_by_name -> ", card_name)
		if cf.has_method("apply_by_name"):
			cf.call("apply_by_name", inst, card_name)
		elif cf.has_method("apply_to"):
			cf.call("apply_to", inst)

	return true


# =========================
# ===== JSON 解析 ========
# =========================

func _build_blueprint_index() -> void:
	_by_card_name.clear()

	# 1) 读取 blueprints
	var bp: Variant = _read_json_any(blueprints_path)
	_parse_blueprints_into_index(bp, _by_card_name)

	# 如果你想用 registry 做补全，可以在这里再读一次 registry_path
	# var rg: Variant = _read_json_any(registry_path)
	# _parse_blueprints_into_index(rg, _by_card_name, false)


func _parse_blueprints_into_index(data: Variant, dst: Dictionary, override_existing: bool = true) -> void:
	if data == null:
		return

	# 支持三种结构：
	# - Array: [ {ROW}, {ROW}, ... ]
	# - Dict (flat): { "ID1": {ROW}, "ID2": {ROW} }
	# - Dict (wrapped): { "cards": [ {ROW}, ... ] }
	if typeof(data) == TYPE_ARRAY:
		_parse_rows_array(data as Array, dst, override_existing)
	elif typeof(data) == TYPE_DICTIONARY:
		var dict_data: Dictionary = data as Dictionary
		if dict_data.has("cards") and typeof(dict_data["cards"]) == TYPE_ARRAY:
			_parse_rows_array(dict_data["cards"] as Array, dst, override_existing)
		else:
			for k in dict_data.keys():
				var row_variant: Variant = dict_data[k]
				if typeof(row_variant) == TYPE_DICTIONARY:
					_add_row(dict_data[k] as Dictionary, dst, override_existing)


func _parse_rows_array(arr: Array, dst: Dictionary, override_existing: bool) -> void:
	for row_var in arr:
		if typeof(row_var) == TYPE_DICTIONARY:
			_add_row(row_var as Dictionary, dst, override_existing)


func _add_row(row: Dictionary, dst: Dictionary, override_existing: bool) -> void:
	# —— 严格字段名：CARD_NAME 与 SCENE_PATH 必填；其他字段按原样保留 —— 
	var card_name_s: String = str(row.get("CARD_NAME", ""))
	var scene_path_s: String = str(row.get("SCENE_PATH", ""))

	if card_name_s == "" or scene_path_s == "":
		return

	var key: String = card_name_s.to_lower()
	if not override_existing and dst.has(key):
		return

	dst[key] = row.duplicate(true)


func _read_json_any(path: String) -> Variant:
	if path == "" or not FileAccess.file_exists(path):
		if debug_log:
			push_warning("[CardPack] file not found: %s" % path)
		return null

	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		if debug_log:
			push_warning("[CardPack] cannot open: %s" % path)
		return null

	var txt: String = f.get_as_text()
	f.close()

	var parsed: Variant = JSON.parse_string(txt)
	if parsed == null:
		if debug_log:
			push_warning("[CardPack] json parse failed: %s" % path)
	return parsed


# ---------- 命中兜底 ----------

func _is_mouse_over_sprite() -> bool:
	if _sprite == null or _sprite.texture == null:
		return false

	var tex_size: Vector2 = _sprite.texture.get_size()
	if tex_size == Vector2.ZERO:
		return false

	var center: Vector2 = _sprite.global_position
	var scl: Vector2 = _sprite.global_scale
	var half: Vector2 = tex_size * 0.5 * scl
	var mouse_g: Vector2 = get_global_mouse_position()

	if absf(_sprite.global_rotation) < 0.001:
		var rect: Rect2 = Rect2(center - half, half * 2.0)
		return rect.has_point(mouse_g)

	var xf: Transform2D = _sprite.get_global_transform().affine_inverse()
	var local: Vector2 = xf * mouse_g
	var local_half: Vector2 = tex_size * 0.5
	return Rect2(-local_half, tex_size).has_point(local)


# ---------- 对齐到格中心（若找不到格子则不动） ----------

func _snap_to_grid_center() -> void:
	if _grid == null or not is_instance_valid(_grid):
		return

	var center: Vector2 = global_position
	if _grid.has_method("world_to_cell_center"):
		center = _grid.call("world_to_cell_center", global_position)
	else:
		if _grid.has_method("_world_to_cell_idx") and _grid.has_method("get_cell_pos"):
			var cell: int = int(_grid.call("_world_to_cell_idx", global_position))
			if cell != -1:
				center = _grid.call("get_cell_pos", cell)

	if _anim != null and _anim.has_method("tween_to"):
		_anim.call("tween_to", center, 0.12, 1.0)
		await get_tree().create_timer(0.12).timeout
	else:
		var tw: Tween = create_tween()
		tw.tween_property(self, "global_position", center, 0.12)
		await tw.finished


# ---------- 计算当前所在格子的中心（不移动，仅返回） ----------

func _get_current_cell_center_global() -> Vector2:
	var center: Vector2 = global_position
	if _grid != null and is_instance_valid(_grid):
		if _grid.has_method("world_to_cell_center"):
			center = _grid.call("world_to_cell_center", global_position)
		elif _grid.has_method("_world_to_cell_idx") and _grid.has_method("get_cell_pos"):
			var cell: int = int(_grid.call("_world_to_cell_idx", global_position))
			if cell != -1:
				center = _grid.call("get_cell_pos", cell)
	return center


# ---------- 提供给 SellingArea 的公共回弹接口 ----------

func snap_back_to_grid() -> void:
	# 优先：记录的原格中心
	if has_meta("pre_drag_cell_center"):
		var v: Variant = get_meta("pre_drag_cell_center")
		if typeof(v) == TYPE_VECTOR2:
			var t1: Tween = create_tween()
			t1.set_trans(bounce_trans)
			t1.set_ease(bounce_ease)
			t1.tween_property(self, "global_position", (v as Vector2), bounce_back_duration)
			return

	# 次优：拖拽前全局坐标
	if has_meta("pre_drag_global_pos"):
		var p: Variant = get_meta("pre_drag_global_pos")
		if typeof(p) == TYPE_VECTOR2:
			var t2: Tween = create_tween()
			t2.set_trans(bounce_trans)
			t2.set_ease(bounce_ease)
			t2.tween_property(self, "global_position", (p as Vector2), bounce_back_duration)
			return

	# 兜底：如果两者都没有，就立即对齐到当前格中心
	var now_center: Vector2 = _get_current_cell_center_global()
	if (now_center - global_position).length() > 1.0:
		var t3: Tween = create_tween()
		t3.set_trans(bounce_trans)
		t3.set_ease(bounce_ease)
		t3.tween_property(self, "global_position", now_center, bounce_back_duration)


# ---------- 候选集合与权重 ----------

func _build_candidates_and_weights(allowed_names: PackedStringArray) -> Dictionary:
	var candidates: Array[String] = []
	if allowed_names.is_empty():
		for k in _by_card_name.keys():
			candidates.append(String(k))
	else:
		for nm in allowed_names:
			var key: String = nm.to_lower()
			if _by_card_name.has(key):
				candidates.append(key)

	var weights: Array[float] = []
	if spawn_card_weights.size() == candidates.size() and candidates.size() > 0:
		for i in range(candidates.size()):
			var w: float = float(spawn_card_weights[i])
			weights.append(max(w, 0.0))
	else:
		if candidates.size() > 0:
			var p: float = 1.0 / float(candidates.size())
			for _i in range(candidates.size()):
				weights.append(p)

	# 归一
	var s: float = 0.0
	for w in weights:
		s += w
	if s <= 0.0:
		var p2: float = 1.0 / float(max(1, weights.size()))
		for i in range(weights.size()):
			weights[i] = p2
	else:
		for i in range(weights.size()):
			weights[i] = weights[i] / s

	return {"names": candidates, "weights": weights}


func _pick_weighted(weights: Array[float]) -> int:
	var r: float = _rng.randf()
	var acc: float = 0.0
	for i in range(weights.size()):
		acc += weights[i]
		if r <= acc:
			return i
	return max(0, weights.size() - 1)


func _normalize_or_warn_weights() -> void:
	if spawn_card_names.size() > 0 and spawn_card_weights.size() > 0:
		if spawn_card_weights.size() != spawn_card_names.size():
			push_warning("[CardPack] spawn_card_weights size != spawn_card_names size; will auto-even at runtime.")
			return
		var s: float = 0.0
		for w in spawn_card_weights:
			s += float(w)
		if s <= 0.0:
			push_warning("[CardPack] weights sum <= 0; will auto-even at runtime.")
			return
		if normalize_weights_on_start:
			for i in range(spawn_card_weights.size()):
				spawn_card_weights[i] = float(spawn_card_weights[i]) / s


# =========================
# ===== 私有工具函数 =====
# =========================

func _get_card_factory() -> Node:
	var root: Node = get_tree().get_root()
	if root.has_node(^"/root/CardFactory"):
		return root.get_node(^"/root/CardFactory")
	return null


func _get_card_limit_manager() -> Node:
	var root: Node = get_tree().get_root()
	if root.has_node(^"/root/CardLimitManager"):
		return root.get_node(^"/root/CardLimitManager")
	return null
