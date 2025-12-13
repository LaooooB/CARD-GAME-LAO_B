extends Node


# ========= 可在 Inspector 设置 =========
@export_file("*.json") var registry_json_path: String = "res://GAME/data/cards/card_registry.json"
@export_file("*.json") var blueprints_json_path: String = "res://GAME/data/cards/card_blueprints.json"

# 自动监听：节点加入场景树就尝试应用
@export var auto_apply_on_node_added: bool = true
# 仅在这些组里的节点才尝试（留空=不限制）
@export var only_groups: Array[String] = []

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
var _by_name: Dictionary = {}   # key: name.to_lower() -> Dictionary(row)
var _by_scene: Dictionary = {}  # key: scene_path_norm -> Dictionary(row)
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
func reload_data() -> void:
	_reload_data()


func apply_to(card_node: Node) -> bool:
	if card_node == null:
		return false
	var row: Dictionary = _resolve_row_for_node(card_node)
	if row.is_empty():
		if debug_log:
			print("[CardFactory] apply_to: no row matched for:", card_node.name)
		return false
	_apply_row_to_card(card_node, row)
	return true


func apply_by_name(card_node: Node, card_name: String) -> bool:
	# 为指定名字的卡牌贴数据；即使 JSON 中找不到完整行，也至少保证名字正确显示
	if card_node == null or card_name == "":
		return false

	var key := card_name.strip_edges().to_lower()
	var row: Dictionary = {}

	# ==== 1）按小写完整匹配 ====
	if _by_name.has(key):
		row = (_by_name[key] as Dictionary).duplicate(true)
	else:
		# ==== 2）忽略空格 / 下划线做一次宽松匹配 ====
		var compact := key.replace(" ", "").replace("_", "")
		for k in _by_name.keys():
			var ks: String = str(k)
			if ks == key:
				row = (_by_name[ks] as Dictionary).duplicate(true)
				break
			var ks_compact := ks.replace(" ", "").replace("_", "")
			if ks_compact == compact:
				row = (_by_name[ks] as Dictionary).duplicate(true)
				break

	# ==== 3）兜底：构造最小 row，至少保证 CARD_NAME 有值 ====
	if row.is_empty():
		row["CARD_NAME"] = card_name.strip_edges()
	elif (not row.has("CARD_NAME")) or str(row["CARD_NAME"]).strip_edges() == "":
		row["CARD_NAME"] = card_name.strip_edges()

	# 回写缓存，保证之后通过名字再查也能拿到补全后的行
	_by_name[key] = row.duplicate(true)

	_apply_row_to_card(card_node, row)
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
			_index_row(row as Dictionary)

	for row2 in reg:
		if typeof(row2) == TYPE_DICTIONARY:
			_merge_or_index_registry_row(row2 as Dictionary)

	_loaded_ok = (not _by_name.is_empty()) or (not _by_scene.is_empty())

	if debug_log:
		print("[CardFactory] reload_data done. _by_name:", _by_name.size(), " _by_scene:", _by_scene.size())


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

	# 1）顶层就是数组：直接读取
	if typeof(parsed) == TYPE_ARRAY:
		for v in (parsed as Array):
			if typeof(v) == TYPE_DICTIONARY:
				out.append(v as Dictionary)

	# 2）顶层是字典：优先找 "cards" 数组，否则把每个 Dictionary value 当作一行
	elif typeof(parsed) == TYPE_DICTIONARY:
		var d: Dictionary = parsed
		if d.has("cards") and typeof(d["cards"]) == TYPE_ARRAY:
			for v2 in (d["cards"] as Array):
				if typeof(v2) == TYPE_DICTIONARY:
					out.append(v2 as Dictionary)
		else:
			for k in d.keys():
				var v3 = d[k]
				if typeof(v3) == TYPE_DICTIONARY:
					out.append(v3 as Dictionary)
		if debug_log:
			print("[CardFactory] parsed dict json:", path, "rows=", out.size())

	else:
		if debug_log:
			print("[CardFactory] parse unsupported json type at:", path)

	return out


func _index_row(row: Dictionary) -> void:
	var name := str(row.get("CARD_NAME", "")).strip_edges()
	var scene := str(row.get("SCENE_PATH","")).strip_edges()

	var key_name: String = name.to_lower() if name != "" else ""
	var key_scene: String = _norm_path(scene) if scene != "" else ""

	if key_name != "":
		_by_name[key_name] = row.duplicate(true)
	if key_scene != "":
		_by_scene[key_scene] = row.duplicate(true)


func _merge_or_index_registry_row(r: Dictionary) -> void:
	var name := str(r.get("CARD_NAME","")).strip_edges()
	var scene := str(r.get("SCENE_PATH","")).strip_edges()
	var key := name.to_lower() if name != "" else ""
	var norm_scene := _norm_path(scene) if scene != "" else ""

	# 1）有名字且 blueprints 里已经有这一张：以 blueprints 为底，再用 registry 补空字段
	if key != "" and _by_name.has(key):
		var merged: Dictionary = (_by_name[key] as Dictionary).duplicate(true)
		for k in r.keys():
			if not merged.has(k) or str(merged[k]).strip_edges() == "":
				merged[k] = r[k]
		_by_name[key] = merged
		if norm_scene != "":
			_by_scene[norm_scene] = merged
		return

	# 2）只有名字，从 registry 新建
	if key != "" and not _by_name.has(key):
		var copy: Dictionary = r.duplicate(true)
		_by_name[key] = copy
		if norm_scene != "":
			_by_scene[norm_scene] = copy
		return

	# 3）只有场景（CARD_NAME 为空），尝试补充现有的 _by_scene，不覆盖已有字段
	if key == "" and norm_scene != "":
		if _by_scene.has(norm_scene):
			var merged2: Dictionary = (_by_scene[norm_scene] as Dictionary).duplicate(true)
			for k2 in r.keys():
				if not merged2.has(k2) or str(merged2[k2]).strip_edges() == "":
					merged2[k2] = r[k2]
			_by_scene[norm_scene] = merged2
		else:
			_by_scene[norm_scene] = r.duplicate(true)


func _norm_path(p: String) -> String:
	return p.replace("\\", "/")


# ========= 自动匹配与应用 =========
func _on_tree_node_added(n: Node) -> void:
	if n == self:
		return
	if not is_instance_valid(n):
		return
	if not _loaded_ok:
		return

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
	if not is_instance_valid(n):
		return
	if not apply_to(n) and debug_log:
		for c in n.get_children():
			if apply_to(c):
				break


# ========= 解析与贴数据 =========
func _resolve_row_for_node(card_node: Node) -> Dictionary:
	# 1）优先使用 RecipeManager 预先写在 meta 里的 card_row
	if card_node.has_meta("card_row"):
		var r_meta: Variant = card_node.get_meta("card_row")
		if typeof(r_meta) == TYPE_DICTIONARY:
			var d: Dictionary = (r_meta as Dictionary).duplicate(true)
			if not d.is_empty():
				# 补齐 CARD_NAME
				if not d.has("CARD_NAME") or str(d["CARD_NAME"]).strip_edges() == "":
					var inferred := ""
					if card_node.has_meta("CARD_NAME"):
						inferred = str(card_node.get_meta("CARD_NAME")).strip_edges()
					elif card_node.has_method("get_card_name"):
						inferred = str(card_node.call("get_card_name")).strip_edges()
					elif str(card_node.name) != "":
						inferred = str(card_node.name)
					if inferred != "":
						d["CARD_NAME"] = inferred
				return d

	# 2）脚本接口优先：get_card_key / get_card_name
	if card_node.has_method("get_card_key"):
		var key1: String = str(card_node.call("get_card_key")).strip_edges().to_lower()
		if _by_name.has(key1):
			return (_by_name[key1] as Dictionary).duplicate(true)

	if card_node.has_method("get_card_name"):
		var key2: String = str(card_node.call("get_card_name")).strip_edges().to_lower()
		if _by_name.has(key2):
			return (_by_name[key2] as Dictionary).duplicate(true)

	# 3）meta: CARD_NAME → 名字索引
	if card_node.has_meta("CARD_NAME"):
		var keym: String = str(card_node.get_meta("CARD_NAME")).strip_edges().to_lower()
		if _by_name.has(keym):
			return (_by_name[keym] as Dictionary).duplicate(true)

	# 4）scene_file_path → 场景索引
	var sp: String = card_node.scene_file_path
	if sp != "":
		var keyp: String = _norm_path(sp)
		if _by_scene.has(keyp):
			return (_by_scene[keyp] as Dictionary).duplicate(true)

	# 5）最后尝试用节点名猜
	var guess: String = str(card_node.name).strip_edges().to_lower()
	if _by_name.has(guess):
		return (_by_name[guess] as Dictionary).duplicate(true)

	return Dictionary()


func _apply_row_to_card(card_node: Node, row: Dictionary) -> void:
	var row_copy: Dictionary = row.duplicate(true)

	# 基础 meta
	card_node.set_meta("card_data", row_copy)
	card_node.set_meta("card_row", row_copy)

	if row_copy.is_empty():
		return

	var raw_name := str(row_copy.get("CARD_NAME", ""))
	if raw_name != "":
		card_node.set_meta("CARD_NAME", raw_name)

	if card_node.has_method("set_card_data"):
		card_node.call("set_card_data", row_copy.duplicate(true))
	else:
		_try_call(card_node, "set_id", row_copy.get("ID", null))
		_try_call(card_node, "set_card_name", row_copy.get("CARD_NAME", null))
		_try_call(card_node, "set_card_type", row_copy.get("CARD_TYPE", null))
		_try_call(card_node, "set_element", row_copy.get("ELEMENT", null))
		_try_call(card_node, "set_rarity", row_copy.get("RARITY", null))
		_try_call(card_node, "set_earth", row_copy.get("EARTH", null))
		_try_call(card_node, "set_water", row_copy.get("WATER", null))
		_try_call(card_node, "set_fire", row_copy.get("FIRE", null))
		_try_call(card_node, "set_air", row_copy.get("AIR", null))
		card_node.set_meta("card_row", row_copy.duplicate(true))

	# VALUE（SellingArea 用）
	if row_copy.has("VALUE"):
		card_node.set("VALUE", int(row_copy["VALUE"]))

	# 名字 Label
	if raw_name != "":
		_apply_name_label(card_node, raw_name)

	# ICON
	if icon_json_key != "" and row_copy.has(icon_json_key):
		var icon_path := str(row_copy.get(icon_json_key, ""))
		if icon_path != "":
			_apply_icon(card_node, icon_path)

	if debug_log:
		print("[CardFactory] applied ->", raw_name, "VALUE=", row_copy.get("VALUE", 0))


# ========= Label / Icon 生成 =========
func _apply_name_label(card_node: Node, text: String) -> void:
	var label := _get_or_create_path(card_node, card_name_label_path, "Label") as Label
	if label == null:
		return

	var show_text := text if not name_text_uppercase else text.to_upper()
	label.text = show_text
	label.visible = true
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", name_font_size)

	if label.get_meta("fresh_created", false):
		if card_node is Node2D:
			label.position = name_position
		else:
			label.position = Vector2.ZERO

	label.z_as_relative = true
	label.z_index = 1
	label.top_level = false


func _apply_icon(card_node: Node, texture_path: String) -> void:
	var tex := load(texture_path)
	if tex == null:
		if debug_log:
			push_warning("[CardFactory] icon load fail:" + texture_path)
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
