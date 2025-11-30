# SettingsPage.gd
extends Control

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# set_process_unhandled_input(true) # 现在不需要专门吃 Esc 了


# ==== 旧的 Esc 逻辑（已禁用） ====
#func _unhandled_input(event: InputEvent) -> void:
#	if event.is_action_pressed("ui_cancel"):
#		_on_esc()
#		get_viewport().set_input_as_handled()
#
#func _on_esc() -> void:
#	queue_free()
# ==== 旧的 Esc 逻辑结束 ====
