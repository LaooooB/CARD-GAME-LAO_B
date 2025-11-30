extends Label
class_name FloatingMenuLabel

@export_range(0.0, 50.0, 0.5) var amplitude_min: float = 1.0
@export_range(0.0, 50.0, 0.5) var amplitude_max: float = 4.0

@export_range(0.1, 10.0, 0.1) var speed_min: float = 0.8
@export_range(0.1, 10.0, 0.1) var speed_max: float = 1.6

# 随机种子（0 = 每次运行都不一样）
@export var random_seed: int = 0

# 每个字母的数据：
# {
#   "char": String,
#   "x": float,
#   "base_y": float,
#   "amp": float,
#   "speed": float,
#   "phase": float
# }
var _chars: Array[Dictionary] = []
var _source_text: String = ""
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

func _ready() -> void:
	# 用原本 Label 的 text 内容
	_source_text = text
	
	# 清掉 Label 自带的绘制，之后我们自己画
	text = ""
	
	if random_seed != 0:
		_rng.seed = random_seed
	else:
		_rng.randomize()
	
	_rebuild_chars()
	set_process(true)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		# Label 尺寸变化时，重算布局
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
	
	var font_size: int = get_theme_font_size("font_size")
	
	for entry in _chars:
		var ch: String = entry["char"]
		var x: float = entry["x"]
		var base_y: float = entry["base_y"]
		var amp: float = entry["amp"]
		var phase: float = entry["phase"]
		
		var y_offset: float = sin(phase) * amp
		var pos: Vector2 = Vector2(x, base_y + y_offset)
		
		draw_string(
			font,
			pos,
			ch,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			font_size
		)

func _rebuild_chars() -> void:
	_chars.clear()
	
	if _source_text.is_empty():
		return
	
	var font: Font = get_theme_font("font")
	if font == null:
		return
	
	var font_size: int = get_theme_font_size("font_size")
	
	# 计算整行文字宽度，用于对齐
	var total_size: Vector2 = font.get_string_size(
		_source_text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		font_size
	)
	var total_width: float = total_size.x
	
	var base_x: float = 0.0
	match horizontal_alignment:
		HORIZONTAL_ALIGNMENT_CENTER:
			base_x = (size.x - total_width) * 0.5
		HORIZONTAL_ALIGNMENT_RIGHT:
			base_x = size.x - total_width
		HORIZONTAL_ALIGNMENT_FILL:
			base_x = 0.0 # 简单处理，当左对齐用
		_:
			base_x = 0.0
	
	# 垂直对齐
	var font_height: float = font.get_height(font_size)
	var ascent: float = font.get_ascent(font_size)
	var base_y: float = ascent
	
	match vertical_alignment:
		VERTICAL_ALIGNMENT_CENTER:
			base_y = (size.y - font_height) * 0.5 + ascent
		VERTICAL_ALIGNMENT_BOTTOM:
			base_y = size.y - font_height + ascent
		_: # TOP 或默认
			base_y = ascent
	
	# 为每个字符创建一个“轨道”
	var length: int = _source_text.length()
	for i in length:
		var ch: String = _source_text.substr(i, 1)
		if ch == "\n":
			# 这里先不支持多行，有需要再扩
			continue
		
		var prefix: String = _source_text.substr(0, i)
		var prefix_width: float = 0.0
		if not prefix.is_empty():
			prefix_width = font.get_string_size(
				prefix,
				HORIZONTAL_ALIGNMENT_LEFT,
				-1.0,
				font_size
			).x
		
		var char_x: float = base_x + prefix_width
		
		var amp: float = _rng.randf_range(amplitude_min, amplitude_max)
		var speed: float = _rng.randf_range(speed_min, speed_max)
		var phase: float = _rng.randf_range(0.0, TAU)
		
		var entry: Dictionary = {
			"char": ch,
			"x": char_x,
			"base_y": base_y,
			"amp": amp,
			"speed": speed,
			"phase": phase
		}
		_chars.append(entry)
