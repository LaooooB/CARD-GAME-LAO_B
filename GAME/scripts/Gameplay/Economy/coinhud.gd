extends Label
class_name CoinHUD

## —— 绑定你的 CoinModel 节点（非 Autoload）——
@export var coin_model_path: NodePath

## —— 显示格式 —— 
@export var use_thousands: bool = true  # 是否用 1,234 风格

var _coin_model: Node = null


func _ready() -> void:
	# 1) 优先用导出的路径拿 CoinModel
	if coin_model_path != NodePath(""):
		_coin_model = get_node_or_null(coin_model_path)

	# 初次刷新与订阅
	if _coin_model != null and _coin_model.has_method("get_amount"):
		_update_text(int(_coin_model.call("get_amount")))
	if _coin_model != null and _coin_model.has_signal("coin_changed"):
		_coin_model.connect("coin_changed", Callable(self, "_on_coin_changed"))


func _on_coin_changed(new_balance: int, _delta: int) -> void:
	_update_text(new_balance)



func _update_text(v: int) -> void:
	text = _fmt_thousands(v) if use_thousands else str(v)


func _fmt_thousands(n: int) -> String:
	var s := str(abs(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3, 3) + out
		s = s.substr(0, s.length() - 3)
	out = s + out
	return ("-" if n < 0 else "") + out
