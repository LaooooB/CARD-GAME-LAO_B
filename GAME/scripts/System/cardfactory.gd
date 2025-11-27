extends Node

# ========= 可在 Inspector 设置 =========
@export_file("*.json") var registry_json_path: String = "res://GAME/data/cards/card_registry.json"
@export_file("*.json") var blueprints_json_path: String = "res://GAME/data/cards/card_blueprints.json"

# 自动监听：节点加入场景树就尝试应用
@export var auto_apply_on_node_added: bool = true
# 仅在这些组里的节点才尝试（留空=不限制）
@export var only_groups: Array[String] = []  # 空 = 不限制分组

# 名字显示：在卡实例内的相对路径（不存在会自动创建）
@export var card_name_label_path: String = "NameLabel"
@export var name_text_uppercase: bool = true
@export var name_font_size: int = 14
@export var name_position: Vector2 = Vector2(0, -42)

# 图标（可选）：在卡实例内的相对路径；JSON 中图标字段名（没有可留空）
@export var icon_node_path: String = "Icon"
@export var icon_json_key: String = "ICON_PATH"

@export var debug_log: bool = false

# ========= 运行期数据 =========
var _by_name: Dictionary = {}
var _by_scene: Dictionary = {}
var _loaded_ok: bool = false

# ========= 生命周期 =========
func _ready() -> void:
	_reload_data()

	# ✅ 关键：一定要连接 node_added，否则不会自动贴数据
	if auto_apply_on_node_added:
		get_tree().node_added.connect(_on_tree_node_added)

	if debug_log:
		print("[CardFactory] ready. loaded=", _loaded_ok,
			" names=", _by_name.size(), " scenes=", _by_scene.size())

# ========= 公共 API =========
func reload_data() -> void:
	_reload_data()

func apply_to(card_node: Node) -> bool:
	if card_node == null:
		return false
	var row: Dictionary = _resolve_row_for_node(card_node)
	if row.is_empty():
		if debug_log:
			print("[CardFactory] no row matched for:", card_node.name)
		return false
	_apply_row_to_card(card_node, row)
	return true

func apply_by_name(card_node: Node, card_name: String) -> bool:
	if card_node == null or card_name == "":
		return false
	var key := card_name.strip_edges().to_lower()
	if not _by_name.has(key):
		if debug_log:
			print("[CardFactory] apply_by_name no such:", card_name)
		return false
	_apply_row_to_card(card_node, _by_name[key])
	return true

# ========= 内部：数据加载与索引 =========
func _reload_data() -> void:
	_by_name.clear()
	_by_scene.clear()
	_loaded_ok = false

	var reg := _load_json_array(registry_json_path)
	var bp := _load_json_array(blueprints_json_path)

	for row in bp:
		if typeof(row) == TYPE_DICTIONARY:
			_index_row(row)

	for row2 in reg:
		if typeof(row2) == TYPE_DICTIONARY:
			_merge_or_index_registry_row(row2)

	_loaded_ok = (not _by_name.is_empty()) or (not _by_scene.is_empty())

func _load_json_array(path: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if path == "" or not FileAccess.file_exists(path):
		if debug_log:
			print("[CardFactory] json not found:", path)
		return out
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		if debug_log:
			print("[CardFactory] open fail:", path)
		return out
	var txt: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_ARRAY:
		for v in parsed:
			if typeof(v) == TYPE_DICTIONARY:
				out.append(v as Dictionary)
	else:
		if debug_log:
			print("[CardFactory] parse not array:", path)
	return out

func _index_row(row: Dictionary) -> void:
	var name := str(row.get("CARD_NAME", "")).strip_edges()
	var scene := str(row.get("SCENE_PATH","")).strip_edges()
	if name != "":
		_by_name[name.to_lower()] = row.duplicate(true)
	if scene != "":
		_by_scene[_norm_path(scene)] = row.duplicate(true)

func _merge_or_index_registry_row(r: Dictionary) -> void:
	var name := str(r.get("CARD_NAME","")).strip_edges()
	var scene := str(r.get("SCENE_PATH","")).strip_edges()
	var key := name.to_lower() if name != "" else ""
	var merged: Dictionary = {}
	if key != "" and _by_name.has(key):
		merged = _by_name[key].duplicate(true)
		for k in r.keys():
			if not merged.has(k) or str(merged[k]) == "":
				merged[k] = r[k]
		_by_name[key] = merged
		if scene != "":
			_by_scene[_norm_path(scene)] = merged
	elif scene != "":
		_by_scene[_norm_path(scene)] = r.duplicate(true)
		if name != "":
			_by_name[key] = r.duplicate(true)
	elif name != "":
		_by_name[key] = r.duplicate(true)

func _norm_path(p: String) -> String:
	return p.replace("\\", "/")

# ========= 自动匹配与应用 =========
func _on_tree_node_added(n: Node) -> void:
	if n == self: return
	if not is_instance_valid(n): return
	if not _loaded_ok: return

	# ✅ 不限制分组，直接尝试所有 Node
	if only_groups.size() > 0:
		var matched := false
		for g in only_groups:
			if n.is_in_group(g):
				matched = true
				break
		if not matched and not (n is Card):
			return

	# 延迟一帧执行，避免节点未初始化
	call_deferred("_try_apply_deferred", n)

func _try_apply_deferred(n: Node) -> void:
	if not is_instance_valid(n): return
	if not apply_to(n) and debug_log:
		for c in n.get_children():
			if apply_to(c):
				break

# ========= 解析与贴数据 =========
func _resolve_row_for_node(card_node: Node) -> Dictionary:
	if card_node.has_method("get_card_key"):
		var key1: String = str(card_node.call("get_card_key")).strip_edges().to_lower()
		if _by_name.has(key1): return _by_name[key1]
	if card_node.has_method("get_card_name"):
		var key2: String = str(card_node.call("get_card_name")).strip_edges().to_lower()
		if _by_name.has(key2): return _by_name[key2]
	if card_node.has_meta("CARD_NAME"):
		var keym: String = str(card_node.get_meta("CARD_NAME")).strip_edges().to_lower()
		if _by_name.has(keym): return _by_name[keym]
	if card_node.has_meta("card_row"):
		var r: Variant = card_node.get_meta("card_row")
		if typeof(r) == TYPE_DICTIONARY and not (r as Dictionary).is_empty():
			return r as Dictionary
	var sp: String = (card_node as Node).scene_file_path
	if sp != "":
		var keyp: String = _norm_path(sp)
		if _by_scene.has(keyp): return _by_scene[keyp]
	var guess: String = str(card_node.name).strip_edges().to_lower()
	if _by_name.has(guess): return _by_name[guess]
	return Dictionary()

func _apply_row_to_card(card_node: Node, row: Dictionary) -> void:
	card_node.set_meta("card_data", row.duplicate(true))
	if row.is_empty(): return

	if card_node.has_method("set_card_data"):
		card_node.call("set_card_data", row.duplicate(true))
	else:
		_try_call(card_node, "set_id", row.get("ID", null))
		_try_call(card_node, "set_card_name", row.get("CARD_NAME", null))
		_try_call(card_node, "set_card_type", row.get("CARD_TYPE", null))
		_try_call(card_node, "set_element", row.get("ELEMENT", null))
		_try_call(card_node, "set_rarity", row.get("RARITY", null))
		_try_call(card_node, "set_earth", row.get("EARTH", null))
		_try_call(card_node, "set_water", row.get("WATER", null))
		_try_call(card_node, "set_fire", row.get("FIRE", null))
		_try_call(card_node, "set_air", row.get("AIR", null))
		card_node.set_meta("card_row", row.duplicate(true))

	# ✅ 关键：写入 VALUE（SellingArea 要读）
	if row.has("VALUE"):
		card_node.set("VALUE", int(row["VALUE"]))

	var raw_name := str(row.get("CARD_NAME", ""))
	if raw_name != "":
		_apply_name_label(card_node, raw_name)

	if icon_json_key != "" and row.has(icon_json_key):
		var icon_path := str(row.get(icon_json_key, ""))
		if icon_path != "":
			_apply_icon(card_node, icon_path)

	if debug_log:
		print("[CardFactory] applied ->", raw_name, "VALUE=", row.get("VALUE", 0))

# ========= Label / Icon 生成 =========
func _apply_name_label(card_node: Node, text: String) -> void:
	var label := _get_or_create_path(card_node, card_name_label_path, "Label") as Label
	if label == null:
		return

	# 文本与基础样式
	var show_text := text if not name_text_uppercase else text.to_upper()
	label.text = show_text
	label.visible = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", name_font_size)

	# 首次创建放到卡面上方（相对坐标）
	if label.get_meta("fresh_created", false):
		if card_node is Node2D:
			label.position = name_position
		else:
			label.position = Vector2.ZERO

	# —— 关键：跟随卡牌的相对层级（绑定在卡牌之下/之上）——
	# 使用相对 Z，这样卡牌整体的 z_index 变化（比如拖拽时提到顶层）会自动带上 Label。
	label.z_as_relative = true
	# 让名字仅比卡面同级元素略高，避免压住其他卡牌：
	# 一般你的 Sprite2D 在同一父节点下 z_index=0，给 Label 设 1 即可。
	label.z_index = 1

	# 防止 Control 脱离父节点画布（确保不是顶层 UI）
	label.top_level = false

	# —— 不再使用绝对超大 Z 值（删除旧逻辑）——
	#（删除）var z_cap: int = RenderingServer.CANVAS_ITEM_Z_MAX
	#（删除）var z_min: int = RenderingServer.CANVAS_ITEM_Z_MIN
	#（删除）label.z_index = clampi(3000, z_min + 1, z_cap - 1)


func _apply_icon(card_node: Node, texture_path: String) -> void:
	var tex := load(texture_path)
	if tex == null:
		if debug_log: push_warning("[CardFactory] icon load fail:" + texture_path)
		return
	var node := _get_or_create_path(card_node, icon_node_path, "Sprite2D")
	if node is Sprite2D:
		(node as Sprite2D).texture = tex
	elif node is TextureRect:
		(node as TextureRect).texture = tex

# ========= 小工具 =========
func _get_or_create_path(root: Node, rel_path: String, leaf_type: String) -> Node:
	if root == null or rel_path == "":
		return null
	var existing := root.get_node_or_null(rel_path)
	if existing:
		return existing
	var parts := rel_path.split("/", false)
	var cur: Node = root
	for i in range(parts.size()):
		var name := parts[i]
		var nxt := cur.get_node_or_null(name)
		if nxt == null:
			var is_leaf := (i == parts.size() - 1)
			var nn: Node
			if is_leaf:
				match leaf_type:
					"Label": nn = Label.new()
					"Sprite2D": nn = Sprite2D.new()
					"TextureRect": nn = TextureRect.new()
					_: nn = Node2D.new() if cur is Node2D else Control.new()
				nn.set_meta("fresh_created", true)
			else:
				nn = Node2D.new() if cur is Node2D else Control.new()
			nn.name = name
			cur.add_child(nn)
			nxt = nn
		cur = nxt
	return cur

func _try_call(obj: Object, method: StringName, arg) -> void:
	if obj.has_method(method):
		obj.call(method, arg)
