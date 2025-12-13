extends Node2D
class_name living_animation

# =============== Inspector 参数 ===============

@export var face_path: NodePath = ^"DialFace"
@export var pointer_path: NodePath = ^"DialPointer"

# 起始角度（进度=0）和总转角（进度=1）
# 机械表盘常见是从 12 点方向开始，所以 -90 度 = 正上
@export var start_angle_deg: float = -90.0
@export var sweep_angle_deg: float = 360.0

# 是否做“机械刻度感”的分段跳动
@export var use_step_ticks: bool = false
@export_range(1, 100, 1) var tick_steps: int = 24

# 当 living 关闭 upkeep_enabled 时的表现：
# true = 指针复位到起点；false = 停在最后一次角度
@export var reset_when_disabled: bool = true


# =============== 运行期 ===============

var _face: Node2D = null
var _pointer: Node2D = null
var _living: living = null
var _current_angle_rad: float = 0.0
var _prev_progress: float = 0.0


func _ready() -> void:
	# 找表盘底图和指针
	if face_path != NodePath(""):
		var f: Node = get_node_or_null(face_path)
		if f != null and f is Node2D:
			_face = f as Node2D
	
	if pointer_path != NodePath(""):
		var p: Node = get_node_or_null(pointer_path)
		if p != null and p is Node2D:
			_pointer = p as Node2D
	
	# 找到父节点 living
	_living = get_parent() as living
	if _living == null:
		push_warning("living_animation: 父节点不是 living，无法读取进度。")
		set_process(false)
		return
	
	# 初始化角度为起点
	_current_angle_rad = deg_to_rad(start_angle_deg)
	if _pointer != null:
		_pointer.rotation = _current_angle_rad
	
	_prev_progress = 0.0
	set_process(true)


func _process(_delta: float) -> void:
	if _living == null:
		return
	
	var progress: float = _living.get_cycle_progress()
	progress = clamp(progress, 0.0, 1.0)
	
	# 若 upkeep 被关闭
	if not _living.upkeep_enabled:
		if reset_when_disabled:
			progress = 0.0
		else:
			# 维持现状：不再更新
			return
	
	# 可选：分段机械刻度感
	if use_step_ticks and tick_steps > 0:
		var step_index: int = int(floor(progress * tick_steps))
		progress = float(step_index) / float(tick_steps)
	
	# 映射到角度
	var angle_deg: float = start_angle_deg + sweep_angle_deg * progress
	_current_angle_rad = deg_to_rad(angle_deg)
	
	if _pointer != null:
		_pointer.rotation = _current_angle_rad
	
	_prev_progress = progress
