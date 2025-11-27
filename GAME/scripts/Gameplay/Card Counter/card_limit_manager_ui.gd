extends Label
class_name CardCounterUI

@export var debug_log: bool = false
@export var autoload_name: String = "CardLimitManager"

var _mgr: Node = null


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
	
	# 初始化文本
	var cur: int = int(_mgr.get("current_card_count"))
	var cap: int = int(_mgr.get("max_card_capacity"))
	text = "%d / %d" % [cur, cap]
	
	_mgr.connect("card_count_changed", Callable(self, "_on_card_count_changed"))
	
	if debug_log:
		print("[CardCounterUI] connected to", str(path))


func _on_card_count_changed(current: int, max: int) -> void:
	text = "%d / %d" % [current, max]

	# 这里你以后可以加一些“快满了就变色”的逻辑，现在先留空
	# 例如：
	# var ratio := (max > 0) ? float(current) / float(max) : 0.0
	# if ratio >= 1.0:
	#     self_modulate = Color(1, 0.3, 0.3)  # 满载变红
	# elif ratio >= 0.9:
	#     self_modulate = Color(1, 0.7, 0.3)  # 接近满载变黄
	# else:
	#     self_modulate = Color(1, 1, 1)      # 正常
