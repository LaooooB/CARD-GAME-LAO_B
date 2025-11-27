extends Node
class_name CardLimitManagerNode

signal card_count_changed(current: int, max: int)

@export var initial_max_capacity: int = 40
@export var debug_log: bool = false

var current_card_count: int = 0
var max_card_capacity: int = 0


func _ready() -> void:
	max_card_capacity = max(initial_max_capacity, 0)
	current_card_count = 0    # 新游戏默认 0；如果你有读档流程，读档时自己 set_current_count
	_emit_changed()
	if debug_log:
		print("[CardLimitManager] ready, count =", current_card_count, "/", max_card_capacity)


func _emit_changed() -> void:
	emit_signal("card_count_changed", current_card_count, max_card_capacity)
	if debug_log:
		print("[CardLimitManager] count =", current_card_count, "/", max_card_capacity)


# ========== 事件接口：加 / 减 卡牌数 ==========

func add_cards(amount: int) -> void:
	if amount <= 0:
		return
	current_card_count += amount
	if current_card_count < 0:
		current_card_count = 0
	_emit_changed()


func remove_cards(amount: int) -> void:
	if amount <= 0:
		return
	current_card_count -= amount
	if current_card_count < 0:
		current_card_count = 0
	_emit_changed()


func set_current_count(new_value: int) -> void:
	current_card_count = max(new_value, 0)
	_emit_changed()


# ========== 容量相关 ==========

func get_free_slots() -> int:
	return max(0, max_card_capacity - current_card_count)


func can_spawn(amount: int) -> bool:
	if amount <= 0:
		return true
	return amount <= get_free_slots()


func set_capacity(new_capacity: int) -> void:
	max_card_capacity = max(new_capacity, 0)
	_emit_changed()


func add_capacity_from_box(bonus: int) -> void:
	if bonus <= 0:
		return
	max_card_capacity = max(max_card_capacity + bonus, 0)
	_emit_changed()
