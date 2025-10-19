extends Node2D
class_name PageRoot

@export var background_path: NodePath
@export var grid_manager_path: NodePath
@export var drag_layer_path: NodePath
@export var cards_root_path: NodePath

func _ready() -> void:
	add_to_group("page_root")
	set_meta("is_page_root", true)

	# 可选：若没在 Inspector 指定，就按常用名字找一次，方便新页拷贝即用
	if background_path == NodePath():
		var bg := find_child("Background", true, false)
		if bg != null: background_path = bg.get_path()
	if grid_manager_path == NodePath():
		var gm := find_child("GridSnapManager", true, false)
		if gm != null: grid_manager_path = gm.get_path()
	if drag_layer_path == NodePath():
		var dl := find_child("DragLayer", true, false)
		if dl != null: drag_layer_path = dl.get_path()
	if cards_root_path == NodePath():
		var cr := find_child("Cards", true, false)
		if cr != null: cards_root_path = cr.get_path()

func get_background() -> Sprite2D:
	return get_node_or_null(background_path) as Sprite2D

func get_grid_manager() -> Node:
	return get_node_or_null(grid_manager_path)

func get_drag_layer() -> CanvasLayer:
	return get_node_or_null(drag_layer_path) as CanvasLayer

func get_cards_root() -> Node:
	return get_node_or_null(cards_root_path)
