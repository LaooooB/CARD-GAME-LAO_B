# main_enter_tween.gd
extends Node2D

# —— 淡入参数（可在 Inspector 调）——
@export var fade_in_duration: float = 0.6
@export var fade_in_color: Color = Color(0, 0, 0, 1.0)
@export var fade_in_trans: Tween.TransitionType = Tween.TRANS_QUAD
@export var fade_in_ease: Tween.EaseType = Tween.EASE_OUT
@export var layer_index: int = 100   # 盖在几乎所有 CanvasLayer 之上


func _ready() -> void:
	# 等一帧，确保场景树和 Viewport 都准备好
	call_deferred("_start_scene_fade_in")


func _start_scene_fade_in() -> void:
	if fade_in_duration <= 0.0:
		return

	var root := get_tree().root
	if root == null:
		return

	# —— 创建一个单独的 CanvasLayer，保证在最上层 —— 
	var fade_layer := CanvasLayer.new()
	fade_layer.layer = layer_index
	root.add_child(fade_layer)

	# —— 创建 1x1 白色纹理，用 Sprite2D 拉伸铺满屏幕 —— 
	var img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	var tex := ImageTexture.create_from_image(img)

	var sprite := Sprite2D.new()
	sprite.texture = tex
	sprite.centered = false
	sprite.position = Vector2.ZERO
	sprite.modulate = fade_in_color

	# 计算当前可见区域大小，并按这个大小缩放
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	sprite.scale = vp_size

	fade_layer.add_child(sprite)

	# —— Tween：从不透明 → 透明（淡入场景） —— 
	var tw := create_tween()
	tw.set_trans(fade_in_trans)
	tw.set_ease(fade_in_ease)
	tw.tween_property(sprite, "modulate:a", 0.0, fade_in_duration).from(sprite.modulate.a)
	tw.finished.connect(func () -> void:
		fade_layer.queue_free()
	)
