extends Node2D
class_name SellingArea

@export var sell_area_path: NodePath

# —— 动画参数 —— 
@export var anim_enabled: bool = true
@export_range(0.05, 1.0, 0.01) var anim_duration: float = 0.18
@export var anim_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var anim_ease: Tween.EaseType = Tween.EASE_IN
@export_range(0.2, 1.0, 0.01) var end_scale: float = 0.6
@export_range(0.0, 1.0, 0.01) var end_alpha: float = 0.0
@export var move_to_center: bool = true

# —— 触发与整堆删除选项 —— 
@export var only_on_left_button: bool = true
@export var delete_entire_pile_if_grouped: bool = false

# —— CardPack 拒收设置 —— 
@export var reject_card_pack: bool = true
@export var reject_to_marker: NodePath
@export_range(0.0, 300.0, 1.0) var reject_bump_distance: float = 120.0
@export_range(0.05, 0.8, 0.01) var reject_anim_duration: float = 0.20
@export var reject_trans: Tween.TransitionType = Tween.TRANS_BACK
@export var reject_ease: Tween.EaseType = Tween.EASE_OUT

# —— 影子/额外节点同步销毁 —— 
@export var extra_kill_paths: Array[NodePath] = []

# —— 新增：删除前隔离与通知的策略 —— 
@export var reparent_before_delete: bool = true                  # 删除前把节点移到 SellingArea 下
@export var notify_grid_groups: PackedStringArray = ["grid_manager", "snap_manager"]
@export var notify_pile_groups: PackedStringArray = ["pile_manager"]
@export var notify_methods_single: PackedStringArray = [         # 尝试这些方法名（有哪个就调用哪个）
	"on_card_will_be_sold",
	"on_node_will_be_sold",
	"on_pile_will_be_sold",
	"will_remove_node",
	"will_remove_card"
]
@export var notify_methods_batch: PackedStringArray = [
	"on_nodes_sold",
	"on_cards_sold",
	"will_remove_nodes"
]

signal sold(nodes: Array)

var _sell_area: Area2D
var _overlapping_cards: Dictionary = {}   # {Node2D: true}

func _ready() -> void:
	_sell_area = get_node_or_null(sell_area_path) as Area2D
	if _sell_area == null:
		push_error("[SellingArea] sell_area_path 未设置或无效。")
		return

	_sell_area.area_entered.connect(_on_area_entered)
	_sell_area.area_exited.connect(_on_area_exited)
	_sell_area.body_entered.connect(_on_body_entered)
	_sell_area.body_exited.connect(_on_body_exited)

	_overlapping_cards.clear()

func _on_area_entered(a: Area2D) -> void:
	var card: Node2D = _guess_card_root_from_area(a)
	if card != null:
		_overlapping_cards[card] = true

func _on_area_exited(a: Area2D) -> void:
	var card: Node2D = _guess_card_root_from_area(a)
	if card != null and card in _overlapping_cards:
		_overlapping_cards.erase(card)

func _on_body_entered(b: Node) -> void:
	var card: Node2D = _guess_card_root_from_body(b)
	if card != null:
		_overlapping_cards[card] = true

func _on_body_exited(b: Node) -> void:
	var card: Node2D = _guess_card_root_from_body(b)
	if card != null and card in _overlapping_cards:
		_overlapping_cards.erase(card)

func _unhandled_input(event: InputEvent) -> void:
	if _sell_area == null or _overlapping_cards.is_empty():
		return

	var is_release: bool = event is InputEventMouseButton and not (event as InputEventMouseButton).pressed
	if not is_release:
		return
	if only_on_left_button and event is InputEventMouseButton and (event as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
		return

	var candidates: Array = []
	for k in _overlapping_cards.keys():
		if k is Node2D and is_instance_valid(k):
			candidates.append(k)

	if candidates.is_empty():
		return

	# CardPack → 回弹；其他 → 出售
	var rejects: Array = []
	var sellables: Array = []
	for n in candidates:
		var n2d: Node2D = n
		if reject_card_pack and _is_card_pack(n2d):
			rejects.append(n2d)
		else:
			sellables.append(n2d)

	for r in rejects:
		_reject_drop(r)

	if not sellables.is_empty():
		_perform_sell(sellables)

	get_viewport().set_input_as_handled()

# —— 判断：是否为 CardPack —— 
func _is_card_pack(n: Node2D) -> bool:
	if n == null:
		return false
	if n.get_class() == "CardPack":
		return true
	if n.is_in_group("card_pack"):
		return true
	var nm: String = String(n.name).to_lower()
	if nm.find("cardpack") != -1 or nm.find("pack") != -1:
		return true
	return false

# —— 回弹实现 —— 
func _reject_drop(node2d: Node2D) -> void:
	if not is_instance_valid(node2d):
		return
	if node2d.has_method("snap_back_to_grid"):
		node2d.call("snap_back_to_grid")
		return
	if node2d.has_method("bounce_back"):
		node2d.call("bounce_back")
		return
	if node2d.has_method("on_sell_rejected"):
		node2d.call("on_sell_rejected")
		return

	if node2d.has_meta("pre_drag_cell_center"):
		var v: Variant = node2d.get_meta("pre_drag_cell_center")
		if typeof(v) == TYPE_VECTOR2:
			var t1: Tween = create_tween()
			t1.set_trans(reject_trans)
			t1.set_ease(reject_ease)
			t1.tween_property(node2d, "global_position", (v as Vector2), reject_anim_duration)
			return

	if node2d.has_meta("pre_drag_global_pos"):
		var p: Variant = node2d.get_meta("pre_drag_global_pos")
		if typeof(p) == TYPE_VECTOR2:
			var t2: Tween = create_tween()
			t2.set_trans(reject_trans)
			t2.set_ease(reject_ease)
			t2.tween_property(node2d, "global_position", (p as Vector2), reject_anim_duration)
			return

	var marker: Node2D = get_node_or_null(reject_to_marker) as Node2D
	if marker != null:
		var t3: Tween = create_tween()
		t3.set_trans(reject_trans)
		t3.set_ease(reject_ease)
		t3.tween_property(node2d, "global_position", marker.global_position, reject_anim_duration)
		return

	var dir: Vector2 = (node2d.global_position - global_position)
	if dir.length() < 1.0:
		dir = Vector2(1.0, 0.0)
	dir = dir.normalized()
	var target: Vector2 = node2d.global_position + dir * reject_bump_distance
	var t4: Tween = create_tween()
	t4.set_trans(reject_trans)
	t4.set_ease(reject_ease)
	t4.tween_property(node2d, "global_position", target, reject_anim_duration)

# —— 出售实现（新增：删除前脱钩与通知）—— 
func _perform_sell(candidates: Array) -> void:
	# 统一去重
	var uniq: Array = []
	for n in candidates:
		if uniq.find(n) == -1:
			uniq.append(n)

	# 先做预清理（脱离拖拽、从 Pile/Grid 解除、通知管理器清引用）
	for n in uniq:
		if n is Node2D and is_instance_valid(n):
			_pre_sell_cleanup(n as Node2D)

	# 动画并安全释放
	var sold_nodes: Array = []
	for n2 in uniq:
		if not (n2 is Node2D) or not is_instance_valid(n2):
			continue
		var target: Node2D = n2
		if delete_entire_pile_if_grouped:
			var pile: Node2D = _find_pile_root(n2)
			if pile != null:
				target = pile
		_play_tween_and_free(target)
		if sold_nodes.find(target) == -1:
			sold_nodes.append(target)

	if not sold_nodes.is_empty():
		emit_signal("sold", sold_nodes)

	_overlapping_cards.clear()

# —— 预清理：结束拖拽、取消选中、通知 Grid/Pile、可选 reparent 隔离 —— 
func _pre_sell_cleanup(node2d: Node2D) -> void:
	# 1) 结束拖拽 / 取消交互态
	if node2d.has_method("cancel_drag"):
		node2d.call("cancel_drag")
	elif node2d.has_method("end_drag"):
		node2d.call("end_drag")
	if node2d.has_method("set_selected"):
		node2d.call("set_selected", false)
	if node2d.has_method("on_sold"):
		node2d.call("on_sold")

	# 2) 通知 Pile / Grid 管理器清引用（单个）
	_notify_managers_single(node2d)

	# 3) 可选：reparent 到 SellingArea，隔离与原父节点的依赖（避免同帧逻辑继续访问）
	if reparent_before_delete and node2d.get_parent() != self:
		var keep_global: Vector2 = node2d.global_position
		var keep_rot: float = node2d.global_rotation
		var keep_scale: Vector2 = node2d.global_scale
		var parent: Node = node2d.get_parent()
		if parent != null:
			parent.remove_child(node2d)
		add_child(node2d)
		node2d.global_position = keep_global
		node2d.global_rotation = keep_rot
		node2d.global_scale = keep_scale

# —— 通知管理器（单个对象）——
func _notify_managers_single(target: Node2D) -> void:
	var groups_all: Array = []
	groups_all.append_array(notify_grid_groups)
	groups_all.append_array(notify_pile_groups)

	for g in groups_all:
		for m in get_tree().get_nodes_in_group(g):
			for method_name in notify_methods_single:
				if m.has_method(method_name):
					m.call(method_name, target)

# —— 批量通知（目前未用到；保留以备扩展）——
func _notify_managers_batch(nodes: Array) -> void:
	var groups_all: Array = []
	groups_all.append_array(notify_grid_groups)
	groups_all.append_array(notify_pile_groups)
	for g in groups_all:
		for m in get_tree().get_nodes_in_group(g):
			for method_name in notify_methods_batch:
				if m.has_method(method_name):
					m.call(method_name, nodes)

# —— 动画 + 安全释放（统一对所有 CanvasItem 子树 + 额外节点）——
func _play_tween_and_free(target: Node2D) -> void:
	var tween: Tween = create_tween()
	tween.set_trans(anim_trans)
	tween.set_ease(anim_ease)
	tween.set_parallel(true)

	if move_to_center:
		var target_pos: Vector2 = global_position
		tween.tween_property(target, "global_position", target_pos, anim_duration)

	var scaled: Vector2 = target.scale * end_scale
	tween.tween_property(target, "scale", scaled, anim_duration)

	var canvas_items: Array = _collect_canvas_items(target)
	for ci in canvas_items:
		if ci is CanvasItem and is_instance_valid(ci):
			var c: Color = (ci as CanvasItem).modulate
			var to_c: Color = Color(c.r, c.g, c.b, end_alpha)
			tween.tween_property(ci, "modulate", to_c, anim_duration)

	var extra_nodes: Array = _resolve_extra_nodes()
	for en in extra_nodes:
		if en is Node2D and is_instance_valid(en):
			if move_to_center:
				tween.tween_property(en, "global_position", global_position, anim_duration)
			var en_scaled: Vector2 = (en as Node2D).scale * end_scale
			tween.tween_property(en, "scale", en_scaled, anim_duration)
		if en is CanvasItem and is_instance_valid(en):
			var ec: Color = (en as CanvasItem).modulate
			var eto: Color = Color(ec.r, ec.g, ec.b, end_alpha)
			tween.tween_property(en, "modulate", eto, anim_duration)

	tween.finished.connect(func () -> void:
		if is_instance_valid(target):
			# 用 deferred 规避“同帧仍被访问”
			target.call_deferred("queue_free")
		_free_extra_nodes_safe_deferred()
	)

func _collect_canvas_items(root: Node) -> Array:
	var out: Array = []
	if root is CanvasItem:
		out.append(root)
	var kids: Array = root.get_children()
	for child in kids:
		out.append_array(_collect_canvas_items(child))
	return out

func _resolve_extra_nodes() -> Array:
	var out: Array = []
	for p in extra_kill_paths:
		var node: Node = get_node_or_null(p)
		if node != null and is_instance_valid(node) and out.find(node) == -1:
			out.append(node)
	return out

func _free_extra_nodes_safe_deferred() -> void:
	for p in extra_kill_paths:
		var node: Node = get_node_or_null(p)
		if node != null and is_instance_valid(node):
			node.call_deferred("queue_free")

func _guess_card_root_from_area(a: Area2D) -> Node2D:
	if a == null:
		return null
	var p: Node = a.get_parent()
	return p as Node2D

func _guess_card_root_from_body(b: Node) -> Node2D:
	if b is Node2D:
		return b as Node2D
	if b != null:
		var parent: Node = b.get_parent()
		if parent is Node2D:
			return parent as Node2D
	return null

func _find_pile_root(n: Node) -> Node2D:
	var cur: Node = n
	while cur != null:
		if cur is Node2D and String(cur.name).to_lower().contains("pile"):
			return cur as Node2D
		cur = cur.get_parent()
	return null
