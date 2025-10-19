extends Node
class_name GridSnapRouter

# 可选：如果你愿意，可以在 Inspector 里显式绑定四个 PageRoot；不填也会自动扫描。
@export var page_main_root: NodePath
@export var page_shop_root: NodePath
@export var page_storage_root: NodePath
@export var page_secret_root: NodePath

const BG_CANDIDATE_NAMES: Array[String] = [
	"Background","MainMap","ShopMap","StorageMap","SecretMap","Map","bg","BG"
]

# —— 页面信息 —— #
class PageInfo:
	var root: Node = null
	var bg: Sprite2D = null
	var mgr: Node = null

var _pages: Array[PageInfo] = []

func _ready() -> void:
	# 让旧 Book.gd 能找到我：
	if not is_in_group("snap_manager"):
		add_to_group("snap_manager")
	# 收集四个页面
	_pages = _collect_pages()
	if _pages.is_empty():
		push_warning("[GridSnapRouter] 没找到任何页面（PageRoot/Background/Manager）。请确认结构或 Inspector 绑定 page_*_root。")

# =========================================================
# 旧 Book.gd 会调用的同名方法：保持签名一致，内部做“按落点路由”
# =========================================================

func pick_card_at(world_pos: Vector2) -> Node2D:
	var mgr: Node = _pick_manager_by_point(world_pos)
	if mgr != null and mgr.has_method("pick_card_at"):
		return mgr.pick_card_at(world_pos)
	return null

func prepare_drag_group(card: Node2D, world_pos: Vector2) -> void:
	var mgr: Node = _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("prepare_drag_group"):
		mgr.prepare_drag_group(card, world_pos)

func begin_group_drag(card: Node2D) -> void:
	var mgr: Node = _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("begin_group_drag"):
		mgr.begin_group_drag(card)

func can_drag(card: Node2D) -> bool:
	var mgr: Node = _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("can_drag"):
		return mgr.can_drag(card)
	return true

func is_group_active_for(card: Node2D) -> bool:
	var mgr: Node = _pick_manager_for_card(card)
	if mgr != null and mgr.has_method("is_group_active_for"):
		return mgr.is_group_active_for(card)
	return false

func try_snap(card: Node2D, original_pos: Vector2) -> bool:
	# 关键：按“松手时的世界坐标”选择目标页面
	var drop_point: Vector2 = card.global_position
	var mgr: Node = _pick_manager_by_point(drop_point)
	if mgr != null and mgr.has_method("try_snap"):
		return mgr.try_snap(card, original_pos)
	return false

# =========================================================
# 选页/查找工具
# =========================================================

func _collect_pages() -> Array[PageInfo]:
	var res: Array[PageInfo] = []
	var roots: Array[Node] = []

	# 1) 显式路径优先
	var rp: Array[NodePath] = [page_main_root, page_shop_root, page_storage_root, page_secret_root]
	for p in rp:
		if p != NodePath():
			var n: Node = get_node_or_null(p)
			if n != null:
				roots.append(n)

	# 2) 自动扫描 PageRoot（名字含 pageroot，或在组 page_root，或 meta is_page_root=true）
	if roots.is_empty():
		var q: Array[Node] = [get_tree().get_root()]
		while q.size() > 0:
			var cur: Node = q.pop_back()
			var children: Array = cur.get_children()
			for i in range(children.size()):
				var ch: Node = children[i]
				q.append(ch)
				var nm: String = ch.name.to_lower()
				var is_pr: bool = nm.find("pageroot") != -1 or nm == "pageroot" \
					or ch.is_in_group("page_root") \
					or (ch.has_meta("is_page_root") and bool(ch.get_meta("is_page_root")) == true)
				if is_pr:
					roots.append(ch)

	# 去重并构建 PageInfo
	var used: Dictionary = {}
	for r in roots:
		if r == null: continue
		if used.has(r): continue
		used[r] = true

		var info := PageInfo.new()
		info.root = r
		info.bg = _find_background_under(r)
		info.mgr = _find_manager_under(r)
		if info.bg != null and info.mgr != null:
			res.append(info)

	return res

func _pick_manager_for_card(card: Node2D) -> Node:
	# 优先按“这张卡属于哪个 PageRoot”（向上爬）匹配
	var pr: Node = _find_page_root_up(card)
	if pr != null:
		for info in _pages:
			if info.root == pr:
				return info.mgr
	# 兜底：按当前位置（落点）判断
	return _pick_manager_by_point(card.global_position)

func _pick_manager_by_point(world_pos: Vector2) -> Node:
	for info in _pages:
		if info.bg == null or info.mgr == null:
			continue
		var rect: Rect2 = _background_rect(info.bg)
		if rect.has_point(world_pos):
			return info.mgr
	return null

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
	# 优先按常见名字找
	for nm in BG_CANDIDATE_NAMES:
		var nd: Node = root.find_child(nm, true, false)
		if nd is Sprite2D:
			return nd as Sprite2D
	# 否则找第一个 Sprite2D
	var q: Array[Node] = [root]
	while q.size() > 0:
		var cur: Node = q.pop_back()
		var children: Array = cur.get_children()
		for i in range(children.size()):
			var ch: Node = children[i]
			q.append(ch)
			if ch is Sprite2D:
				return ch as Sprite2D
	return null

func _find_manager_under(root: Node) -> Node:
	# 优先名字：GridSnapManager
	var nd: Node = root.find_child("GridSnapManager", true, false)
	if nd != null:
		return nd
	# 否则找“有 can_drag + try_snap”的节点
	var q: Array[Node] = [root]
	while q.size() > 0:
		var cur: Node = q.pop_back()
		var children: Array = cur.get_children()
		for i in range(children.size()):
			var ch: Node = children[i]
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
