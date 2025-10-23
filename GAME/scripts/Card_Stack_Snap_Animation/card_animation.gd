extends Node
class_name CardAnimation
## 轻量级卡牌动画组件（强类型 & 严格无推断警告版）

# ============ 可调参数 ============
@export var default_duration: float = 0.12
@export var default_trans: Tween.TransitionType = Tween.TRANS_SINE
@export var default_ease: Tween.EaseType = Tween.EASE_OUT

# bump（落位小弹跳）的参数
@export var bump_offset: Vector2 = Vector2(0, -6)
@export var bump_up_ratio: float = 0.35         # 上抬时间占比
@export var bump_total: float = 0.14            # 总时长

# ============ 信号 ============
signal on_finished   # 任一补间播放完毕时发出（不含 follow_immediate / jump_to）

# ============ 运行态 ============
var _tween: Tween = null

# --------------- 内部工具 ---------------
func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null

func _owner_card() -> Node2D:
	return get_parent() as Node2D

# --------------- 对外 API ---------------

## 拖拽中“无补间跟随”
func follow_immediate(card: Node2D, target_global: Vector2) -> void:
	var c: Node2D = card if card != null else _owner_card()
	if c == null:
		return
	c.global_position = target_global

## 瞬移到位（无补间）
func jump_to(target_global: Vector2, z: int = -99999, scale: float = -1.0) -> void:
	var card: Node2D = _owner_card()
	if card == null:
		return
	_kill_tween()
	card.global_position = target_global
	if z != -99999:
		card.z_index = z
	if scale > 0.0:
		card.scale = Vector2(scale, scale)

## 标准补间：位置 + 可选缩放 + 可选 Z
func tween_to(
		target_global: Vector2,
		dur: float = -1.0,
		scale: float = -1.0,
		z: int = -99999,
		trans: Tween.TransitionType = -1,
		ease: Tween.EaseType = -1
	) -> void:
	var card: Node2D = _owner_card()
	if card == null:
		return

	var d: float = (dur if dur > 0.0 else default_duration)
	var tr: Tween.TransitionType = (trans if trans != -1 else default_trans)
	var ea: Tween.EaseType = (ease if ease != -1 else default_ease)

	_kill_tween()
	_tween = create_tween()
	_tween.set_trans(tr).set_ease(ea)

	# 位置补间
	_tween.tween_property(card, "global_position", target_global, d)

	# 同步缩放
	if scale > 0.0:
		var tw_parallel: Tween = _tween.parallel()
		tw_parallel.tween_property(card, "scale", Vector2(scale, scale), d)

	# Z 直接设置（Z 不补间）
	if z != -99999:
		card.z_index = z

	_tween.finished.connect(func () -> void:
		emit_signal("on_finished")
	)

## 落位小弹跳：先抬起再回落（在当前位置附近做位移）
func bump() -> void:
	var card: Node2D = _owner_card()
	if card == null:
		return
	_kill_tween()

	var ratio: float = clamp(bump_up_ratio, 0.05, 0.95)
	var up_dur: float = float(bump_total) * ratio
	var down_dur: float = float(bump_total) - up_dur
	var start: Vector2 = card.global_position
	var up_pos: Vector2 = start + bump_offset

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_tween.tween_property(card, "global_position", up_pos, up_dur)

	# Godot 4：tween_property 返回 PropertyTweener
	var tw_down: PropertyTweener = _tween.tween_property(card, "global_position", start, down_dur)
	tw_down.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)

	_tween.finished.connect(func () -> void:
		emit_signal("on_finished")
	)

## 只做缩放（不改位置）
func scale_to(target_scale: float, dur: float = -1.0) -> void:
	var card: Node2D = _owner_card()
	if card == null:
		return
	var d: float = (dur if dur > 0.0 else default_duration)
	_kill_tween()
	_tween = create_tween().set_trans(default_trans).set_ease(default_ease)
	_tween.tween_property(card, "scale", Vector2(target_scale, target_scale), d)
	_tween.finished.connect(func () -> void:
		emit_signal("on_finished")
	)

## 旋转到角度（弧度）
func rotate_to(angle_rad: float, dur: float = -1.0) -> void:
	var card: Node2D = _owner_card()
	if card == null:
		return
	var d: float = (dur if dur > 0.0 else default_duration)
	_kill_tween()
	_tween = create_tween().set_trans(default_trans).set_ease(default_ease)
	_tween.tween_property(card, "rotation", angle_rad, d)
	_tween.finished.connect(func () -> void:
		emit_signal("on_finished")
	)

## 取消当前动画
func cancel() -> void:
	_kill_tween()

## 是否有动画在跑
func is_busy() -> bool:
	return _tween != null and _tween.is_running()

## 回弹到指定点（仅位置补间；默认不自动 bump，避免与外部重复）
func rebound_to(
		target_global: Vector2,
		dur: float = -1.0,
		do_bump: bool = false,
		trans: int = -1,
		ease_mode: int = -1
	) -> void:
	var card: Node2D = _owner_card()
	if card == null:
		return

	var d: float = (dur if dur > 0.0 else default_duration)
	var trans_mode: Tween.TransitionType = (trans if trans != -1 else default_trans)
	var ease_final: Tween.EaseType = (ease_mode if ease_mode != -1 else default_ease)

	_kill_tween()
	_tween = create_tween()
	_tween.set_trans(trans_mode).set_ease(ease_final)
	_tween.tween_property(card, "global_position", target_global, d)

	_tween.finished.connect(func () -> void:
		if do_bump:
			bump()
		emit_signal("on_finished")
	)
