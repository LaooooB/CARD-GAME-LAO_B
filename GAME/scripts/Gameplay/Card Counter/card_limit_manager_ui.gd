extends Label
class_name CardCounterUI

@export var debug_log: bool = false
@export var autoload_name: String = "CardLimitManager"

var _mgr: Node = null
var _last_cur: int = -1
var _last_cap: int = -1


func _ready() -> void:
	var path: NodePath = NodePath("/root/" + autoload_name)
	_mgr = get_node_or_null(path)
	
	if _mgr == null:
		text = "0 / 0"
		push_error("[CardCounterUI] manager not found at %s" % str(path))
		return
	
	if not _mgr.has_signal("card_count_changed"):
		text = "0 / 0"
		push_error("[CardCounterUI] node at %s has no signal 'card_count_changed'" % str(path))
		return
	
	# 初始化文本（从 Manager 当前值读一次）
	var cur: int = int(_mgr.get("current_card_count"))
	var cap: int = int(_mgr.get("max_card_capacity"))
	_last_cur = cur
	_last_cap = cap
	text = "%d / %d" % [cur, cap]
	
	_mgr.connect("card_count_changed", Callable(self, "_on_card_count_changed"))
	set_process(true)  # 开启 _process 兜底刷新
	
	if debug_log:
		print("[CardCounterUI] connected to", str(path))


func _on_card_count_changed(current: int, max: int) -> void:
	_last_cur = current
	_last_cap = max
	text = "%d / %d" % [current, max]


func _process(_delta: float) -> void:
	if _mgr == null:
		return
	
	# 每帧从 Manager 读一次数值，如果发现有变化就更新 UI
	var cur: int = int(_mgr.get("current_card_count"))
	var cap: int = int(_mgr.get("max_card_capacity"))
	
	if cur != _last_cur or cap != _last_cap:
		_last_cur = cur
		_last_cap = cap
		text = "%d / %d" % [cur, cap]
		if debug_log:
			print("[CardCounterUI] polled update:", cur, "/", cap)
