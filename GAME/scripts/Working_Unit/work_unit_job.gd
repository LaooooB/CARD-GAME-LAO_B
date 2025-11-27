extends Control
class_name work_unit_job

@export var margin: Vector2 = Vector2(8, 8) # 定位时的小偏移

func show_at(global_pos: Vector2) -> void:
	# 放到指定位置上方一点，避免完全遮到卡
	global_position = global_pos + Vector2(0, -size.y) - margin
	visible = true

func toggle_at(global_pos: Vector2) -> void:
	if visible:
		visible = false
	else:
		show_at(global_pos)
