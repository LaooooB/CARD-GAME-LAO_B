# scripts/core/CardSpawner.gd
extends Node2D

@export var card_scene: PackedScene
@export var card_textures: Array[Texture2D]
@export var start_pos: Vector2 = Vector2(200, 200)
@export var gap: Vector2 = Vector2(140, 0)

@export_range(0.1, 3.0, 0.05) var card_scale: float = 0.5   # ← 新增：卡牌缩放

func _ready() -> void:
	if card_scene == null:
		push_error("CardSpawner: card_scene 未设置")
		return
	var pos := start_pos
	for tex in card_textures:
		if tex == null:
			continue
		var c := card_scene.instantiate()
		c.texture = tex
		c.scale = Vector2(card_scale, card_scale)  # ← 新增：统一缩放卡牌
		c.position = pos
		add_child(c)
		pos += gap * card_scale                
