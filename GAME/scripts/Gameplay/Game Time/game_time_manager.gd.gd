extends Node
class_name GameTimeManager

signal time_paused_changed(paused: bool)

# 实例上的标记（给别的脚本直接读用）
var is_time_paused: bool = false
# 类级静态标记（给 GameTimeManager.is_paused() 用）
static var _paused_flag: bool = false


func _ready() -> void:
	# 不再改 Engine.time_scale，让引擎时间一直正常跑
	# Engine.time_scale = 1.0
	set_process_input(true)


func _input(event: InputEvent) -> void:
	# 这里用 Input Map 里配置的 action 名（推荐 "pause_time"）
	if event.is_action_pressed("pause_time"):
		_toggle_pause()


func _toggle_pause() -> void:
	# 翻转静态标记
	GameTimeManager._paused_flag = !GameTimeManager._paused_flag

	# 同步一份到实例字段，方便其他脚本用 autoload 读
	is_time_paused = GameTimeManager._paused_flag

	# 发信号（如果你以后要做 UI 提示可以用）
	time_paused_changed.emit(is_time_paused)


# 静态查询接口：RecipeManager 这类脚本里用的就是这个
static func is_paused() -> bool:
	return GameTimeManager._paused_flag
