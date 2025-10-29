# CardFactory.gd —— 全局卡牌配置器（挂在 Main 或注册为 Autoload 皆可）
# 作用：自动/手动把 registry / blueprint 的信息贴到任何新生成的卡牌实例上
# 字段遵循：ID, CARD_NAME, CARD_TYPE, ELEMENT, RARITY, EARTH, WATER, FIRE, AIR, SCENE_PATH

extends Node
class_name CardFactory

# ========= 可在 Inspector 设置 =========
@export_file("*.json") var registry_json_path: String = "res://GAME/data/cards/card_registry.json"
@export_file("*.json") var blueprints_json_path: String = "res://GAME/data/cards/card_blueprints.json"

# 自动监听：节点加入场景树就尝试应用
@export var auto_apply_on_node_added: bool = true
# 仅在这些组里的节点才尝试（留空=不限制）
@export var only_groups: PackedStringArray = ["card", "cards"]

# 名字显示：在卡实例内的相对路径（不存在会自动创建）
@export var card_name_label_path: String = "NameLabel"
@export var name_text_uppercase: bool = true
@export var name_font_size: int = 14
@export var name_position: Vector2 = Vector2(0, -42)

# 图标（可选）：在卡实例内的相对路径；JSON 中图标字段名（没有可留空）
@export var icon_node_path: String = "Icon"      # Sprite2D / TextureRect；不存在会自动创建 Sprite2D
@export var icon_json_key: String = "ICON_PATH"  # 若蓝图里没有就留空

@export var debug_log: bool = false

# ========= 运行期数据 =========
var _by_name: Dictionary = {}      # key: lower(CARD_NAME) -> row(dict)
var _by_scene: Dictionary = {}     # key: normalized(SCENE_PATH) -> row(dict)
var _loaded_ok: bool = false

# ========= 生命周期 =========
func _ready() -> void:
	_reload_data()

	if auto_apply_on_node_added:
		get_tree().node_added.connect(_on_tree_node_added)

	if debug_log:
		print("[CardFactory] ready. loaded=", _loaded_ok, 
			" names=", _by_name.size(), " scenes=", _by_scene.size())

# ========= 公共 API =========

# 手动重载两份 JSON（你改了表想热加载时可调用）
func reload_data() -> void:
	_reload_data()

# 自动/手动：对某个卡实例应用（优先使用已有 metadata 或可推断信息）
func apply_to(card_node: Node) -> bool:
	if card_node == null:
		return false
	var row: Dictionary = _resolve_row_for_node(card_node)
	if row.is_empty():
		if debug_log:
			print("[CardFactory] no row matched for: ", card_node.name)
		return false
	_apply_row_to_card(card_node, row)
	return true


# 手动：通过名字查找并应用（名字不区分大小写）
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

	var reg := _load_json_array(registry_json_path)   # 可为空
	var bp  := _load_json_array(blueprints_json_path) # 主来源（字段更全）

	# 先用蓝图建索引（字段更完整）
	for row in bp:
		if typeof(row) == TYPE_DICTIONARY:
			_index_row(row)

	# 再用 registry 补充缺字段（或新增）
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
		var arr: Array = parsed as Array
		for v in arr:
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

# registry 行可能字段少，用它来“补齐”已有 name/scene 的行；若不存在则新增
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
		# 通过 scene 建一条
		_by_scene[_norm_path(scene)] = r.duplicate(true)
		if name != "":
			_by_name[key] = r.duplicate(true)
	elif name != "":
		_by_name[key] = r.duplicate(true)

func _norm_path(p: String) -> String:
	# 统一斜杠；注意资源路径大小写敏感，这里不做强制小写
	return p.replace("\\", "/")

# ========= 内部：自动匹配与应用 =========
func _on_tree_node_added(n: Node) -> void:
	if n == self: return
	if not is_instance_valid(n): return
	if not _loaded_ok: return

	# 可选：只处理特定组
	if only_groups.size() > 0:
		var matched_group := false
		for g in only_groups:
			if n.is_in_group(g):
				matched_group = true
				break
		if not matched_group:
			return

	# 尽量等节点初始化完再处理
	call_deferred("_try_apply_deferred", n)

func _try_apply_deferred(n: Node) -> void:
	if not is_instance_valid(n): return
	if not apply_to(n) and debug_log:
		# 如果根节点没匹配到，试试看它的子节点里是否有“卡根”
		for c in n.get_children():
			if apply_to(c):
				break

func _resolve_row_for_node(card_node: Node) -> Dictionary:
	# 1) 若节点自身提供 key：get_card_key() / get_card_name()
	if card_node.has_method("get_card_key"):
		var key1: String = str(card_node.call("get_card_key")).strip_edges().to_lower()
		if _by_name.has(key1):
			return _by_name[key1]
	if card_node.has_method("get_card_name"):
		var key2: String = str(card_node.call("get_card_name")).strip_edges().to_lower()
		if _by_name.has(key2):
			return _by_name[key2]

	# 2) metadata / 自带字段
	if card_node.has_meta("CARD_NAME"):
		var keym: String = str(card_node.get_meta("CARD_NAME")).strip_edges().to_lower()
		if _by_name.has(keym):
			return _by_name[keym]
	if card_node.has_meta("card_row"):
		var r: Variant = card_node.get_meta("card_row")
		if typeof(r) == TYPE_DICTIONARY and not (r as Dictionary).is_empty():
			return r as Dictionary

	# 3) 通过场景路径匹配（Godot 4 所有 Node 都有 scene_file_path）
	var sp: String = (card_node as Node).scene_file_path
	if sp != "":
		var keyp: String = _norm_path(sp)
		if _by_scene.has(keyp):
			return _by_scene[keyp]

	# 4) 通过节点名试一试（不推荐，但有时好用）
	var guess: String = str(card_node.name).strip_edges().to_lower()
	if _by_name.has(guess):
		return _by_name[guess]

	return Dictionary()

# ========= 内部：真正把一行数据贴到卡实例 =========
func _apply_row_to_card(card_node: Node, row: Dictionary) -> void:
	if row.is_empty(): return

	# 优先一次性注入
	if card_node.has_method("set_card_data"):
		card_node.call("set_card_data", row.duplicate(true))
	else:
		# 逐项：保持你的命名
		_try_call(card_node, "set_id",            row.get("ID", null))
		_try_call(card_node, "set_card_name",     row.get("CARD_NAME", null))
		_try_call(card_node, "set_card_type",     row.get("CARD_TYPE", null))
		_try_call(card_node, "set_element",       row.get("ELEMENT", null))
		_try_call(card_node, "set_rarity",        row.get("RARITY", null))
		_try_call(card_node, "set_earth",         row.get("EARTH", null))
		_try_call(card_node, "set_water",         row.get("WATER", null))
		_try_call(card_node, "set_fire",          row.get("FIRE", null))
		_try_call(card_node, "set_air",           row.get("AIR", null))
		card_node.set_meta("card_row", row.duplicate(true))

	# 名字到 Label（存在则用；没有则自动创建）
	var raw_name := str(row.get("CARD_NAME",""))
	if raw_name != "":
		_apply_name_label(card_node, raw_name)

	# 图标（可选）
	if icon_json_key != "" and row.has(icon_json_key):
		var icon_path := str(row.get(icon_json_key, ""))
		if icon_path != "":
			_apply_icon(card_node, icon_path)

	if debug_log:
		print("[CardFactory] applied -> ", raw_name, "  node=", card_node.name)

func _apply_name_label(card_node: Node, text: String) -> void:
	var label := _get_or_create_path(card_node, card_name_label_path, "Label") as Label
	if label == null: return

	var show_text := text if not name_text_uppercase else text.to_upper()
	label.text = show_text
	label.visible = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", name_font_size)

	# 仅当是新建的 Label 才应用默认位置；避免覆盖你在场景里手摆的位置
	if label.get_meta("fresh_created", false):
		if card_node is Node2D:
			label.position = name_position
		else:
			label.position = Vector2.ZERO

	# 放到最上层，避免被卡面遮住
	# 改成安全写法（夹在可用范围内）
	label.z_as_relative = false
	var z_cap: int = RenderingServer.CANVAS_ITEM_Z_MAX    # 上限
	var z_min: int = RenderingServer.CANVAS_ITEM_Z_MIN    # 下限
	var desired_z: int = 3000                              # 你想要的“很靠前”的层级
	label.z_index = clampi(desired_z, z_min + 1, z_cap - 1)

func _apply_icon(card_node: Node, texture_path: String) -> void:
	var tex := load(texture_path)
	if tex == null:
		if debug_log: push_warning("[CardFactory] icon load fail: " + texture_path)
		return

	var node := _get_or_create_path(card_node, icon_node_path, "Sprite2D")
	if node is Sprite2D:
		(node as Sprite2D).texture = tex
	elif node is TextureRect:
		(node as TextureRect).texture = tex
	else:
		# 不识别的类型就替换为 Sprite2D
		var spr := Sprite2D.new()
		spr.name = icon_node_path.get_file() if icon_node_path.find("/") != -1 else icon_node_path
		spr.texture = tex
		card_node.add_child(spr)

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
					"Label":
						nn = Label.new()
					"Sprite2D":
						nn = Sprite2D.new()
					"TextureRect":
						nn = TextureRect.new()
					_:
						nn = Node2D.new() if cur is Node2D else Control.new()
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
