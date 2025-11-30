extends Control
class_name work_unit_job

# 弹出位置的小偏移（还是你原来的）
@export var margin: Vector2 = Vector2(8, 8)

# ====== 新增：卡牌 snap 槽配置 ======
# 槽根节点（下面挂 Slot1 / Slot2 这些 Node2D）
@export var job_slot_root_path: NodePath
# 卡松手时，距离槽多少像素内就会被吸进去
@export_range(0.0, 512.0, 1.0) var job_slot_snap_radius: float = 48.0

# ====== 运行期状态 ======
var _job_slot_root: Node2D = null
var _job_slot_occupants: Dictionary = {}	# key: Node2D 槽, value: Node2D 卡牌


func _ready() -> void:
	# 找槽根节点
	_job_slot_root = get_node_or_null(job_slot_root_path) as Node2D
	if _job_slot_root == null:
		_job_slot_root = find_child("JobSlotRoot", true, false) as Node2D


# ====== 原来的弹出接口，保持不变 ======

func show_at(global_pos: Vector2) -> void:
	# global_pos 是 WorkUnit 计算出来的世界坐标锚点
	global_position = global_pos + Vector2(0.0, -size.y) - margin
	visible = true

func toggle_at(global_pos: Vector2) -> void:
	if visible:
		visible = false
	else:
		show_at(global_pos)


# ====== 槽工具：拿到所有槽位 Node2D ======
func _get_job_slots() -> Array[Node2D]:
	var slots: Array[Node2D] = []
	if _job_slot_root == null:
		return slots

	for child in _job_slot_root.get_children():
		if child is Node2D:
			var slot_node: Node2D = child as Node2D
			if slot_node != null:
				slots.append(slot_node)

	return slots


# ====== 供 JobSlotManager 调用：尝试把卡吸附到本弹窗的某个槽 ======
func _try_snap_card(card: Node2D, drop_global: Vector2) -> bool:
	if card == null or not is_instance_valid(card):
		return false
	# 只有弹窗当前可见才接卡
	if not visible:
		return false

	var slots: Array[Node2D] = _get_job_slots()
	if slots.is_empty():
		return false

	var radius: float = job_slot_snap_radius
	var radius_sq: float = radius * radius

	for slot: Node2D in slots:
		# 如果这个槽已经有卡，就跳过
		var existing: Node2D = _job_slot_occupants.get(slot, null) as Node2D
		if existing != null and is_instance_valid(existing):
			continue

		var slot_pos: Vector2 = slot.global_position
		if drop_global.distance_squared_to(slot_pos) > radius_sq:
			continue

		# ===== 真正接卡的逻辑 =====
		# 把卡 reparent 到槽根节点（也就是弹窗内部），这样弹窗移动/隐藏时卡跟着一起
		if _job_slot_root != null and card.get_parent() != _job_slot_root:
			var gp: Vector2 = card.global_position
			card.reparent(_job_slot_root)
			card.global_position = gp

		# 吸附到槽中心
		card.global_position = slot_pos

		# 记录“这个槽被这张卡占用”
		_job_slot_occupants[slot] = card

		return true

	return false


# ====== 供 JobSlotManager 调用：卡开始拖拽时，清理槽的占用 ======
func _on_card_begin_drag(card: Node2D) -> void:
	if card == null or not is_instance_valid(card):
		return
	if _job_slot_occupants.is_empty():
		return

	for slot in _job_slot_occupants.keys():
		var card_in_slot: Node2D = _job_slot_occupants[slot] as Node2D
		if card_in_slot == card:
			_job_slot_occupants.erase(slot)
			return
