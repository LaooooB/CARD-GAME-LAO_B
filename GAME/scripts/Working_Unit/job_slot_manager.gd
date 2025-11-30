extends Node


# 统一声明：存的是 WorkUnit 的 WeakRef
var _work_units: Array[WeakRef] = []

func _cleanup_dead() -> void:
	for i: int in range(_work_units.size() - 1, -1, -1):
		var wu: Node = _work_units[i].get_ref() as Node
		if wu == null or not is_instance_valid(wu):
			_work_units.remove_at(i)

func register_work_unit(wu: Node) -> void:
	if wu == null or not is_instance_valid(wu):
		return

	_cleanup_dead()

	for wref: WeakRef in _work_units:
		var inst: Node = wref.get_ref() as Node
		if inst == wu:
			return

	_work_units.append(weakref(wu))

func unregister_work_unit(wu: Node) -> void:
	if wu == null:
		return

	for i: int in range(_work_units.size() - 1, -1, -1):
		var inst: Node = _work_units[i].get_ref() as Node
		if inst == null or not is_instance_valid(inst) or inst == wu:
			_work_units.remove_at(i)

# Card 在 _end_drag_and_drop 里先调用：
# 如果有某个 WorkUnit 愿意 snap 这张卡，就返回 true。
func try_snap_card(card: Node2D, drop_global: Vector2) -> bool:
	if card == null or not is_instance_valid(card):
		return false

	_cleanup_dead()

	for wref: WeakRef in _work_units:
		var wu: Node = wref.get_ref() as Node
		if wu == null or not is_instance_valid(wu):
			continue

		if wu.has_method("_try_snap_card"):
			var accepted: bool = bool(wu.call("_try_snap_card", card, drop_global))
			if accepted:
				return true

	return false

# Card 开始拖拽时通知：如果这张卡原来在某个槽里，让该槽把引用清掉
func on_card_begin_drag(card: Node2D) -> void:
	if card == null or not is_instance_valid(card):
		return

	_cleanup_dead()

	for wref: WeakRef in _work_units:
		var wu: Node = wref.get_ref() as Node
		if wu == null or not is_instance_valid(wu):
			continue

		if wu.has_method("_on_card_begin_drag"):
			wu.call("_on_card_begin_drag", card)
