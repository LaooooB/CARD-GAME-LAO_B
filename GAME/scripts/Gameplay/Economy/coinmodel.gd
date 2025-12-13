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


## 增加 / 减少金币（允许 amount 为正负；结果不小于 0）
func add(amount: int) -> void:
	if amount == 0:
		return
	
	var old: int = coin
	var new_amount: int = max(0, old + amount)
	if new_amount == old:
		return
	
	coin = new_amount
	var delta: int = coin - old
	emit_signal("coin_changed", coin, delta)


## 直接设置金币（结果不小于 0）
func set_amount(amount: int) -> void:
	var new_amount: int = max(0, amount)
	if new_amount == coin:
		return
	
	var old: int = coin
	coin = new_amount
	var delta: int = coin - old
	emit_signal("coin_changed", coin, delta)


## 读取当前金币
func get_amount() -> int:
	return coin


## 支付一定金币：
## - cost > 0：尝试扣减，余额不足则返回 false，不修改金币
## - cost == 0：直接返回 true
## - cost < 0：等价于 add(-cost)，总是返回 true
func pay(cost: int) -> bool:
	if cost == 0:
		return true
	
	if cost < 0:
		add(-cost)
		return true
	
	if coin < cost:
		# 余额不足，不动 coin
		return false
	
	var old: int = coin
	coin = old - cost
	var delta: int = coin - old	# 负数
	emit_signal("coin_changed", coin, delta)
	return true
