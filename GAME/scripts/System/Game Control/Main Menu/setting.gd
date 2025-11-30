extends Button

# =========================
# —— 字母蠕动参数 —— 
# =========================
@export_range(0.0, 50.0, 0.5) var amplitude_min: float = 1.0
@export_range(0.0, 50.0, 0.5) var amplitude_max: float = 4.0

@export_range(0.1, 10.0, 0.1) var speed_min: float = 0.8
@export_range(0.1, 10.0, 0.1) var speed_max: float = 1.6

# 随机种子（0 = 每次运行都不一样）
@export var random_seed: int = 0

# 对齐方式（自己导出，不用 Button 自带的）
@export var align_h: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT
@export var align_v: VerticalAlignment = VERTICAL_ALIGNMENT_CENTER

# ========== Hover 缩放设置（字号 Tween） ==========
@export_range(0.1, 3.0, 0.01) var hover_scale: float = 1.10
@export_range(0.01, 2.0, 0.01) var hover_tween_time: float = 0.18
@export var hover_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var hover_ease: Tween.EaseType = Tween.EASE_OUT

# ========== Hover 变色（可在 Inspector 调整） ==========
@export var normal_color: Color = Color(1.0, 1.0, 1.0, 1.0)
@export var hover_color: Color = Color(1.0, 0.96, 0.85, 1.0)
@export_range(0.01, 2.0, 0.01) var color_tween_time: float = 0.20

var _current_scale: float = 1.0
var _scale_tween: Tween
var _current_color: Color = Color(1.0, 1.0, 1.0, 1.0)
var _color_tween: Tween

# =========================
# —— Setting 抽屉相关 —— 
# =========================

# 你的 Setting 场景（单独的 .tscn）
@export var settings_scene: PackedScene

enum SlideSide { LEFT, RIGHT }
@export var settings_slide_side: SlideSide = SlideSide.RIGHT

@export_range(0.05, 3.0, 0.01) var settings_slide_duration: float = 0.3
@export var settings_slide_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var settings_slide_ease: Tween.EaseType = Tween.EASE_OUT

# 左侧 dim / blur 强度
@export_range(0.0, 1.0, 0.01) var settings_dim_alpha: float = 0.55
@export_range(0.0, 1.0, 0.01) var settings_blur_max: float = 0.4

# 🎯 新增：右侧 dim / blur 强度（默认比左边淡）
@export_range(0.0, 1.0, 0.01) var settings_right_dim_alpha: float = 0.25
@export_range(0.0, 1.0, 0.01) var settings_right_blur_max: float = 0.2

# 左侧区域宽度比例（0.27）
@export_range(0.1, 1.0, 0.01) var settings_effect_width_ratio: float = 0.26

var _settings_panel: Control = null

# 左侧下半区（强效果）
var _settings_dimmer: ColorRect = null
var _settings_blur: ColorRect = null

# 左侧上半区（淡效果，用右侧参数）
var _settings_dimmer_left_top: ColorRect = null
var _settings_blur_left_top: ColorRect = null

# 右侧（淡效果）
var _settings_dimmer_right: ColorRect = null
var _settings_blur_right: ColorRect = null

var _settings_open: bool = false
var _settings_tween: Tween = null
var _panel_open_pos: Vector2 = Vector2.ZERO
var _panel_closed_pos: Vector2 = Vector2.ZERO

# Shader 资源，从 Inspector 指定（避免写死路径）
@export var blur_shader_res: Shader

# =========================
# —— 文本数据 —— 
# =========================

var _chars: Array[Dictionary] = []
var _source_text: String = ""
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _text_rect: Rect2 = Rect2()
var _text_center: Vector2 = Vector2.ZERO

var _base_font_size: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_unhandled_input(true)

	_source_text = text
	text = ""
	
	_flatten_button_visual()
	
	_base_font_size = get_theme_font_size("font_size")
	
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	pressed.connect(_on_pressed)
	
	if random_seed != 0:
		_rng.seed = random_seed
	else:
		_rng.randomize()
	
	_rebuild_chars()
	set_process(true)
	custom_minimum_size = _get_minimum_size()
	update_minimum_size()

	_current_color = normal_color


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_rebuild_chars()

func _process(delta: float) -> void:
	for entry in _chars:
		var speed: float = entry["speed"]
		entry["phase"] += delta * speed
	queue_redraw()

func _draw() -> void:
	var font: Font = get_theme_font("font")
	if font == null:
		return
	
	var base_font_size: int = _base_font_size
	if base_font_size <= 0:
		base_font_size = get_theme_font_size("font_size")
	
	var scaled_font_size: int = int(round(float(base_font_size) * _current_scale))
	if scaled_font_size < 1:
		scaled_font_size = 1
	
	var total_width_scaled: float = 0.0
	if not _source_text.is_empty():
		total_width_scaled = font.get_string_size(
			_source_text,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			scaled_font_size
		).x
	
	var center_y: float = _text_center.y
	var height_scaled: float = font.get_height(scaled_font_size)
	var ascent_scaled: float = font.get_ascent(scaled_font_size)
	var base_y_scaled: float = center_y - height_scaled * 0.5 + ascent_scaled
	
	var base_x_scaled: float = 0.0
	
	if total_width_scaled <= 0.0:
		base_x_scaled = _text_rect.position.x
	else:
		match align_h:
			HORIZONTAL_ALIGNMENT_LEFT:
				base_x_scaled = _text_rect.position.x
			HORIZONTAL_ALIGNMENT_RIGHT:
				base_x_scaled = _text_rect.position.x + _text_rect.size.x - total_width_scaled
			HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_FILL:
				var center_x: float = _text_center.x
				base_x_scaled = center_x - total_width_scaled * 0.5
			_:
				base_x_scaled = _text_rect.position.x
	
	var run_x: float = 0.0
	
	for i in _chars.size():
		var entry = _chars[i]
		var ch: String = entry["char"]
		var amp: float = entry["amp"]
		var phase: float = entry["phase"]
		
		var x: float = base_x_scaled + run_x
		var y_offset: float = sin(phase) * amp
		var pos: Vector2 = Vector2(x, base_y_scaled + y_offset)
		
		draw_string(
			font,
			pos,
			ch,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			scaled_font_size,
			_current_color
		)
		
		var char_width: float = 0.0
		if ch != "":
			char_width = font.get_string_size(
				ch,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1.0,
				scaled_font_size
			).x
		run_x += char_width

func _rebuild_chars() -> void:
	_chars.clear()
	_text_rect = Rect2()
	_text_center = Vector2.ZERO
	
	if _source_text.is_empty():
		return
	
	var font: Font = get_theme_font("font")
	if font == null:
		return
	
	var font_size: int = get_theme_font_size("font_size")
	_base_font_size = font_size
	
	var total_size: Vector2 = font.get_string_size(
		_source_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size
	)
	var total_width: float = total_size.x
	
	var base_x: float = 0.0
	match align_h:
		HORIZONTAL_ALIGNMENT_CENTER:
			base_x = (size.x - total_width) * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			base_x = size.x - total_width
		HORIZONTAL_ALIGNMENT_FILL:
			base_x = 0.0
		_:
			base_x = 0.0
	
	var font_height: float = font.get_height(font_size)
	var ascent: float = font.get_ascent(font_size)
	var base_y: float = ascent
	
	match align_v:
		VERTICAL_ALIGNMENT_CENTER:
			base_y = (size.y - font_height) * 0.5 + ascent
		VERTICAL_ALIGNMENT_BOTTOM:
			base_y = size.y - font_height + ascent
		_:
			base_y = ascent
	
	var top_y: float = base_y - ascent
	_text_rect = Rect2(
		Vector2(base_x, top_y),
		Vector2(total_width, font_height)
	)
	_text_center = _text_rect.position + _text_rect.size * 0.5
	
	var length: int = _source_text.length()
	for i in length:
		var ch: String = _source_text.substr(i, 1)
		if ch == "\n":
			continue
		
		var amp: float = _rng.randf_range(amplitude_min, amplitude_max)
		var speed: float = _rng.randf_range(speed_min, speed_max)
		var phase: float = _rng.randf_range(0.0, TAU)
		
		var entry: Dictionary = {
			"char": ch,
			"amp": amp,
			"speed": speed,
			"phase": phase
		}
		_chars.append(entry)
	
	custom_minimum_size = _get_minimum_size()
	update_minimum_size()

func _has_point(point: Vector2) -> bool:
	if _text_rect.size == Vector2.ZERO:
		return Rect2(Vector2.ZERO, size).has_point(point)
	return _text_rect.has_point(point)

# ========== Hover Tween ==========
func _on_mouse_entered() -> void:
	_start_scale_tween(hover_scale)
	_start_color_tween(hover_color)

func _on_mouse_exited() -> void:
	_start_scale_tween(1.0)
	_start_color_tween(normal_color)



func _start_scale_tween(target: float) -> void:
	if _scale_tween != null and _scale_tween.is_valid():
		_scale_tween.kill()
	
	_scale_tween = create_tween()
	_scale_tween.set_trans(hover_trans)
	_scale_tween.set_ease(hover_ease)
	_scale_tween.tween_property(self, "_current_scale", target, hover_tween_time)

func _start_color_tween(target: Color) -> void:
	if _color_tween != null and _color_tween.is_valid():
		_color_tween.kill()
	
	_color_tween = create_tween()
	_color_tween.set_trans(hover_trans)
	_color_tween.set_ease(hover_ease)
	_color_tween.tween_property(self, "_current_color", target, color_tween_time)
# ========== 去掉 Button 背景/hover/聚焦 ==========

func _flatten_button_visual() -> void:
	focus_mode = Control.FOCUS_NONE
	
	var empty := StyleBoxEmpty.new()
	add_theme_stylebox_override("normal", empty)
	add_theme_stylebox_override("hover", empty)
	add_theme_stylebox_override("pressed", empty)
	add_theme_stylebox_override("disabled", empty)
	add_theme_stylebox_override("focus", empty)
	
	flat = true

# =========================
#  告诉 VBoxContainer：这个按钮至少要这么大
# =========================
func _get_minimum_size() -> Vector2:
	var font: Font = get_theme_font("font")
	if font == null or _source_text.is_empty():
		return Vector2(0, 24)
	
	var font_size: int = _base_font_size
	if font_size <= 0:
		font_size = get_theme_font_size("font_size")
	
	var text_size: Vector2 = font.get_string_size(
		_source_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size
	)
	var height: float = font.get_height(font_size)
	
	var pad_x: float = 8.0
	var pad_y: float = 4.0
	
	return Vector2(
		text_size.x + pad_x * 2.0,
		height + pad_y * 2.0
	)

# =========================
#  Setting 抽屉：载入 & 动画
# =========================
func _ensure_settings_instance() -> void:
	if _settings_panel != null and is_instance_valid(_settings_panel):
		return
	
	if settings_scene == null:
		push_error("[SettingsButton] settings_scene 没有在 Inspector 里赋值")
		return
	
	var root := get_tree().current_scene as Control
	if root == null:
		push_error("[SettingsButton] current_scene 不是 Control，无法作为 UI 根")
		return
	
	var viewport_size: Vector2 = root.get_viewport_rect().size
	var left_width: float = viewport_size.x * settings_effect_width_ratio
	var right_width: float = max(viewport_size.x - left_width, 0.0)
	
	# —— 左侧 Blur：左侧 + 下半屏 —— 
	_settings_blur = ColorRect.new()
	_settings_blur.color = Color(1, 1, 1, 1)
	_settings_blur.anchor_left = 0.0
	_settings_blur.anchor_top = 0.5     # 下半屏开始
	_settings_blur.anchor_right = 0.0
	_settings_blur.anchor_bottom = 1.0   # 底部
	_settings_blur.offset_left = 0.0
	_settings_blur.offset_top = 0.0
	_settings_blur.offset_right = left_width
	_settings_blur.offset_bottom = 0.0
	_settings_blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings_blur.visible = false
	root.add_child(_settings_blur)
	
	var blur_shader: Shader = blur_shader_res
	if blur_shader == null:
		push_error("[SettingsButton] blur_shader_res 没有在 Inspector 里赋值")
	else:
		var blur_mat := ShaderMaterial.new()
		blur_mat.shader = blur_shader
		blur_mat.set_shader_parameter("blur_amount", 0.0)
		_settings_blur.material = blur_mat
	
	# —— 左侧 Dim：左侧 + 下半屏 —— 
	_settings_dimmer = ColorRect.new()
	_settings_dimmer.color = Color(0, 0, 0, 0.0)
	_settings_dimmer.anchor_left = 0.0
	_settings_dimmer.anchor_top = 0.5      # 下半屏开始
	_settings_dimmer.anchor_right = 0.0
	_settings_dimmer.anchor_bottom = 1.0   # 底部
	_settings_dimmer.offset_left = 0.0
	_settings_dimmer.offset_top = 0.0
	_settings_dimmer.offset_right = left_width
	_settings_dimmer.offset_bottom = 0.0
	_settings_dimmer.mouse_filter = Control.MOUSE_FILTER_STOP
	_settings_dimmer.visible = false
	root.add_child(_settings_dimmer)
	_settings_dimmer.gui_input.connect(_on_dimmer_gui_input)
	
	# —— 左上 Blur（淡，用右侧参数） —— 
	_settings_blur_left_top = ColorRect.new()
	_settings_blur_left_top.color = Color(1, 1, 1, 1)
	_settings_blur_left_top.anchor_left = 0.0
	_settings_blur_left_top.anchor_top = 0.0
	_settings_blur_left_top.anchor_right = 0.0
	_settings_blur_left_top.anchor_bottom = 0.5
	_settings_blur_left_top.offset_left = 0.0
	_settings_blur_left_top.offset_top = 0.0
	_settings_blur_left_top.offset_right = left_width
	_settings_blur_left_top.offset_bottom = 0.0
	_settings_blur_left_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_settings_blur_left_top.visible = false
	root.add_child(_settings_blur_left_top)
	
	if blur_shader != null:
		var blur_mat_lt := ShaderMaterial.new()
		blur_mat_lt.shader = blur_shader
		blur_mat_lt.set_shader_parameter("blur_amount", 0.0)
		_settings_blur_left_top.material = blur_mat_lt
	
	# —— 左上 Dim（淡，用右侧参数） —— 
	_settings_dimmer_left_top = ColorRect.new()
	_settings_dimmer_left_top.color = Color(0, 0, 0, 0.0)
	_settings_dimmer_left_top.anchor_left = 0.0
	_settings_dimmer_left_top.anchor_top = 0.0
	_settings_dimmer_left_top.anchor_right = 0.0
	_settings_dimmer_left_top.anchor_bottom = 0.5
	_settings_dimmer_left_top.offset_left = 0.0
	_settings_dimmer_left_top.offset_top = 0.0
	_settings_dimmer_left_top.offset_right = left_width
	_settings_dimmer_left_top.offset_bottom = 0.0
	_settings_dimmer_left_top.mouse_filter = Control.MOUSE_FILTER_STOP
	_settings_dimmer_left_top.visible = false
	root.add_child(_settings_dimmer_left_top)
	_settings_dimmer_left_top.gui_input.connect(_on_dimmer_gui_input)
	
	# —— 右侧 Blur / Dim（覆盖剩余区域，全高） —— 
	if right_width > 0.0:
		_settings_blur_right = ColorRect.new()
		_settings_blur_right.color = Color(1, 1, 1, 1)
		_settings_blur_right.anchor_left = 0.0
		_settings_blur_right.anchor_top = 0.0
		_settings_blur_right.anchor_right = 1.0
		_settings_blur_right.anchor_bottom = 1.0
		_settings_blur_right.offset_left = left_width
		_settings_blur_right.offset_top = 0.0
		_settings_blur_right.offset_right = 0.0
		_settings_blur_right.offset_bottom = 0.0
		_settings_blur_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_settings_blur_right.visible = false
		root.add_child(_settings_blur_right)
		
		if blur_shader != null:
			var blur_mat_r := ShaderMaterial.new()
			blur_mat_r.shader = blur_shader
			blur_mat_r.set_shader_parameter("blur_amount", 0.0)
			_settings_blur_right.material = blur_mat_r
		
		_settings_dimmer_right = ColorRect.new()
		_settings_dimmer_right.color = Color(0, 0, 0, 0.0)
		_settings_dimmer_right.anchor_left = 0.0
		_settings_dimmer_right.anchor_top = 0.0
		_settings_dimmer_right.anchor_right = 1.0
		_settings_dimmer_right.anchor_bottom = 1.0
		_settings_dimmer_right.offset_left = left_width
		_settings_dimmer_right.offset_top = 0.0
		_settings_dimmer_right.offset_right = 0.0
		_settings_dimmer_right.offset_bottom = 0.0
		_settings_dimmer_right.mouse_filter = Control.MOUSE_FILTER_STOP
		_settings_dimmer_right.visible = false
		root.add_child(_settings_dimmer_right)
		_settings_dimmer_right.gui_input.connect(_on_dimmer_gui_input)
	
	# —— 实例化 Setting 场景 —— 
	var inst := settings_scene.instantiate()
	_settings_panel = inst as Control
	if _settings_panel == null:
		push_error("[SettingsButton] settings_scene 根节点不是 Control，建议改成 Control")
		root.remove_child(inst)
		inst.queue_free()
		return
	
	root.add_child(_settings_panel)
	
	_settings_panel.modulate = Color(1, 1, 1, 0.0)
	
	_panel_open_pos = _settings_panel.position
	
	var panel_size: Vector2 = _settings_panel.size
	var closed_y: float = _panel_open_pos.y
	
	match settings_slide_side:
		SlideSide.RIGHT:
			_panel_closed_pos = Vector2(viewport_size.x, closed_y)
		SlideSide.LEFT:
			_panel_closed_pos = Vector2(-panel_size.x, closed_y)
	
	_settings_panel.position = _panel_closed_pos
	_settings_panel.visible = false

func _on_pressed() -> void:
	if _settings_open:
		_close_settings()
	else:
		_open_settings()

func _open_settings() -> void:
	_ensure_settings_instance()
	if _settings_panel == null or _settings_dimmer == null:
		return
	if _settings_open:
		return
	
	_settings_open = true
	
	if _settings_blur != null:
		_settings_blur.visible = true
	if _settings_blur_left_top != null:
		_settings_blur_left_top.visible = true
	if _settings_blur_right != null:
		_settings_blur_right.visible = true
	
	_settings_dimmer.visible = true
	if _settings_dimmer_left_top != null:
		_settings_dimmer_left_top.visible = true
	if _settings_dimmer_right != null:
		_settings_dimmer_right.visible = true
	
	_settings_panel.visible = true
	
	_play_settings_tween(true)

func _close_settings() -> void:
	if not _settings_open:
		return
	
	_settings_open = false
	_play_settings_tween(false)

# —— 统一的开关动画接口 —— 
func _play_settings_tween(is_opening: bool) -> void:
	if _settings_panel == null or _settings_dimmer == null:
		return
	
	if _settings_tween != null and _settings_tween.is_valid():
		_settings_tween.kill()
	
	_settings_tween = create_tween()
	_settings_tween.set_trans(settings_slide_trans)
	_settings_tween.set_ease(settings_slide_ease)
	
	var dim_to_left: float
	var dim_to_right_like: float = 0.0   # 左上 + 右侧 用这一档
	var pos_to: Vector2
	var mod_to: float
	var blur_from_left: float
	var blur_to_left: float
	var blur_from_right_like: float = 0.0
	var blur_to_right_like: float = 0.0
	
	if is_opening:
		dim_to_left = settings_dim_alpha
		dim_to_right_like = settings_right_dim_alpha
		
		pos_to = _panel_open_pos
		mod_to = 1.0
		
		blur_from_left = 0.0
		blur_to_left = settings_blur_max
		blur_from_right_like = 0.0
		blur_to_right_like = settings_right_blur_max
		
		_settings_dimmer.color.a = 0.0
		if _settings_dimmer_left_top != null:
			_settings_dimmer_left_top.color.a = 0.0
		if _settings_dimmer_right != null:
			_settings_dimmer_right.color.a = 0.0
		
		_settings_panel.position = _panel_closed_pos
		_settings_panel.modulate.a = 0.0
		_set_blur_amount(0.0)
		_set_blur_amount_right(0.0)
	else:
		dim_to_left = 0.0
		dim_to_right_like = 0.0
		
		pos_to = _panel_closed_pos
		mod_to = 0.0
		
		blur_from_left = settings_blur_max
		blur_to_left = 0.0
		blur_from_right_like = settings_right_blur_max
		blur_to_right_like = 0.0
	
	# 左下黑幕（强）
	_settings_tween.tween_property(
		_settings_dimmer,
		"color:a",
		dim_to_left,
		settings_slide_duration
	)
	
	# 左上 + 右侧黑幕（淡）
	if _settings_dimmer_left_top != null:
		_settings_tween.parallel().tween_property(
			_settings_dimmer_left_top,
			"color:a",
			dim_to_right_like,
			settings_slide_duration
		)
	if _settings_dimmer_right != null:
		_settings_tween.parallel().tween_property(
			_settings_dimmer_right,
			"color:a",
			dim_to_right_like,
			settings_slide_duration
		)
	
	# 面板位置
	_settings_tween.parallel().tween_property(
		_settings_panel,
		"position",
		pos_to,
		settings_slide_duration
	)
	# 面板 alpha
	_settings_tween.parallel().tween_property(
		_settings_panel,
		"modulate:a",
		mod_to,
		settings_slide_duration
	)
	
	# 左下模糊（强）
	if _settings_blur != null and _settings_blur.material is ShaderMaterial:
		_settings_tween.parallel().tween_method(
			_set_blur_amount,
			blur_from_left,
			blur_to_left,
			settings_slide_duration
		)
	# 左上 + 右侧模糊（淡）
	if (_settings_blur_right != null and _settings_blur_right.material is ShaderMaterial) \
		or (_settings_blur_left_top != null and _settings_blur_left_top.material is ShaderMaterial):
		_settings_tween.parallel().tween_method(
			_set_blur_amount_right,
			blur_from_right_like,
			blur_to_right_like,
			settings_slide_duration
		)
	
	_settings_tween.finished.connect(func () -> void:
		if not _settings_open:
			if _settings_dimmer != null:
				_settings_dimmer.visible = false
			if _settings_dimmer_left_top != null:
				_settings_dimmer_left_top.visible = false
			if _settings_dimmer_right != null:
				_settings_dimmer_right.visible = false
			if _settings_blur != null:
				_settings_blur.visible = false
			if _settings_blur_left_top != null:
				_settings_blur_left_top.visible = false
			if _settings_blur_right != null:
				_settings_blur_right.visible = false
			if _settings_panel != null:
				_settings_panel.visible = false
	)

# —— 给 Tween 用的设置 blur 的方法（左侧下半） —— 
func _set_blur_amount(value: float) -> void:
	if _settings_blur == null:
		return
	var mat := _settings_blur.material
	if mat is ShaderMaterial:
		var lod: float = clamp(value, 0.0, 1.0) * 3.0
		(mat as ShaderMaterial).set_shader_parameter("blur_amount", lod)

# —— 给 Tween 用的设置 blur 的方法（右侧 + 左上，淡一点） —— 
func _set_blur_amount_right(value: float) -> void:
	var lod: float = clamp(value, 0.0, 1.0) * 3.0
	
	if _settings_blur_right != null:
		var mat_r := _settings_blur_right.material
		if mat_r is ShaderMaterial:
			(mat_r as ShaderMaterial).set_shader_parameter("blur_amount", lod)
	
	if _settings_blur_left_top != null:
		var mat_lt := _settings_blur_left_top.material
		if mat_lt is ShaderMaterial:
			(mat_lt as ShaderMaterial).set_shader_parameter("blur_amount", lod)

func _on_dimmer_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
		and event.button_index == MOUSE_BUTTON_LEFT \
		and event.pressed:
		_close_settings()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _settings_open:
		_close_settings()
		get_viewport().set_input_as_handled()
