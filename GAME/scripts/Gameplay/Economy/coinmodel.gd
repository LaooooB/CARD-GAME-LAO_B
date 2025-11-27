extends Node
class_name CoinModel

## —— 信号 —— 
signal coin_changed(new_balance: int, delta: int)

## —— 可在 Inspector 里设置初始金币 —— 
@export var start_coin: int = 0

## —— 运行时金币 —— 
var coin: int = 0

func _ready() -> void:
	coin = max(0, start_coin)
	# 首次广播（便于 UI 初次刷新）
	emit_signal("coin_changed", coin, 0)

## 增加金币（允许 amount 为正负；结果不小于 0）
func add(amount: int) -> void:
	if amount == 0:
		return
	var old := coin
	coin = max(0, old + amount)
	var delta := coin - old
	if delta != 0:
		emit_signal("coin_changed", coin, delta)

## 直接设置金币（结果不小于 0）
func set_amount(amount: int) -> void:
	var old := coin
	coin = max(0, amount)
	var delta := coin - old
	if delta != 0:
		emit_signal("coin_changed", coin, delta)

## 读取当前金币
func get_amount() -> int:
	return coin
