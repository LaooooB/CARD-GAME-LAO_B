extends Control
class_name work_unit_job

# =========================
# —— 弹出位置 —— 
# =========================
@export var margin: Vector2 = Vector2(8, 8)

# =========================
# —— 卡牌 snap 槽配置 —— 
# =========================
# 槽根节点（下面挂 Slot1 / Slot2 / SlotN 这些 Node2D）
@export var job_slot_root_path: NodePath
# 卡松手时，距离槽多少像素内就会被吸进去
@export_range(0.0, 512.0, 1.0) var job_slot_snap_radius: float = 64.0

# =========================
# —— snap 动画参数（磁铁感）——
# 位置 tween 的时长
@export_range(0.05, 0.6, 0.01) var job_snap_duration: float = 0.22
# 过渡类型：用 BACK 带一点“弹”感
@export var job_snap_transition: Tween.TransitionType = Tween.TRANS_BACK
@export var job_snap_ease: Tween.EaseType = Tween.EASE_OUT
# 可选：一点延迟
@export_range(0.0, 0.5, 0.01) var job_snap_delay: float = 0.0

# =========================
# —— 生产配置（多 Job 槽）——
# 要实例化的 CardPack 场景（例如：res://GAME/scenes/2D/card_packs/CardPack_Common.tscn）
@export var pack_scene: PackedScene

# 每个 job 的生产时间（秒数组，对应每一个槽；长度不足会用默认值补）
@export var job_intervals: PackedFloat32Array = PackedFloat32Array()

# 是否循环生产：true = 只要该槽里卡还在，就反复按时间间隔生产 pack
@export var loop_produce: bool = true

# 产出的 pack 相对 WorkUnit 锚点的偏移（所有 job 共用）
@export var spawn_offset: Vector2 = Vector2.ZERO

# 调试开关
@export var debug_log: bool = false

# =========================
# —— 运行期状态 —— 
# =========================
var _job_slot_root: Node2D = null
var _job_slots: Array[Node2D] = []             # 所有 job 槽 Node2D 列表
var _job_slot_occupants: Dictionary = {}       # key: Node2D 槽, value: Node2D 卡牌

var _job_timers: Array[Timer] = []             # 每个 job 一个 Timer
var _job_input_cards: Array[Node2D] = []       # 对应 job 槽当前持有的卡

# 记住 WorkUnitBase 的世界坐标锚点（通过 show_at 传进来）
var _anchor_valid: bool = false
var _anchor_position: Vector2 = Vector2.ZERO


# =========================
# —— 生命周期 —— 
# =========================
func _ready() -> void:
	add_to_group("work_unit_job")

	# 找槽根节点
	_job_slot_root = get_node_or_null(job_slot_root_path) as Node2D
	if _job_slot_root == null:
		_job_slot_root = find_child("JobSlotRoot", true, false) as Node2D

	# 收集所有 job 槽（Job1 / Job2 / JobN）
	_collect_job_slots()
	_init_job_timers()

	if debug_log:
		_log("ready: slots=%d" % _job_slots.size())


# =========================
# —— 弹出接口（保持 API 不变）——
# =========================
func show_at(global_pos: Vector2) -> void:
	# global_pos 是 WorkUnit 传进来的世界坐标锚点
	_anchor_position = global_pos
	_anchor_valid = true

	global_position = global_pos + Vector2(0.0, -size.y) - margin
	visible = true


func toggle_at(global_pos: Vector2) -> void:
	if visible:
		visible = false
	else:
		show_at(global_pos)


# =========================
# —— 槽初始化 —— 
# =========================
func _collect_job_slots() -> void:
	_job_slots.clear()
	if _job_slot_root == null:
		return

	for child in _job_slot_root.get_children():
		if child is Node2D:
			var slot_node: Node2D = child as Node2D
			if slot_node != null:
				_job_slots.append(slot_node)


func _init_job_timers() -> void:
	_job_timers.clear()
	_job_input_cards.clear()

	var slot_count: int = _job_slots.size()
	for i in range(slot_count):
		# 初始没有卡
		_job_input_cards.append(null)

		var t: Timer = Timer.new()
		t.one_shot = true
		t.autostart = false

		var interval: float = _get_job_interval(i)
		t.wait_time = interval

		add_child(t)
		var cb: Callable = Callable(self, "_on_job_timer_timeout").bind(i)
		t.timeout.connect(cb)

		_job_timers.append(t)


func _get_job_interval(job_index: int) -> float:
	# 强制要求 job_intervals 配得够长，且 > 0
	if job_index < 0 or job_index >= job_intervals.size():
		push_error("job_intervals 太短或未配置：job_index=%d" % job_index)
		return 1.0

	var v: float = job_intervals[job_index]
	if v <= 0.0:
		push_error("job_intervals[%d] 必须 > 0，目前是 %.2f" % [job_index, v])
		return 1.0

	return v



# =========================
# —— 供外部调用：尝试把卡吸附到某个 job 槽 —— 
# =========================
func _try_snap_card(card: Node2D, drop_global: Vector2) -> bool:
	if card == null or not is_instance_valid(card):
		return false
	# 只有弹窗当前可见才接卡
	if not visible:
		return false

	var slots: Array[Node2D] = _job_slots
	if slots.is_empty():
		return false

	var radius: float = job_slot_snap_radius
	var radius_sq: float = radius * radius

	for slot: Node2D in slots:
		# 每个槽最多一张牌
		var existing_v: Variant = _job_slot_occupants.get(slot, null)
		var existing: Node2D = existing_v as Node2D
		if existing != null and is_instance_valid(existing):
			continue

		var slot_pos: Vector2 = slot.global_position
		if drop_global.distance_squared_to(slot_pos) > radius_sq:
			continue

		# ===== 真正接卡逻辑 =====

		# 把卡 reparent 到弹窗内部的 JobSlotRoot，保持 global_position 不变
		if _job_slot_root != null and card.get_parent() != _job_slot_root:
			var gp: Vector2 = card.global_position
			card.reparent(_job_slot_root, true)
			card.global_position = gp

		# 磁铁式 snap tween：对 global_position 做一个 BACK + EASE_OUT
		var tw: Tween = card.create_tween()
		tw.set_trans(job_snap_transition).set_ease(job_snap_ease)
		if job_snap_delay > 0.0:
			tw.set_delay(job_snap_delay)
		tw.tween_property(card, "global_position", slot_pos, job_snap_duration)

		# 记录槽占用关系
		_job_slot_occupants[slot] = card

		# 通知这个槽对应的 job 开始计时生产
		_on_slot_occupied(slot, card)

		return true

	return false


# 卡开始拖拽时，清理槽的占用（外部调用）
func _on_card_begin_drag(card: Node2D) -> void:
	if card == null or not is_instance_valid(card):
		return
	if _job_slot_occupants.is_empty():
		return

	for slot in _job_slot_occupants.keys():
		var card_in_slot: Node2D = _job_slot_occupants[slot] as Node2D
		if card_in_slot == card:
			_job_slot_occupants.erase(slot)
			_on_slot_cleared(slot)
			return


# =========================
# —— 槽与 job 的映射 / 状态 —— 
# =========================
func _get_job_index_for_slot(slot: Node2D) -> int:
	var count: int = _job_slots.size()
	for i in range(count):
		if _job_slots[i] == slot:
			return i
	return -1


func _on_slot_occupied(slot: Node2D, card: Node2D) -> void:
	var idx: int = _get_job_index_for_slot(slot)
	if idx < 0:
		return

	if debug_log:
		_log("slot %d occupied by %s" % [idx, card])

	_job_input_cards[idx] = card
	_start_job_production(idx)


func _on_slot_cleared(slot: Node2D) -> void:
	var idx: int = _get_job_index_for_slot(slot)
	if idx < 0:
		return

	if debug_log:
		_log("slot %d cleared" % idx)

	_job_input_cards[idx] = null
	_stop_job_production(idx)


# =========================
# —— Job 生产流程 —— 
# =========================
func _start_job_production(job_index: int) -> void:
	if job_index < 0 or job_index >= _job_slots.size():
		return

	var card: Node2D = _job_input_cards[job_index]
	if card == null or not is_instance_valid(card):
		return

	var t: Timer = _job_timers[job_index]
	if t == null or not is_instance_valid(t):
		return

	t.wait_time = _get_job_interval(job_index)
	t.start()

	if debug_log:
		_log("job %d started, interval=%.2f" % [job_index, t.wait_time])


func _stop_job_production(job_index: int) -> void:
	if job_index < 0 or job_index >= _job_slots.size():
		return

	var t: Timer = _job_timers[job_index]
	if t == null or not is_instance_valid(t):
		return

	t.stop()

	if debug_log:
		_log("job %d stopped" % job_index)


func _on_job_timer_timeout(job_index: int) -> void:
	if job_index < 0 or job_index >= _job_slots.size():
		return

	var card: Node2D = _job_input_cards[job_index]
	if card == null or not is_instance_valid(card):
		_stop_job_production(job_index)
		return

	# 槽里还有卡 → 生成一个 pack
	_spawn_pack(job_index)

	if loop_produce:
		_start_job_production(job_index)
	else:
		_stop_job_production(job_index)


# =========================
# —— 生成 Pack —— 
# =========================
func _spawn_pack(job_index: int) -> void:
	if pack_scene == null:
		if debug_log:
			_log("job %d: cannot spawn pack, pack_scene is null." % job_index)
		return

	var parent: Node = get_tree().current_scene
	if parent == null or not is_instance_valid(parent):
		if debug_log:
			_log("job %d: cannot spawn pack, no valid parent." % job_index)
		return

	var pack_instance: Node = pack_scene.instantiate()
	parent.add_child(pack_instance)

	# 位置：以 WorkUnit 锚点为参考（show_at 传进来的 global_pos）
	var origin: Vector2

	if _anchor_valid:
		origin = _anchor_position
	else:
		# 兜底：用这个 job 槽自己的位置
		if job_index >= 0 and job_index < _job_slots.size():
			origin = _job_slots[job_index].global_position
		else:
			origin = Vector2.ZERO

	if pack_instance is Node2D:
		var p2d: Node2D = pack_instance as Node2D
		p2d.global_position = origin + spawn_offset

	if debug_log:
		_log("job %d spawned pack: %s at %s" % [job_index, pack_instance, origin + spawn_offset])


# =========================
# —— 工具 —— 
# =========================
func _log(msg: String) -> void:
	print("[work_unit_job] %s" % msg)
