extends Node
class_name CardLimitManagerNode

signal card_count_changed(current: int, max: int)

@export var initial_max_capacity: int = 40
@export var debug_log: bool = false

# 从这里往下的节点都算“场上的牌”
@export var board_root_path: NodePath
@export var count_cards: bool = true           # 统计 class_name Card
@export var count_work_units: bool = false     # 统计 class_name WorkUnitBase（如果需要）

var current_card_count: int = 0
var max_card_capacity: int = 0

var _board_root_cache: Node = null
var _recalc_queued: bool = false


func _ready() -> void:
	max_card_capacity = max(initial_max_capacity, 0)
	_update_board_root()
	recalculate_from_board()
	if debug_log:
		print("[CardLimitManager] ready, capacity =", max_card_capacity, " count =", current_card_count)


func _update_board_root() -> void:
	if board_root_path == NodePath(""):
		_board_root_cache = get_tree().root
	else:
		_board_root_cache = get_node_or_null(board_root_path)
		if _board_root_cache == null and debug_log:
			push_error("[CardLimitManager] board_root not found at %s" % str(board_root_path))


# ===== 对外主接口：按需重算（立刻执行） =====
func recalculate_from_board() -> void:
	if _board_root_cache == null:
		_update_board_root()
	if _board_root_cache == null:
		if current_card_count != 0:
			current_card_count = 0
			_emit_changed()
		return

	var total: int = 0
	var stack: Array[Node] = [_board_root_cache]

	while stack.size() > 0:
		var n: Node = stack.pop_back()

		if count_cards and n is Card:
			total += 1
		elif count_work_units and n is WorkUnitBase:
			total += 1

		for child in n.get_children():
			stack.push_back(child)

	if total != current_card_count:
		current_card_count = total
		_emit_changed()
	elif debug_log:
		print("[CardLimitManager] recalc ->", current_card_count, "/", max_card_capacity)


func _emit_changed() -> void:
	emit_signal("card_count_changed", current_card_count, max_card_capacity)
	if debug_log:
		print("[CardLimitManager] count =", current_card_count, "/", max_card_capacity)


# ===== 对外主接口：按需重算（延迟到本帧 idle 阶段执行） =====
# 用这个来应对 queue_free / call_deferred 的延迟删除
func request_recalc() -> void:
	if _recalc_queued:
		return
	_recalc_queued = true
	call_deferred("_do_recalc")


func _do_recalc() -> void:
	_recalc_queued = false
	recalculate_from_board()


# ===== 预留：箱子提升上限 =====
func add_capacity_from_box(bonus: int) -> void:
	if bonus <= 0:
		return
	max_card_capacity = max(max_card_capacity + bonus, 0)
	_emit_changed()
