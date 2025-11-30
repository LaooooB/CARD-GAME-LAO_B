extends Button


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


# 每个字母的数据
# {
#   "char": String,
#   "amp": float,
#   "speed": float,
#   "phase": float
# }
var _chars: Array[Dictionary] = []
var _source_text: String = ""
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# 文字点击区域（本地坐标，基于基础字号）
var _text_rect: Rect2 = Rect2()
var _text_center: Vector2 = Vector2.ZERO

# 记录基础字号
var _base_font_size: int = 0

func _ready() -> void:
	# 用原本 Button 的 text 内容
	_source_text = text
	# 清掉 Button 自带的文字绘制，只保留我们自绘
	text = ""
	
	# 去掉按钮背景 / hover / 聚焦框
	_flatten_button_visual()
	
	# 基础字号
	_base_font_size = get_theme_font_size("font_size")
	
	# hover 信号做缩放
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	
	if random_seed != 0:
		_rng.seed = random_seed
	else:
		_rng.randomize()
	
	_rebuild_chars()
	set_process(true)
	
	# 告诉父容器：我至少要这么大
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
	
	# 当前字号（根据 hover tween 缩放）
	var scaled_font_size: int = int(round(float(base_font_size) * _current_scale))
	if scaled_font_size < 1:
		# 避免极端情况下变 0
		scaled_font_size = 1
	
	# ===== 计算行宽（scaled） =====
	var total_width_scaled: float = 0.0
	if not _source_text.is_empty():
		total_width_scaled = font.get_string_size(
	_source_text,
	HORIZONTAL_ALIGNMENT_LEFT,
	-1.0,
	scaled_font_size
).x

	
	# 垂直方向：始终绕原来的文字中心做居中
	var center_y: float = _text_center.y
	var height_scaled: float = font.get_height(scaled_font_size)
	var ascent_scaled: float = font.get_ascent(scaled_font_size)
	var base_y_scaled: float = center_y - height_scaled * 0.5 + ascent_scaled
	
	# ===== 水平方向：根据对齐方式决定“哪条边”是固定的 =====
	var base_x_scaled: float = 0.0
	
	if total_width_scaled <= 0.0:
		base_x_scaled = _text_rect.position.x
	else:
		match align_h:
			HORIZONTAL_ALIGNMENT_LEFT:
				# 锁定左边界：左边永远在 _text_rect.left，不往左长
				base_x_scaled = _text_rect.position.x
			HORIZONTAL_ALIGNMENT_RIGHT:
				# 锁定右边界：右边永远在 _text_rect.right
				base_x_scaled = _text_rect.position.x + _text_rect.size.x - total_width_scaled
			HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_FILL:
				# 居中：以原先文字中心为轴对称放大
				var center_x: float = _text_center.x
				base_x_scaled = center_x - total_width_scaled * 0.5
			_:
				base_x_scaled = _text_rect.position.x
	
	# 逐字累积 X
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
	
	# 基础字号下的整行宽度
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
	
	# 基础字号下的垂直对齐
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
	
	# 文字整体矩形（用于 hitbox 和中心）
	var top_y: float = base_y - ascent
	_text_rect = Rect2(
		Vector2(base_x, top_y),
		Vector2(total_width, font_height)
	)
	_text_center = _text_rect.position + _text_rect.size * 0.5
	
	# 为每个字符创建一个“轨道”（只存随机参数）
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
	
	# 重建完字符后，更新最小尺寸，触发布局
	custom_minimum_size = _get_minimum_size()
	update_minimum_size()

# 只让文字区域算点击
func _has_point(point: Vector2) -> bool:
	if _text_rect.size == Vector2.ZERO:
		return Rect2(Vector2.ZERO, size).has_point(point)
	return _text_rect.has_point(point)

# ========== Hover Tween（改字号，不动布局中心） ==========
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
	
	var empty = StyleBoxEmpty.new()
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
		# 没字体或没文字时给一个兜底高度，防止变成 0
		return Vector2(0, 24)
	
	var font_size: int = _base_font_size
	if font_size <= 0:
		font_size = get_theme_font_size("font_size")
	
	# 基础字号下的字符串大小
	var text_size: Vector2 = font.get_string_size(
		_source_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size
	)
	var height: float = font.get_height(font_size)
	
	# 预留一点左右 / 上下 padding，不然会太贴边
	var pad_x: float = 8.0
	var pad_y: float = 4.0
	
	return Vector2(
		text_size.x + pad_x * 2.0,
		height + pad_y * 2.0
	)
