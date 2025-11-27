extends Node
class_name CardController

# —— 必填节点路径 ——
@export var hit_full_path: NodePath = ^"../hit_full"   # Area2D，整张卡命中区
@export var scale_target_path: NodePath = ^".."        # 要放大的节点（默认 Card 根）

# —— 悬停放大参数（可在 Inspector 调）——
@export var hover_enabled: bool = true
@export var hover_scale: Vector2 = Vector2(1.20, 1.20)      # 单卡 hover 缩放
@export var pile_hover_scale: Vector2 = Vector2(1.05, 1.05) # pile hover 缩放
@export var hover_scale_duration: float = 0.25
@export var hover_scale_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var hover_scale_ease: Tween.EaseType = Tween.EASE_OUT
@export_range(0.05, 5.0, 0.05) var hover_speed_scale: float = 1.0

# —— 按下/拖拽时的缩回 ——
@export var drag_shrink_duration: float = 0.12
@export var drag_shrink_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var drag_shrink_ease: Tween.EaseType = Tween.EASE_OUT

# —— 运行时引用 ——
var _hit_full: Area2D
var _scale_target: Node

# —— 状态 ——
var _base_scale: Vector2 = Vector2.ONE
var _mouse_over: bool = false       # hit_full hover
var _pile_hover: bool = false       # pile hover 来自 PileManager

# —— Tween ——
var tween_hover: Tween = null

# —— 上一次锁定，用于松开时刷新 ——
var _hover_locked_prev: bool = false

func _ready() -> void:
	_hit_full = get_node_or_null(hit_full_path) as Area2D
	_scale_target = get_node_or_null(scale_target_path)
	assert(_hit_full != null and _scale_target != null)

	# 记录初始 scale
	if _scale_target is Node2D:
		_base_scale = (_scale_target as Node2D).scale
	elif _scale_target is Control:
		_base_scale = (_scale_target as Control).scale
	else:
		_base_scale = Vector2.ONE

	# 链接 enter / exit
	if not _hit_full.mouse_entered.is_connected(_on_hit_mouse_entered):
		_hit_full.mouse_entered.connect(_on_hit_mouse_entered)
	if not _hit_full.mouse_exited.is_connected(_on_hit_mouse_exited):
		_hit_full.mouse_exited.connect(_on_hit_mouse_exited)

	if not is_in_group("card_controllers"):
		add_to_group("card_controllers", true)

	set_process(true)

func _process(_dt: float) -> void:
	var locked: bool = _hover_locked()
	if locked != _hover_locked_prev:
		_hover_locked_prev = locked
		_update_hover_scale()

# ==================== Hover 入口 ====================

func _on_hit_mouse_entered() -> void:
	# pile hover 时禁用单卡 hover
	if _pile_hover:
		return
	_mouse_over = true
	if _hover_locked() or not hover_enabled:
		return
	_update_hover_scale()

func _on_hit_mouse_exited() -> void:
	if _pile_hover:
		return
	_mouse_over = false
	if _hover_locked() or not hover_enabled:
		return
	_update_hover_scale()

# =============== 被 PileManager 调用：堆叠 hover ===============

func set_pile_hover(active: bool) -> void:
	if _hover_locked():
		if _pile_hover:
			_pile_hover = false
			_update_hover_scale()
		return

	if _pile_hover == active:
		return

	_pile_hover = active

	if active:
		_mouse_over = false  # 防止顶牌叠加单卡 hover

	_update_hover_scale()

# =============== 拖拽广播（可选） ===============
func on_global_drag_started() -> void:
	_update_hover_scale()

# =============== 强制缩回基础比例 ===============
func shrink_to_base(immediate: bool = false) -> void:
	var can_scale: bool = (_scale_target is Node2D) or (_scale_target is Control)
	if not can_scale:
		return

	_mouse_over = false
	_pile_hover = false

	if immediate:
		if tween_hover != null and tween_hover.is_running():
			tween_hover.kill()
		(_scale_target as Node).set("scale", _base_scale)
	else:
		_update_hover_scale()

# ==================== 核心：统一决定当前缩放 ====================

func _update_hover_scale() -> void:
	var can_scale: bool = (_scale_target is Node2D) or (_scale_target is Control)
	if not can_scale:
		return

	var locked: bool = _hover_locked()

	var target_scale: Vector2 = _base_scale
	var duration: float = hover_scale_duration / max(0.001, hover_speed_scale)
	var trans: Tween.TransitionType = hover_scale_trans
	var ease: Tween.EaseType = hover_scale_ease

	if not hover_enabled:
		target_scale = _base_scale

	elif locked:
		target_scale = _base_scale
		duration = drag_shrink_duration
		trans = drag_shrink_trans
		ease = drag_shrink_ease

	else:
		var active_card_hover: bool = _mouse_over
		var active_pile_hover: bool = _pile_hover
		var in_multi_pile: bool = _is_in_multi_card_pile()

		if active_pile_hover:
			target_scale = pile_hover_scale
		elif active_card_hover:
			# 顶牌也属于 pile 逻辑，只要堆里不只它一个
			if in_multi_pile:
				target_scale = pile_hover_scale
			else:
				target_scale = hover_scale
		else:
			target_scale = _base_scale

	_tween_scale_to(target_scale, duration, trans, ease)

# ==================== Tween ====================

func _tween_scale_to(target_scale: Vector2, duration: float, trans: Tween.TransitionType, ease: Tween.EaseType) -> void:
	var can_scale: bool = (_scale_target is Node2D) or (_scale_target is Control)
	if not can_scale:
		return

	var current_scale: Vector2 = (_scale_target as Node).get("scale")
	if current_scale.is_equal_approx(target_scale):
		return

	if tween_hover != null and tween_hover.is_running():
		tween_hover.kill()

	tween_hover = create_tween()
	tween_hover.set_trans(trans).set_ease(ease)
	tween_hover.tween_property(_scale_target, "scale", target_scale, max(0.0, duration))

# ==================== 拖拽锁定 ====================
func _hover_locked() -> bool:
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)

# ==================== 判断是否在多张卡 pile 中 ====================
func _is_in_multi_card_pile() -> bool:
	var card_root: Node = _scale_target
	if card_root == null:
		card_root = get_parent()
	if card_root == null:
		return false

	if not card_root.has_method("get_pile"):
		return false

	var pile: Object = card_root.call("get_pile")
	if pile == null or not is_instance_valid(pile):
		return false

	if not pile.has_method("get_cards"):
		return false

	var cards: Array = pile.call("get_cards")
	return cards.size() > 1
