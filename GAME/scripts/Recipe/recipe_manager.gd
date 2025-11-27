# recipemanager.gd 
extends Node
class_name recipemanager

@export var recipe_files: Array[String] = []
@export var card_blueprints_file: String = ""
@export var debug_log: bool = false

# ========= 安全删除 =========
@export var reparent_before_delete: bool = true

# ========= 通知回调 =========
@export var notify_script_paths: PackedStringArray = []
@export var notify_methods_single: PackedStringArray = [
	"on_pile_will_be_sold",
	"on_node_will_be_sold",
	"will_remove_node",
	"will_remove_card",
	"on_card_will_be_sold"
]

# ========= 合成延迟（命中→等待，同时也是旧卡聚拢动画时长）=========
@export_range(0.5, 30.0, 0.5) var craft_delay_sec: float = 5.0

# ========= FX 参数（不使用 Tween，全程 _process）=========
@export_range(0.1, 3.0, 0.05) var fx_total_sec: float = 0.65
@export_range(0.05, 1.0, 0.01) var fx_glow_peak_sec: float = 0.18
@export_range(0.05, 1.0, 0.01) var fx_glow_fade_sec: float = 0.28
@export_range(0.1, 2.0, 0.05) var fx_newcard_appear_sec: float = 0.35
@export var fx_jitter_px: float = 1.4
@export var fx_glow_color: Color = Color(1.0, 0.85, 0.55, 0.9)
@export var fx_trail_count: int = 2
@export var fx_trail_alpha: float = 0.28
@export var fx_dust_count: int = 18
@export var fx_dust_min_v: float = 14.0
@export var fx_dust_max_v: float = 38.0

var _sig_to_output: Dictionary = {}
var _scene_by_name: Dictionary = {}
var _is_crafting_now: bool = false
var _notify_script_res: Array = []
var _last_spawned_card: Node2D = null
var _limit_recalc_pending: bool = false

# ================== FX 类 ==================
class CraftFX:
	extends Node2D
	signal finished
	signal cancelled

	var cards: Array[Node2D] = []
	var start_pos: Array[Vector2] = []
	var start_scale: Array[Vector2] = []
	var center: Vector2
	var total_sec: float
	var glow_peak: float
	var glow_fade: float
	var newcard_sec: float
	var jitter_px: float
	var trail_count: int
	var trail_alpha: float
	var dust_count: int
	var dust_min_v: float
	var dust_max_v: float
	var flare_color: Color
	var on_execute_craft: Callable
	var new_card_node: Node2D = null
	var expected_sig: String = ""
	var pile_wref: WeakRef

	# 参与者实例集合（仅内部用于取消判定）
	var member_ids: PackedInt64Array = []
	# 本轮定向取消连接的缓存：使用弱引用避免已释放实例赋值报错
	# 结构：[{ "wref": WeakRef, "call": Callable }, ...]
	var _cancel_bindings: Array = []

	var _t: float = 0.0
	var _phase_done: bool = false
	var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
	var _dust: Array = []                 # [{pos:Vector2, v:float, r:float, a:float}]
	var _trails: Array = []               # 每帧重建 [{pos:Vector2, alpha:float}]
	var _cancel_requested: bool = false

	func _ready() -> void:
		_rng.randomize()
		start_pos.clear()
		start_scale.clear()
		member_ids.clear()

		for c in cards:
			start_pos.append(c.global_position)
			start_scale.append(c.global_scale)
			member_ids.append(int(c.get_instance_id()))

		_dust.clear()
		for i in dust_count:
			_dust.append({
				"pos": center + Vector2(_rng.randf_range(-24.0, 24.0), _rng.randf_range(-8.0, 8.0)),
				"v": _rng.randf_range(dust_min_v, dust_max_v),
				"r": _rng.randf_range(1.0, 2.6),
				"a": _rng.randf_range(0.45, 0.8)
			})
		set_process(true)

	func request_cancel() -> void:
		_cancel_requested = true

	func _ease_out_cubic(t: float) -> float:
		var x: float = clampf(t, 0.0, 1.0)
		var inv: float = 1.0 - x
		return 1.0 - inv * inv * inv

	func _yoyo_scale(t: float) -> float:
		return 1.0 + 0.05 * (1.0 - abs(2.0 * t - 1.0))

	func _current_pile_signature() -> String:
		var pile: Node = pile_wref.get_ref() if pile_wref != null else null
		if pile == null or not is_instance_valid(pile) or not pile.has_method("get_cards"):
			return ""
		var arr_any: Variant = pile.call("get_cards")
		if typeof(arr_any) != TYPE_ARRAY:
			return ""
		var bag: Dictionary = {}
		for v in (arr_any as Array):
			var n: Node = v
			if n != null and n.has_meta("card_data"):
				var row_any: Variant = n.get_meta("card_data")
				if typeof(row_any) == TYPE_DICTIONARY:
					var row: Dictionary = row_any
					if row.has("CARD_NAME"):
						var nm: String = String(row["CARD_NAME"]).strip_edges().to_lower()
						if nm != "":
							bag[nm] = int(bag.get(nm, 0)) + 1
		var keys_str: Array = []
		for k in bag.keys():
			keys_str.append(String(k))
		keys_str.sort()
		var parts: Array = []
		for k2 in keys_str:
			parts.append("%s:%d" % [k2, int(bag[k2])])
		return "|".join(parts)

	func _current_member_ids() -> PackedInt64Array:
		var pile: Node = pile_wref.get_ref() if pile_wref != null else null
		var ids: PackedInt64Array = PackedInt64Array()
		if pile == null or not is_instance_valid(pile) or not pile.has_method("get_cards"):
			return ids
		var arr_any: Variant = pile.call("get_cards")
		if typeof(arr_any) != TYPE_ARRAY:
			return ids
		for v in (arr_any as Array):
			var n: Node = v
			if n != null:
				ids.append(int(n.get_instance_id()))
		return ids

	func _ids_equal(a: PackedInt64Array, b: PackedInt64Array) -> bool:
		if a.size() != b.size():
			return false
		var aa := a.duplicate()
		var bb := b.duplicate()
		aa.sort()
		bb.sort()
		for i in aa.size():
			if aa[i] != bb[i]:
				return false
		return true

	func _process(dt: float) -> void:
		# 任何时刻的取消：定向交互或“成员集合变化”
		if _cancel_requested:
			emit_signal("cancelled")
			queue_free()
			return

		var cur_ids: PackedInt64Array = _current_member_ids()
		# pile 失效或成员集合变化（仅在未进入显形阶段时触发取消）
		if cur_ids.size() == 0 or (!_phase_done and not _ids_equal(cur_ids, member_ids)):
			emit_signal("cancelled")
			queue_free()
			return

		# —— 全局时间暂停：不推进动画时间，但仍允许上面的取消判定 —— 
		if GameTimeManager.is_paused():
			return

		_t += dt
		var t_norm: float = clampf(_t / total_sec, 0.0, 1.0)
		var move_w: float = _ease_out_cubic(t_norm)
		var yoyo: float = _yoyo_scale(t_norm)

		_trails.clear()

		for i in cards.size():
			var c: Node2D = cards[i]
			if c == null or not is_instance_valid(c):
				continue
			var p0: Vector2 = start_pos[i]
			var p: Vector2 = p0.lerp(center, move_w)
			var decay: float = 1.0 - t_norm
			p += Vector2(
				sin((_t * 14.0) + float(i)) * jitter_px * decay,
				cos((_t * 16.0) + float(i) * 0.7) * jitter_px * 0.6 * decay
			)
			c.global_position = p
			c.global_scale = start_scale[i] * Vector2(yoyo, yoyo)

			for k_i in trail_count:
				var back_t: float = clampf(t_norm - (0.08 * float(k_i + 1)), 0.0, 1.0)
				var bp: Vector2 = p0.lerp(center, _ease_out_cubic(back_t))
				var a: float = trail_alpha * (0.66 - 0.28 * float(k_i))
				_trails.append({"pos": bp, "alpha": a})

		queue_redraw()

		# 阶段切换：动画结束 -> 再复核签名 -> 合成
		if not _phase_done and _t >= total_sec:
			_phase_done = true
			if _current_pile_signature() == expected_sig and on_execute_craft.is_valid():
				on_execute_craft.call()

			var parent: Node = get_parent()
			if parent != null and parent.get_child_count() > 0:
				var last: Node = parent.get_child(parent.get_child_count() - 1)
				var as2d: Node2D = last as Node2D
				if as2d != null and is_instance_valid(as2d):
					new_card_node = as2d
					new_card_node.self_modulate.a = 0.0
					new_card_node.scale = Vector2(0.86, 0.86)

			_t = 0.0

		# 新卡显形阶段
		if _phase_done and new_card_node != null and is_instance_valid(new_card_node):
			var w: float = _ease_out_cubic(clampf(_t / newcard_sec, 0.0, 1.0))
			new_card_node.self_modulate.a = w
			var s2: float = lerpf(0.86, 1.0, w)
			new_card_node.scale = Vector2(s2, s2)
			if w >= 1.0:
				emit_signal("finished")
				queue_free()
		elif _phase_done and new_card_node == null:
			emit_signal("finished")
			queue_free()

	func _draw() -> void:
		var r: float = 0.0
		var a: float = 0.0
		if _t <= glow_peak:
			var k: float = _t / max(glow_peak, 0.0001)
			k = _ease_out_cubic(k)
			r = lerpf(6.0, 60.0, k)
			a = lerpf(0.0, flare_color.a, k)
		else:
			var k2: float = (_t - glow_peak) / max(glow_fade, 0.0001)
			k2 = clampf(k2, 0.0, 1.0)
			r = lerpf(60.0, 92.0, k2)
			a = lerpf(flare_color.a, 0.0, _ease_out_cubic(k2))
		if a > 0.0:
			draw_circle(center, r, Color(flare_color.r, flare_color.g, flare_color.b, a))

		var sz: float = 10.0
		for t in _trails:
			var pos: Vector2 = t["pos"]
			var alpha: float = clampf(float(t["alpha"]), 0.0, 1.0)
			var col: Color = Color(1.0, 0.96, 0.86, alpha)
			draw_rect(Rect2(pos - Vector2(sz, sz * 0.6), Vector2(sz * 2.0, sz * 1.2)), col, true)

		var paused: bool = GameTimeManager.is_paused()
		for i in _dust.size():
			var d: Dictionary = _dust[i]
			# 暂停时只绘制，不更新 dust 的位置和透明度
			if not paused:
				d["pos"] = (d["pos"] as Vector2) + Vector2(0, d["v"] as float) * get_process_delta_time()
				d["a"] = max(0.0, (d["a"] as float) - 0.18 * get_process_delta_time())
				_dust[i] = d
			var col2: Color = Color(0.92, 0.86, 0.75, float(d["a"]))
			draw_circle(d["pos"], float(d["r"]), col2)

# ================== 生命周期 ==================
func _ready() -> void:
	_load_recipes()
	_load_card_blueprints()
	_notify_script_res.clear()
	for p in notify_script_paths:
		var sp: String = String(p).strip_edges()
		if sp == "":
			continue
		if not ResourceLoader.exists(sp):
			if debug_log:
				print("[RecipeManager] notify script not found:", sp)
			continue
		var s_res: Resource = load(sp)
		if s_res is Script:
			_notify_script_res.append(s_res)
	call_deferred("_connect_existing_piles")
	get_tree().connect("node_added", Callable(self, "_on_node_added"))

# ================== 连接 PileManager ==================
func _connect_existing_piles() -> void:
	var root: Node = get_tree().root
	var stack: Array = [root]
	while stack.size() > 0:
		var n: Node = stack.pop_back() as Node
		for child in n.get_children():
			stack.append(child)
		if _is_pile(n):
			_connect_pile(n)

func _on_node_added(n: Node) -> void:
	if _is_pile(n):
		if debug_log:
			print("[RecipeManager] found pile:", n.name)
		_connect_pile(n)

func _is_pile(n: Node) -> bool:
	return n is PileManager

func _connect_pile(pile: Node) -> void:
	if not pile.is_connected("pile_changed", Callable(self, "_on_pile_changed")):
		pile.connect("pile_changed", Callable(self, "_on_pile_changed"))
		if debug_log:
			print("[RecipeManager] connected pile_changed ->", pile.name)

# ================== 配方/蓝图加载 ==================
func _load_recipes() -> void:
	_sig_to_output.clear()
	for path in recipe_files:
		if path == "" or not FileAccess.file_exists(path):
			if debug_log:
				print("[RecipeManager] recipe file not found:", path)
			continue
		var f: FileAccess = FileAccess.open(path, FileAccess.READ)
		if f == null:
			continue
		var txt: String = f.get_as_text()
		f.close()
		var data: Variant = JSON.parse_string(txt)
		if typeof(data) == TYPE_ARRAY:
			_parse_recipe_array(data as Array)
		elif typeof(data) == TYPE_DICTIONARY:
			var d: Dictionary = data
			if d.has("recipes") and typeof(d["recipes"]) == TYPE_ARRAY:
				_parse_recipe_array(d["recipes"] as Array)
	if debug_log:
		print("[RecipeManager] loaded recipes:", _sig_to_output.size())

func _parse_recipe_array(arr_any: Array) -> void:
	var arr: Array = arr_any
	for row_any in arr:
		if typeof(row_any) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_any
		var inputs: Array = []
		var keys: Array = ["IN_PUT", "IN_PUT__1", "IN_PUT__2", "IN_PUT__3", "IN_PUT__4"]
		for k in keys:
			if row.has(k):
				var v_raw: String = String(row[k]).strip_edges()
				var v: String = v_raw.to_lower()
				if v != "" and v != "n/a":
					inputs.append(v)
		if inputs.is_empty():
			continue
		if not row.has("CARD_NAME"):
			continue
		var out_name_raw: String = String(row["CARD_NAME"]).strip_edges()
		if out_name_raw == "":
			continue
		var sig: String = _make_signature_from_list(inputs)
		_sig_to_output[sig] = out_name_raw
		if debug_log:
			print("[RecipeManager] recipe:", sig, "=>", out_name_raw)

func _load_card_blueprints() -> void:
	_scene_by_name.clear()
	if card_blueprints_file == "" or not FileAccess.file_exists(card_blueprints_file):
		if debug_log:
			print("[RecipeManager] blueprints not found:", card_blueprints_file)
		return
	var f: FileAccess = FileAccess.open(card_blueprints_file, FileAccess.READ)
	if f == null:
		return
	var txt: String = f.get_as_text()
	f.close()
	var data: Variant = JSON.parse_string(txt)
	var rows: Array = []
	if typeof(data) == TYPE_ARRAY:
		rows = data as Array
	elif typeof(data) == TYPE_DICTIONARY:
		var d: Dictionary = data
		if d.has("cards") and typeof(d["cards"]) == TYPE_ARRAY:
			rows = d["cards"] as Array
	for r_any in rows:
		if typeof(r_any) != TYPE_DICTIONARY:
			continue
		var r: Dictionary = r_any
		var nm: String = String(r.get("CARD_NAME", "")).strip_edges()
		var sp: String = String(r.get("SCENE_PATH", "")).strip_edges()
		if nm != "" and sp != "":
			_scene_by_name[nm.to_lower()] = sp
	if debug_log:
		print("[RecipeManager] blueprints indexed:", _scene_by_name.size())

# ================== 主逻辑：检测即开播 ==================
func _on_pile_changed(pile: Node) -> void:
	if pile == null or not is_instance_valid(pile):
		return
	if _is_pile_consumed(pile):
		return

	var names: Dictionary = _bag_from_pile(pile)
	if debug_log:
		print("[RecipeManager] bag:", names)
	if names.is_empty():
		return

	# 自触发保护
	if names.size() == 1:
		for k in names.keys():
			var cnt: int = int(names[k])
			if cnt == 1 and pile.has_method("get_cards"):
				var arr_any: Variant = pile.call("get_cards")
				if typeof(arr_any) == TYPE_ARRAY:
					var arr: Array = arr_any as Array
					if arr.size() == 1:
						var c := arr[0] as Node2D
						if c != null and is_instance_valid(c) and c.has_meta("_crafted_tag"):
							if debug_log:
								print("[RecipeManager] skip self-craft for crafted card")
							return

	var sig: String = _make_signature_from_bag(names)
	if debug_log:
		print("[RecipeManager] sig:", sig)
	if not _sig_to_output.has(sig):
		return

	var out_name_raw: String = String(_sig_to_output[sig]).strip_edges()
	if out_name_raw == "":
		return
	var out_name_key: String = out_name_raw.to_lower()
	if not _scene_by_name.has(out_name_key):
		if debug_log:
			print("[RecipeManager] no blueprint for:", out_name_raw)
		return
	var scene_path: String = _scene_by_name[out_name_key]

	_mark_pile_consumed(pile)
	_play_craft_fx_and_execute(pile as Node2D, out_name_raw, scene_path, sig)

# ================== 播放 FX + 执行 Craft（动画末复核签名） ==================
func _play_craft_fx_and_execute(pile2d: Node2D, out_name_raw: String, scene_path: String, expected_sig: String) -> void:
	if pile2d == null or not is_instance_valid(pile2d):
		return
	if not pile2d.has_method("get_cards"):
		return
	var arr_any: Variant = pile2d.call("get_cards")
	if typeof(arr_any) != TYPE_ARRAY:
		return
	var cards: Array = arr_any as Array
	var center: Vector2 = (pile2d as Node2D).global_position

	# FX 节点
	var fx: CraftFX = CraftFX.new()
	fx.cards = []
	for v2 in cards:
		var c2: Node2D = v2 as Node2D
		if c2 != null and is_instance_valid(c2):
			fx.cards.append(c2)
	fx.center = center
	fx.total_sec = craft_delay_sec
	fx.glow_peak = fx_glow_peak_sec
	fx.glow_fade = fx_glow_fade_sec
	fx.newcard_sec = fx_newcard_appear_sec
	fx.jitter_px = fx_jitter_px
	fx.trail_count = clampi(fx_trail_count, 0, 3)
	fx.trail_alpha = fx_trail_alpha
	fx.dust_count = fx_dust_count
	fx.dust_min_v = fx_dust_min_v
	fx.dust_max_v = fx_dust_max_v
	fx.flare_color = fx_glow_color
	fx.expected_sig = expected_sig
	fx.pile_wref = weakref(pile2d)
	fx.on_execute_craft = Callable(self, "_finish_execute_craft").bind(pile2d, out_name_raw, scene_path, center)

	add_child(fx)

	# —— 仅为本轮参与者与本轮 pile 建立“定向取消”回调（使用 WeakRef 存储对象）——
	for v in cards:
		if v == null or not is_instance_valid(v):
			continue
		var obj := v as Object
		if obj != null and obj.has_signal("drag_started"):
			var cb := func () -> void:
				if is_instance_valid(fx):
					fx.request_cancel()
			if not obj.is_connected("drag_started", cb):
				obj.connect("drag_started", cb)
			fx._cancel_bindings.append({ "wref": weakref(obj), "call": cb })

	if pile2d != null and is_instance_valid(pile2d):
		var pile_obj := pile2d as Object
		if pile_obj != null and pile_obj.has_signal("drag_started"):
			var cb_pile := func () -> void:
				if is_instance_valid(fx):
					fx.request_cancel()
			if not pile_obj.is_connected("drag_started", cb_pile):
				pile_obj.connect("drag_started", cb_pile)
			fx._cancel_bindings.append({ "wref": weakref(pile_obj), "call": cb_pile })

	# —— 在结束/取消时清理本轮的“定向取消”连接（弱引用取回活对象；变量不加类型）——
	fx.cancelled.connect(func () -> void:
		_unmark_pile_consumed(pile2d)
		for entry in fx._cancel_bindings:
			var wr = entry.get("wref", null)
			var c: Callable = entry.get("call", Callable())
			var o = (wr as WeakRef).get_ref() if wr != null else null
			if o != null and is_instance_valid(o) and c.is_valid():
				if o.is_connected("drag_started", c):
					o.disconnect("drag_started", c)
		fx._cancel_bindings.clear()
		if debug_log:
			print("[RecipeManager] craft cancelled (scoped)")
	)

	fx.finished.connect(func () -> void:
		for entry in fx._cancel_bindings:
			var wr2 = entry.get("wref", null)
			var c2: Callable = entry.get("call", Callable())
			var o2 = (wr2 as WeakRef).get_ref() if wr2 != null else null
			if o2 != null and is_instance_valid(o2) and c2.is_valid():
				if o2.is_connected("drag_started", c2):
					o2.disconnect("drag_started", c2)
		fx._cancel_bindings.clear()
		var new_card: Node2D = _last_spawned_card
		if new_card != null and is_instance_valid(new_card) and new_card.has_method("set_pickable"):
			new_card.call("set_pickable", true)
	)

# ——（保留但不再连接使用）全局取消入口 ——
func _on_cancel_by_interaction(_arg: Variant = null) -> void:
	pass

# ================== 真正执行 Craft ==================
func _finish_execute_craft(pile2d: Node2D, out_name_raw: String, scene_path: String, center: Vector2) -> void:
	_is_crafting_now = true

	var parent: Node = pile2d.get_parent()
	_delete_pile_safe(pile2d)

	var ps: PackedScene = load(scene_path) as PackedScene
	if ps == null:
		_is_crafting_now = false
		return
	var node: Node = ps.instantiate()
	var card2d: Node2D = node as Node2D
	if card2d == null:
		_is_crafting_now = false
		return

	if parent != null:
		parent.add_child(card2d)
	else:
		add_child(card2d)
	card2d.global_position = center
	card2d.set_meta("_crafted_tag", true)

	var cf: Node = get_node_or_null(^"/root/CardFactory")
	if cf != null and cf.has_method("apply_by_name"):
		cf.call("apply_by_name", card2d, out_name_raw)
	card2d.call_deferred("set_meta", "_crafted_tag", null)

	card2d.self_modulate.a = 0.0
	card2d.scale = Vector2(0.86, 0.86)
	_last_spawned_card = card2d

	_is_crafting_now = false

	# —— 合成会删掉旧卡、加一张新卡：请求 CardLimitManager 在本帧稍后重算一次 —— 
	_request_limit_recalc()


# ================== Bag / 签名 ==================
func _bag_from_pile(pile: Node) -> Dictionary:
	var bag: Dictionary = {}
	if not pile.has_method("get_cards"):
		return bag
	var arr_any: Variant = pile.call("get_cards")
	if typeof(arr_any) != TYPE_ARRAY:
		return bag
	for v in (arr_any as Array):
		var c: Node = v
		if c == null:
			continue
		if not c.has_meta("card_data"):
			return {}
		var row_any: Variant = c.get_meta("card_data")
		if typeof(row_any) != TYPE_DICTIONARY:
			return {}
		var row: Dictionary = row_any
		if not row.has("CARD_NAME"):
			return {}
		var nm_raw: String = String(row["CARD_NAME"]).strip_edges()
		var nm: String = nm_raw.to_lower()
		if nm == "":
			return {}
		bag[nm] = int(bag.get(nm, 0)) + 1
	return bag

func _make_signature_from_bag(bag: Dictionary) -> String:
	var keys_str: Array = []
	for k in bag.keys():
		keys_str.append(String(k))
	keys_str.sort()
	var parts: Array = []
	for k in keys_str:
		parts.append("%s:%d" % [k, int(bag[k])])
	return "|".join(parts)

func _make_signature_from_list(items: Array) -> String:
	var bag: Dictionary = {}
	for it in items:
		var k: String = it.to_lower()
		bag[k] = int(bag.get(k, 0)) + 1
	return _make_signature_from_bag(bag)

# ================== 删除广播 & 安全删除 ==================
func _pre_delete_cleanup(node2d: Node2D) -> void:
	if node2d.has_method("cancel_drag"):
		node2d.call("cancel_drag")
	elif node2d.has_method("end_drag"):
		node2d.call("end_drag")
	if node2d.has_method("set_selected"):
		node2d.call("set_selected", false)
	_notify_managers_single(node2d)
	if reparent_before_delete and node2d.get_parent() != self:
		var keep_pos: Vector2 = node2d.global_position
		var keep_rot: float = node2d.global_rotation
		var keep_scale: Vector2 = node2d.global_scale
		var parent: Node = node2d.get_parent()
		if parent != null:
			parent.remove_child(node2d)
		add_child(node2d)
		node2d.global_position = keep_pos
		node2d.global_rotation = keep_rot
		node2d.global_scale = keep_scale

func _notify_managers_single(target: Node2D) -> void:
	var receivers: Array = _collect_receivers_by_scripts()
	_call_receivers_methods(receivers, target)

func _collect_receivers_by_scripts() -> Array:
	var out: Array = []
	var stack: Array = [get_tree().root]
	while stack.size() > 0:
		var n: Node = stack.pop_back() as Node
		for c in n.get_children():
			stack.append(c)
		var s: Script = n.get_script() as Script
		if s == null:
			continue
		for want in _notify_script_res:
			var want_script: Script = want as Script
			if s == want_script:
				out.append(n)
				break
			if (s is GDScript) and (want_script is GDScript):
				if (s as GDScript).inherits_script(want_script as GDScript):
					out.append(n)
					break
	return out

func _call_receivers_methods(receivers: Array, target: Node2D) -> void:
	for m in receivers:
		for method_name in notify_methods_single:
			if m.has_method(method_name):
				m.call(method_name, target)

func _delete_pile_safe(pile2d: Node2D) -> void:
	if pile2d == null or not is_instance_valid(pile2d):
		return
	if pile2d.is_connected("pile_changed", Callable(self, "_on_pile_changed")):
		pile2d.disconnect("pile_changed", Callable(self, "_on_pile_changed"))
	_pre_delete_cleanup(pile2d)
	if pile2d.has_method("get_cards"):
		var arr_any: Variant = pile2d.call("get_cards")
		if typeof(arr_any) == TYPE_ARRAY:
			for v in (arr_any as Array):
				var c: Node2D = v as Node2D
				if c == null or not is_instance_valid(c):
					continue
				_pre_delete_cleanup(c)
				c.set_deferred("process_mode", Node.PROCESS_MODE_DISABLED)
				c.set_deferred("visible", false)
				c.call_deferred("queue_free")
	pile2d.set_deferred("process_mode", Node.PROCESS_MODE_DISABLED)
	pile2d.set_deferred("visible", false)
	pile2d.call_deferred("queue_free")

# ================== 去重冷却 ==================
var _consumed_piles: Dictionary = {}
var _dedup_cooldown_sec: float = 0.2

func _mark_pile_consumed(pile: Node) -> void:
	if pile == null or not is_instance_valid(pile):
		return
	var iid: int = int(pile.get_instance_id())
	_consumed_piles[iid] = true
	var tmr: Timer = Timer.new()
	tmr.one_shot = true
	tmr.wait_time = _dedup_cooldown_sec
	add_child(tmr)
	tmr.timeout.connect(func () -> void:
		_consumed_piles.erase(iid)
		tmr.queue_free()
	)
	tmr.start()

func _unmark_pile_consumed(pile: Node) -> void:
	if pile == null or not is_instance_valid(pile):
		return
	_consumed_piles.erase(int(pile.get_instance_id()))

func _is_pile_consumed(pile: Node) -> bool:
	if pile == null or not is_instance_valid(pile):
		return false
	return bool(_consumed_piles.get(int(pile.get_instance_id()), false))

func _request_limit_recalc() -> void:
	if _limit_recalc_pending:
		return
	_limit_recalc_pending = true
	call_deferred("_do_limit_recalc")


func _do_limit_recalc() -> void:
	_limit_recalc_pending = false
	var mgr := _get_card_limit_manager()
	if mgr != null:
		if mgr.has_method("request_recalc"):
			mgr.call("request_recalc")
		elif mgr.has_method("recalculate_from_board"):
			mgr.call("recalculate_from_board")


func _get_card_limit_manager() -> Node:
	var root := get_tree().get_root()
	if root.has_node(^"/root/CardLimitManager"):
		return root.get_node(^"/root/CardLimitManager")
	return null
