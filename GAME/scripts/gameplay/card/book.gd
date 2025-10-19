extends Node2D
class_name Book

@export var texture: Texture2D

# ==== 新增：卡面数值 ====
enum Rarity { Common, Uncommon, Rare, Epic, Legendary } # 可扩展
@export var value: int = 1
@export var rarity: int = Rarity.Common  # 在 Inspector 中显示为枚举索引（0=Common）

@onready var sprite: Sprite2D = $Sprite2D
@onready var area: Area2D = $Area2D
@onready var col: CollisionShape2D = $Area2D/CollisionShape2D

const DRAG_Z := 4096

var dragging: bool = false
var drag_target: Node2D = null
var drag_offset: Vector2 = Vector2.ZERO
var base_scale: Vector2 = Vector2.ONE
var _pre_drag_pos: Vector2 = Vector2.ZERO

# 仅用于“单卡拖拽放大”的视觉；组拖由管理器控制
var _scaled_card: Node2D = null

# —— 单卡拖拽时的还原信息（组拖不走这套）——
var _pre_drag_z: int = 0
var _pre_drag_z_as_relative: bool = true
var _pre_drag_top_level: bool = false
var _pre_drag_parent: Node = null
var _pre_drag_sibling: int = -1
var _used_drag_layer: bool = false

func _ready() -> void:
	if texture != null:
		sprite.texture = texture
	_ensure_rect_shape_matches_sprite()
	base_scale = scale
	add_to_group("cards")
	area.input_event.connect(_on_area_input_event)
	set_process_input(true)

# 点击开始拖拽（支持：点中间牌眉 → 选它+上方所有牌）
func _on_area_input_event(_vp, event: InputEvent, _shape_idx: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb: InputEventMouseButton = event
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return

	# 1) 找“谁来判定命中 & 组拖”
	var reg: Node = get_node_or_null("/root/SnapRegistry")
	var gm: Node = null
	if reg == null:
		var managers := get_tree().get_nodes_in_group("snap_manager")
		if managers.size() > 0:
			gm = managers[0]

	# 2) 让 Manager 判定“到底点中了哪张牌”
	var mouse_pos: Vector2 = get_global_mouse_position()
	var picked: Node2D = null

	if reg != null and reg.has_method("pick_card_at"):
		picked = reg.pick_card_at(mouse_pos)
	elif gm != null and gm.has_method("pick_card_at"):
		picked = gm.pick_card_at(mouse_pos)

	if picked == null:
		picked = self

	# 3) 设定拖拽目标
	drag_target = picked
	_pre_drag_pos = drag_target.global_position

	# 4) 交给 Manager 组装“它 + 上方所有牌”为子堆，并尝试进入组拖
	if reg != null and reg.has_method("prepare_drag_group"):
		reg.prepare_drag_group(drag_target, mouse_pos)
	elif gm != null and gm.has_method("prepare_drag_group"):
		gm.prepare_drag_group(drag_target, mouse_pos)

	if reg != null and reg.has_method("begin_group_drag"):
		reg.begin_group_drag(drag_target)
	elif gm != null and gm.has_method("begin_group_drag"):
		gm.begin_group_drag(drag_target)

	# 5) 判断是否已进入“组拖”
	var group_active: bool = false
	if reg != null and reg.has_method("is_group_active_for"):
		group_active = reg.is_group_active_for(drag_target)
	elif gm != null and gm.has_method("is_group_active_for"):
		group_active = gm.is_group_active_for(drag_target)

	if not group_active:
		# —— 单卡拖拽视觉（组拖不走这套）——
		_pre_drag_parent = drag_target.get_parent()
		_pre_drag_sibling = drag_target.get_index()

		var gp: Vector2 = drag_target.global_position
		drag_target.top_level = true
		drag_target.global_position = gp

		drag_target.z_as_relative = false
		drag_target.z_index = DRAG_Z
		_scaled_card = drag_target
		_scaled_card.scale = base_scale * 1.04

	# 6) 记录拖拽偏移，进入拖拽态
	drag_offset = drag_target.global_position - mouse_pos
	dragging = true


func _input(event: InputEvent) -> void:
	if not dragging: return
	if drag_target == null: return

	if event is InputEventMouseMotion:
		# 始终移动 drag_target（可能是自己，也可能是子堆头）
		drag_target.global_position = get_global_mouse_position() + drag_offset

	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		# 鼠标抬起：结束拖拽
		dragging = false
		if _scaled_card != null:
			_scaled_card.scale = base_scale

		# 单卡拖拽才需要把节点放回原父级；组拖由 GridSnapManager.end_group_drag 收尾
		var gm := get_tree().get_first_node_in_group("snap_manager")
		var is_group_active: bool = (gm != null and gm.has_method("is_group_active_for") and gm.is_group_active_for(drag_target))

		if not is_group_active:
			var gp := drag_target.global_position
			if _used_drag_layer:
				var idx := _pre_drag_sibling
				if _pre_drag_parent != null and idx > _pre_drag_parent.get_child_count():
					idx = _pre_drag_parent.get_child_count()
				drag_target.reparent(_pre_drag_parent, idx)
				drag_target.global_position = gp
			else:
				drag_target.top_level = _pre_drag_top_level
				drag_target.global_position = gp

			drag_target.z_index = _pre_drag_z
			drag_target.z_as_relative = _pre_drag_z_as_relative

		# 让管理器尝试吸附（注意传入 drag_target 与它的 _pre_drag_pos）
		var snapped := false
		if gm and gm.has_method("try_snap"):
			snapped = gm.try_snap(drag_target, _pre_drag_pos)

		if not snapped:
			# 改为走 AnimationOrchestrator 的回弹；如果没有，就瞬移回去
			var orchestrator := get_tree().get_first_node_in_group("anim_orchestrator")
			if orchestrator and orchestrator.has_method("bounce"):
				orchestrator.bounce(drag_target, _pre_drag_pos)
			else:
				drag_target.global_position = _pre_drag_pos

		# 清理上下文
		drag_target = null
		_scaled_card = null
		_used_drag_layer = false

# —— 工具：DragLayer ——
func _get_drag_layer() -> CanvasLayer:
	var best: CanvasLayer = null
	for n in get_tree().get_nodes_in_group("drag_layer"):
		if n is CanvasLayer:
			var cl := n as CanvasLayer
			if best == null or cl.layer > best.layer:
				best = cl
	return best

func _ensure_rect_shape_matches_sprite() -> void:
	var shape: Shape2D = col.shape
	if shape == null or not (shape is RectangleShape2D):
		shape = RectangleShape2D.new()
		col.shape = shape
	var sz: Vector2 = Vector2(64, 96)
	if sprite.texture != null:
		sz = sprite.texture.get_size()
	(col.shape as RectangleShape2D).extents = sz * 0.5

# —— 新增：工具方法（可选）——
static func rarity_to_string(idx: int) -> String:
	match idx:
		Rarity.Common: return "Common"
		Rarity.Uncommon: return "Uncommon"
		Rarity.Rare: return "Rare"
		Rarity.Epic: return "Epic"
		Rarity.Legendary: return "Legendary"
		_: return "Unknown"

func get_rarity_name() -> String:
	return Book.rarity_to_string(rarity)
	
	
