# start_new_game.gd
extends Button

# —— 目标场景（你的 Main）——
@export var target_scene_path: String = "res://GAME/scenes/2D/Main.tscn"

# —— 淡出参数（可在 Inspector 调）——
@export var fade_out_duration: float = 0.4
@export var fade_out_color: Color = Color(0, 0, 0, 1.0)
@export var fade_out_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var fade_out_ease: Tween.EaseType = Tween.EASE_IN

var _is_transitioning: bool = false


func _ready() -> void:
	pressed.connect(_on_pressed)


func _on_pressed() -> void:
	if _is_transitioning:
		return
	_is_transitioning = true
	disabled = true	# 防止连点
	_start_scene_fade_out()


func _start_scene_fade_out() -> void:
	var root: Node = get_tree().current_scene
	if root == null or fade_out_duration <= 0.0:
		# 兜底：没有当前场景/时长 <= 0 就直接切
		get_tree().change_scene_to_file(target_scene_path)
		return

	var fade := ColorRect.new()
	fade.color = Color(fade_out_color.r, fade_out_color.g, fade_out_color.b, 0.0)  # 从透明开始
	fade.anchor_left = 0.0
	fade.anchor_top = 0.0
	fade.anchor_right = 1.0
	fade.anchor_bottom = 1.0
	fade.offset_left = 0.0
	fade.offset_top = 0.0
	fade.offset_right = 0.0
	fade.offset_bottom = 0.0
	fade.mouse_filter = Control.MOUSE_FILTER_IGNORE

	root.add_child(fade)
	fade.move_to_front()

	var tw := create_tween()
	tw.set_trans(fade_out_trans)
	tw.set_ease(fade_out_ease)
	tw.tween_property(
		fade,
		"color",
		Color(fade_out_color.r, fade_out_color.g, fade_out_color.b, 1.0),
		fade_out_duration
	)
	tw.finished.connect(func () -> void:
		get_tree().change_scene_to_file(target_scene_path)
	)
