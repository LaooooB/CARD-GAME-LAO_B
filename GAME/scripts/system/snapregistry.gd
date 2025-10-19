extends Node
class_name SnapRegistry

@export var page_main_root: NodePath
@export var page_shop_root: NodePath
@export var page_storage_root: NodePath
@export var page_secret_root: NodePath

const BG_CANDIDATE_NAMES := ["Background","MainMap","ShopMap","StorageMap","SecretMap","Map","bg","BG"]

class PageInfo:
	var root: Node = null
	var bg: Sprite2D = null
	var mgr: Node = null

var _pages: Array[PageInfo] = []

func _ready() -> void:
	_pages.clear()
	var roots: Array[Node] = []
	var rp: Array[NodePath] = [page_main_root, page_shop_root, page_storage_root, page_secret_root]
	for p in rp:
		if p != NodePath():
			var n: Node = get_node_or_null(p)
			if n != null:
				roots.append(n)
	if roots.is_empty():
		var q: Array[Node] = [get_tree().get_root()]
		while q.size() > 0:
			var cur: Node = q.pop_back()
			for ch in cur.get_children():
				q.append(ch)
				var nm := ch.name.to_lower()
				if nm.find("pageroot") != -1 or nm == "pageroot" or ch.is_in_group("page_root") \
				or (ch.has_meta("is_page_root") and bool(ch.get_meta("is_page_root")) == true):
					roots.append(ch)
	var used := {}
	for r in roots:
		if r == null or used.has(r): continue
		used[r] = true
		var info := PageInfo.new()
		info.root = r
		info.bg = _find_background_under(r)
		info.mgr = _find_manager_under(r)
		if info.bg != null and info.mgr != null:
			_pages.append(info)

# ========== 供 Book 调用的 API（名字与 Manager 对齐） ==========

func pick_card_at(world_pos: Vector2) -> Node2D:
	var mgr := _pick_manager_by_point(world_pos)
	if mgr != null and mgr.has_method("pick_card_at"):
		return mgr.pick_card_at(world_pos)
	return null

func prepare_drag_group(card: Node2D, world_pos: Vector2) -> void:
	var mgr := _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("prepare_drag_group"):
		mgr.prepare_drag_group(card, world_pos)

func begin_group_drag(card: Node2D) -> void:
	var mgr := _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("begin_group_drag"):
		mgr.begin_group_drag(card)

func can_drag(card: Node2D) -> bool:
	var mgr := _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("can_drag"):
		return mgr.can_drag(card)
	return true

func is_group_active_for(card: Node2D) -> bool:
	var mgr := _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("is_group_active_for"):
		return mgr.is_group_active_for(card)
	return false

func try_snap(card: Node2D, original_pos: Vector2) -> bool:
	var drop_point: Vector2 = card.global_position
	var mgr := _pick_manager_by_point(drop_point)
	if mgr != null and mgr.has_method("try_snap"):
		return mgr.try_snap(card, original_pos)
	return false

# ========== 选择 page / manager 的策略 ==========

func _pick_manager_for_card(card: Node2D) -> Node:
	var pr := _find_page_root_up(card)
	if pr != null:
		for info in _pages:
			if info.root == pr:
				return info.mgr
	return _pick_manager_by_point(card.global_position)

func _pick_manager_by_point(world_pos: Vector2) -> Node:
	for info in _pages:
		if info.bg == null or info.mgr == null: continue
		var rect: Rect2 = _background_rect(info.bg)
		if rect.has_point(world_pos):
			return info.mgr
	return null

# ========== 查找/几何工具 ==========

func _find_page_root_up(n: Node) -> Node:
	var cur: Node = n
	while cur != null:
		if cur.is_in_group("page_root"):
			return cur
		if cur.has_meta("is_page_root") and bool(cur.get_meta("is_page_root")) == true:
			return cur
		cur = cur.get_parent()
	return null

func _find_background_under(root: Node) -> Sprite2D:
	for nm in BG_CANDIDATE_NAMES:
		var nd: Node = root.find_child(nm, true, false)
		if nd is Sprite2D:
			return nd as Sprite2D
	var q: Array[Node] = [root]
	while q.size() > 0:
		var cur: Node = q.pop_back()
		for ch in cur.get_children():
			q.append(ch)
			if ch is Sprite2D:
				return ch as Sprite2D
	return null

func _find_manager_under(root: Node) -> Node:
	var nd: Node = root.find_child("GridSnapManager", true, false)
	if nd != null:
		return nd
	var q: Array[Node] = [root]
	while q.size() > 0:
		var cur: Node = q.pop_back()
		for ch in cur.get_children():
			q.append(ch)
			if ch != null and ch.has_method("can_drag") and ch.has_method("try_snap"):
				return ch
	return null

func _background_rect(bg: Sprite2D) -> Rect2:
	if bg == null or bg.texture == null:
		return Rect2()
	var tex_size: Vector2 = bg.texture.get_size()
	var scl: Vector2 = bg.scale.abs()
	var size: Vector2 = tex_size * scl
	var top_left: Vector2 = bg.global_position
	if bg.centered:
		top_left -= size * 0.5
	top_left -= bg.offset * scl
	return Rect2(top_left, size)
