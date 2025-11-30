extends Control
class_name SettingsTabsManager

# 左侧按钮（顺序要和右侧面板一一对应）
@export var buttons: Array[Button] = []

# 右侧面板（建议都是 PanelContainer）
@export var panels: Array[PanelContainer] = []

# 默认打开第几个（从 0 开始）
@export_range(0, 32, 1) var default_index: int = 0

# 切换动画参数（只给“目标 panel”做动画）
@export_range(0.0, 2.0, 0.05) var tween_duration: float = 0.35
@export var tween_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var tween_ease: Tween.EaseType = Tween.EASE_OUT

# 动画起始缩放（相对于原始 scale 的倍数）
@export var start_scale: Vector2 = Vector2(0.95, 1.05)

var _current_index: int = -1
var _current_tween: Tween

var _panel_base_scales: Array[Vector2] = []


func _ready() -> void:
	var count_buttons: int = buttons.size()
	var count_panels: int = panels.size()
	
	if count_buttons == 0 or count_panels == 0:
		push_error("[SettingsTabsManager] buttons / panels 为空，请在 Inspector 里拖拽引用。")
		return
	
	if count_buttons != count_panels:
		push_error("[SettingsTabsManager] 按钮数量与面板数量不一致，会导致索引错位。已按较小值裁剪。")
		var min_count: int = min(count_buttons, count_panels)
		buttons.resize(min_count)
		panels.resize(min_count)
	
	_panel_base_scales.clear()
	_panel_base_scales.resize(panels.size())
	
	# 绑定按钮点击事件
	for i in buttons.size():
		var btn: Button = buttons[i]
		if btn == null:
			continue
		
		var index: int = i
		btn.pressed.connect(func() -> void:
			_switch_to(index))
	
	# 初始化所有面板：记录原始 scale，全部隐藏 & alpha=0
	for i in panels.size():
		var panel: PanelContainer = panels[i]
		if panel == null:
			_panel_base_scales[i] = Vector2.ONE
			continue
		
		_panel_base_scales[i] = panel.scale
		
		panel.visible = false
		var c: Color = panel.modulate
		c.a = 0.0
		panel.modulate = c
	
	_switch_to(default_index)


func _switch_to(index: int) -> void:
	if panels.is_empty():
		return
	
	var idx: int = clamp(index, 0, panels.size() - 1)
	if idx == _current_index and _current_tween == null:
		return
	
	# 干掉旧 tween，防止残留
	if _current_tween != null and is_instance_valid(_current_tween):
		_current_tween.kill()
	_current_tween = null
	
	# 先把所有非目标 panel 立即关掉（避免任何闪烁）
	for i in panels.size():
		var panel: PanelContainer = panels[i]
		if panel == null:
			continue
		
		if i != idx:
			panel.visible = false
			var c_hide: Color = panel.modulate
			c_hide.a = 0.0
			panel.modulate = c_hide
			# 确保 scale 回到原始值
			if i < _panel_base_scales.size():
				panel.scale = _panel_base_scales[i]
	
	var target: PanelContainer = panels[idx]
	if target == null:
		_current_index = idx
		return
	
	_current_index = idx
	
	# 目标 panel 初始状态：可见 + alpha=0 + 略微缩放
	target.visible = true
	
	var base_scale: Vector2 = Vector2.ONE
	if idx < _panel_base_scales.size():
		base_scale = _panel_base_scales[idx]
	
	target.scale = Vector2(base_scale.x * start_scale.x, base_scale.y * start_scale.y)
	
	var c_show: Color = target.modulate
	c_show.a = 0.0
	target.modulate = c_show
	
	# 没动画时长就直接显示
	if tween_duration <= 0.0:
		target.scale = base_scale
		c_show.a = 1.0
		target.modulate = c_show
		return
	
	# 创建 tween：缩放回原始 scale + 淡入
	var tween: Tween = create_tween()
	tween.set_trans(tween_trans)
	tween.set_ease(tween_ease)
	
	tween.parallel().tween_property(
		target,
		"scale",
		base_scale,
		tween_duration
	)
	tween.parallel().tween_property(
		target,
		"modulate:a",
		1.0,
		tween_duration
	)
	
	_current_tween = tween
	tween.finished.connect(func() -> void:
		_current_tween = null)
