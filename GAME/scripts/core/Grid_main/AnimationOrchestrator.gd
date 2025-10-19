extends Node
# 不用 class_name，避免全局名冲突
class_name AnimationOrchestrator
# —— 统一动画参数（可在 Inspector 调）——
# 吸附（新卡/重排到位）
@export var snap_enabled: bool = true
@export_range(0.01, 1.0, 0.01) var snap_duration: float = 0.14
@export var snap_transition: Tween.TransitionType = Tween.TRANS_CUBIC
@export var snap_ease: Tween.EaseType = Tween.EASE_OUT

# 回弹（落在禁区/失败返回）
@export var return_enabled: bool = true
@export_range(0.01, 1.0, 0.01) var return_duration: float = 0.14
@export var return_transition: Tween.TransitionType = Tween.TRANS_CUBIC
@export var return_ease: Tween.EaseType = Tween.EASE_OUT

# 让位（被遮挡的堆整体下移）
@export var shift_enabled: bool = true
@export_range(0.01, 1.2, 0.01) var shift_duration: float = 0.18
@export var shift_transition: Tween.TransitionType = Tween.TRANS_QUAD
@export var shift_ease: Tween.EaseType = Tween.EASE_IN_OUT

# —— 内部：每张卡一个活动 tween —— 
var _tweens: Dictionary = {}        # Node2D -> Tween

func _ready() -> void:
	add_to_group("anim_orchestrator")

# ========== 对外 API ==========
func snap(card: Node2D, target: Vector2) -> void:
	if not snap_enabled:
		card.global_position = target
		return
	_tween(card, target, snap_duration, snap_transition, snap_ease)

func bounce(card: Node2D, target: Vector2) -> void:
	if not return_enabled:
		card.global_position = target
		return
	_tween(card, target, return_duration, return_transition, return_ease)

func shift(card: Node2D, target: Vector2) -> void:
	if not shift_enabled:
		card.global_position = target
		return
	_tween(card, target, shift_duration, shift_transition, shift_ease)

func cancel(card: Node2D) -> void:
	if _tweens.has(card):
		var t: Tween = _tweens[card]
		if is_instance_valid(t):
			t.kill()
		_tweens.erase(card)
	card.set_meta("is_snapping", false)

func is_animating(card: Node2D) -> bool:
	return card.has_meta("is_snapping") and bool(card.get_meta("is_snapping"))

# ========== 内部：统一补间 ==========
func _tween(card: Node2D, target: Vector2, dur: float, trans: int, ease: int) -> void:
	# 防重复
	if _tweens.has(card):
		var old: Tween = _tweens[card]
		if is_instance_valid(old):
			old.kill()
		_tweens.erase(card)

	card.set_meta("is_snapping", true)
	var t: Tween = create_tween()
	_tweens[card] = t
	t.set_trans(trans).set_ease(ease)
	t.tween_property(card, "global_position", target, dur)
	t.finished.connect(func():
		if _tweens.has(card):
			_tweens.erase(card)
		card.set_meta("is_snapping", false))
