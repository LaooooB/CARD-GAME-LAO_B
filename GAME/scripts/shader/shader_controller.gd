extends Node
class_name CardController

# —— 必填节点路径 —— 
@export var hit_full_path: NodePath = ^"../hit_full"   # Area2D，整张卡命中区
@export var scale_target_path: NodePath = ^".."        # 要放大的节点（默认 Card 根）

# —— 悬停放大参数（可在 Inspector 调）——
@export var hover_enabled: bool = true
@export var hover_scale: Vector2 = Vector2(1.20, 1.20)
@export var hover_scale_duration: float = 0.25
@export var hover_scale_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var hover_scale_ease: Tween.EaseType = Tween.EASE_OUT
@export_range(0.05, 5.0, 0.05) var hover_speed_scale: float = 1.0

# —— 运行时引用 —— 
var _hit_full: Area2D
var _scale_target: Node

# —— 状态 —— 
var _base_scale: Vector2 = Vector2.ONE
var _mouse_over: bool = false

# —— Tween —— 
var tween_hover: Tween = null

func _ready() -> void:
	_hit_full = get_node_or_null(hit_full_path) as Area2D
	_scale_target = get_node_or_null(scale_target_path)
	assert(_hit_full != null and _scale_target != null)

	# 记录初始缩放
	if _scale_target is Node2D:
		_base_scale = (_scale_target as Node2D).scale
	elif _scale_target is Control:
		_base_scale = (_scale_target as Control).scale
	else:
		_base_scale = Vector2.ONE

	# 只连 enter / exit
	if not _hit_full.mouse_entered.is_connected(_on_hit_mouse_entered):
		_hit_full.mouse_entered.connect(_on_hit_mouse_entered)
	if not _hit_full.mouse_exited.is_connected(_on_hit_mouse_exited):
		_hit_full.mouse_exited.connect(_on_hit_mouse_exited)

func _on_hit_mouse_entered() -> void:
	_mouse_over = true
	if hover_enabled:
		_play_hover_scale(true)

func _on_hit_mouse_exited() -> void:
	_mouse_over = false
	if hover_enabled:
		_play_hover_scale(false)

# —— 悬停放大/缩回 —— 
func _play_hover_scale(entering: bool) -> void:
	var can_scale: bool = (_scale_target is Node2D) or (_scale_target is Control)
	if not can_scale:
		return

	var current_scale: Vector2 = (_scale_target as Node).get("scale")
	var target_scale: Vector2 = (hover_scale if entering else _base_scale)
	if current_scale.is_equal_approx(target_scale):
		return

	if tween_hover != null and tween_hover.is_running():
		tween_hover.kill()

	var eff_duration: float = hover_scale_duration / max(0.001, hover_speed_scale)
	tween_hover = create_tween()
	tween_hover.set_trans(hover_scale_trans).set_ease(hover_scale_ease)
	tween_hover.tween_property(_scale_target, "scale", target_scale, eff_duration)

# —— 工具：外部可调用，直接收回到基础缩放 —— 
func shrink_to_base(immediate: bool = false) -> void:
	var can_scale := (_scale_target is Node2D) or (_scale_target is Control)
	if not can_scale:
		return
	if immediate:
		if tween_hover != null and tween_hover.is_running():
			tween_hover.kill()
		(_scale_target as Node).set("scale", _base_scale)
	else:
		_play_hover_scale(false)
