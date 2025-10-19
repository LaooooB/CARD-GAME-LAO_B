extends Node2D
class_name SellZone

@onready var area: Area2D = $Area2D

const HOVER_Z: int = 50000  # 进入卖区时临时提层

var _inside_cards: Array[Node2D] = []
var _old_z: Dictionary = {}  # card(Node2D) -> {"z": int, "rel": bool}

func _ready() -> void:
	if area != null:
		area.monitoring = true
		area.area_entered.connect(_on_area_entered)
		area.area_exited.connect(_on_area_exited)
	set_process_input(true)

# 进入卖区：临时提层
func _on_area_entered(other: Area2D) -> void:
	var card: Node2D = other.get_parent() as Node2D
	if card == null or not card.is_in_group("cards"):
		return
	if not _inside_cards.has(card):
		_inside_cards.append(card)
	if not _old_z.has(card):
		_old_z[card] = {"z": card.z_index, "rel": card.z_as_relative}
	card.z_as_relative = false
	card.z_index = HOVER_Z

# 离开卖区：恢复层级
func _on_area_exited(other: Area2D) -> void:
	var card: Node2D = other.get_parent() as Node2D
	if card == null:
		return
	_inside_cards.erase(card)
	if _old_z.has(card):
		var info: Dictionary = _old_z[card]
		card.z_index = int(info.get("z", 0))
		card.z_as_relative = bool(info.get("rel", true))
		_old_z.erase(card)

# 在卖区内松开左键 → 安全删除
func _input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_LEFT or mb.pressed:
		return
	if _inside_cards.is_empty():
		return

	# 取当前在卖区内 z 最高的一张（一般就是被拖拽的那张）
	var target: Node2D = null
	for c in _inside_cards:
		if target == null or c.z_index > target.z_index:
			target = c
	if target == null or not is_instance_valid(target):
		return

	# —— 安全删除策略 —— 
	_inside_cards.erase(target)
	if _old_z.has(target):
		_old_z.erase(target)

	# 先“软禁用”：避免同帧其他脚本继续操作它
	target.set_process(false)
	target.set_physics_process(false)
	target.visible = false  # Node2D/CanvasItem 直接可用

	# 延迟到帧末释放，避免同帧回调对已销毁对象调用
	target.call_deferred("queue_free")
