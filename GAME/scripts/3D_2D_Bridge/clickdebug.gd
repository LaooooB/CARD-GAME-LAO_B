extends Node2D
class_name ClickDebugRelay

# ====== Inspector 可调 ======
@export var show_hud_counter: bool = true
@export var show_toast: bool = true
@export var log_events: bool = true
@export var toast_duration: float = 0.9
@export var probe_on_down: bool = true   # 点下时做一次空间探针

# 内部节点
var _hud_label: Label = null
var _toast_panel: Panel = null
var _toast_label: Label = null

# 计数 / 最近一次桥侧 click_id
var _recv_count: int = 0
var _last_bridge_click_id: int = 0

func _ready() -> void:
	if show_hud_counter:
		_make_hud()
	if show_toast:
		_make_toast()
	set_process_unhandled_input(true)
	set_process_input(true)

# 供 Card 同步 click_id 使用
func get_last_bridge_click_id() -> int:
	return _last_bridge_click_id

# 1) 直接监听 SubViewport 内部的输入（证明“桥→2D 收到”）
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var e: InputEventMouseButton = event as InputEventMouseButton
		if e.button_index == MOUSE_BUTTON_LEFT:
			if e.pressed:
				_on_received_native("DOWN", e.position)
				if probe_on_down:
					_probe_point(e.position)
			else:
				_on_received_native("UP", e.position)

func _on_received_native(kind: String, pos: Vector2) -> void:
	_recv_count += int(kind == "DOWN")
	if log_events:
		print("[2D-ROOT] RECEIVED_NATIVE kind=%s pos=(%.1f,%.1f) count=%d" % [kind, pos.x, pos.y, _recv_count])
	_update_hud()

# 2) 供桥调用的回调（带 click_id，用来打通“统一ID”链路）
func notify_bridge_click_down(click_id: int, px: Vector2) -> void:
	_last_bridge_click_id = click_id
	if log_events:
		print("[2D-ROOT] BRIDGE_DOWN id=%d pos=(%.1f,%.1f)" % [click_id, px.x, px.y])
	_pulse_hud()
	_show_toast("DOWN id=%d" % click_id)

func notify_bridge_click_up(click_id: int, px: Vector2) -> void:
	if log_events:
		print("[2D-ROOT] BRIDGE_UP   id=%d pos=(%.1f,%.1f)" % [click_id, px.x, px.y])
	_show_toast("UP   id=%d" % click_id)

# 3) 提供给卡牌用的“点击完成”显示（Card.gd 会调用）
func notify_card_clicked(card_name: String, click_id: int) -> void:
	if log_events:
		print("[2D-ROOT] CLICKED card=%s id=%d" % [card_name, click_id])
	_show_toast("CLICK %s" % card_name)

# ===== 空间探针：列出当前点下命中的 Area2D，帮助确认是否命中到卡 =====
func _probe_point(pos: Vector2) -> void:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var q: PhysicsPointQueryParameters2D = PhysicsPointQueryParameters2D.new()
	q.position = pos
	q.collide_with_areas = true
	q.collide_with_bodies = false


	var hits: Array[Dictionary] = space.intersect_point(q)
	if hits.is_empty():
		print("[2D-ROOT] PROBE @", pos, " -> <none>")
		return

	print("[2D-ROOT] PROBE @", pos, " -> ", hits.size(), " hits")
	for h in hits:
		var collider: Area2D = h.get("collider") as Area2D
		var cid: int = int(h.get("collider_id"))
		var cname: String = collider.name if collider != null else "<null>"
		print("  - Area2D:", cname, "  id=", cid, "  class=", (collider.get_class() if collider != null else "<null>"))

# ===== HUD / Toast 视图 =====
func _make_hud() -> void:
	var l: Label = Label.new()
	l.text = "2D Clicks: 0"
	l.position = Vector2(10, 10)
	l.add_theme_color_override("font_color", Color(1, 1, 0.8))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.name = "DebugHudLabel"
	add_child(l)
	_hud_label = l

func _update_hud() -> void:
	if _hud_label:
		_hud_label.text = "2D Clicks: %d" % _recv_count

func _pulse_hud() -> void:
	if _hud_label:
		var tw := _hud_label.create_tween()
		tw.tween_property(_hud_label, "scale", Vector2(1.1, 1.1), 0.08)
		tw.tween_property(_hud_label, "scale", Vector2.ONE, 0.12)

func _make_toast() -> void:
	var panel: Panel = Panel.new()
	panel.modulate = Color(0, 0, 0, 0.0)
	panel.size = Vector2(280, 40)
	panel.position = Vector2(20, 50)
	panel.name = "DebugToast"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 重要：不吃鼠标
	add_child(panel)
	_toast_panel = panel

	var lbl: Label = Label.new()
	lbl.text = ""
	lbl.position = Vector2(10, 10)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lbl)
	_toast_label = lbl

func _show_toast(text: String) -> void:
	if not show_toast or _toast_panel == null or _toast_label == null:
		return
	_toast_label.text = text
	_toast_panel.modulate = Color(0, 0, 0, 0.0)
	var tw := _toast_panel.create_tween()
	tw.tween_property(_toast_panel, "modulate", Color(0, 0, 0, 0.65), 0.08)
	tw.tween_interval(toast_duration)
	tw.tween_property(_toast_panel, "modulate", Color(0, 0, 0, 0.0), 0.12)
