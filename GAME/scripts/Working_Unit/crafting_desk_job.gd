extends Control
class_name crafting_desk_job


# =========================
# —— 弹出位置 —— 
# =========================
@export var margin: Vector2 = Vector2(8, 8)


# =========================
# —— 输入槽配置 —— 
# =========================
# 槽根节点（下面挂 Slot1 / Slot2 / SlotN 这些 Node2D）
@export var job_slot_root_path: NodePath
# 卡松手时，距离槽多少像素内就会被吸进去
@export_range(0.0, 512.0, 1.0) var job_slot_snap_radius: float = 64.0


# snap 动画参数（磁铁感）
@export_range(0.05, 0.6, 0.01) var job_snap_duration: float = 0.22
@export var job_snap_transition: Tween.TransitionType = Tween.TRANS_BACK
@export var job_snap_ease: Tween.EaseType = Tween.EASE_OUT
@export_range(0.0, 0.5, 0.01) var job_snap_delay: float = 0.0


# =========================
# —— 输出槽 & 按钮 —— 
# =========================
# 输出槽（Node2D 或 Control），合成结果会出现在这里附近（global_position）
@export var output_slot_path: NodePath
# 合成按钮
@export var craft_button_path: NodePath
# 新卡要挂到的“世界场景”路径（*.tscn），不是 NodePath
# 例如：res://GAME/scenes/MainWorld.tscn
@export_file("*.tscn") var spawn_parent_path: String = ""


# 调试开关
@export var debug_log: bool = false


# =========================
# —— 运行期状态 —— 
# =========================
var _job_slot_root: Node2D = null
var _job_slots: Array[Node2D] = []          # 所有输入槽
var _job_slot_occupants: Dictionary = {}    # key: 槽 Node2D, value: 卡牌 Node2D


var _output_slot: Node = null               # 输出槽（可以是 Node2D 或 Control）
var _output_card: Node2D = null             # 当前输出槽上的卡（如果有）


# 记住 WorkUnitBase 的世界坐标锚点（通过 show_at 传进来）
var _anchor_valid: bool = false
var _anchor_position: Vector2 = Vector2.ZERO


var _craft_button: Button = null




# =========================
# —— 生命周期 —— 
# =========================
func _ready() -> void:
		add_to_group("work_unit_job")


		# 槽根节点
		_job_slot_root = get_node_or_null(job_slot_root_path) as Node2D
		if _job_slot_root == null:
				_job_slot_root = find_child("JobSlotRoot", true, false) as Node2D


		# 输出槽（可以和 JobSlotRoot 同层，也可以是它的子节点；类型不限定）
		_output_slot = null
		if output_slot_path != NodePath(""):
				_output_slot = get_node_or_null(output_slot_path)
		if _output_slot == null:
				_output_slot = find_child("OutputSlot", true, false)


		# 收集输入槽（排除输出槽）
		_collect_job_slots()


		# 合成按钮
		_craft_button = get_node_or_null(craft_button_path) as Button
		if _craft_button == null:
				_craft_button = find_child("CraftButton", true, false) as Button
		if _craft_button != null:
				_craft_button.pressed.connect(_on_craft_pressed)


		if debug_log:
				print("[crafting_desk_job] ready: input_slots=%d output_slot=%s" %
						[_job_slots.size(), str(_output_slot)])




# =========================
# —— 弹出接口（兼容 WorkUnitBase）——
# =========================
func show_at(global_pos: Vector2) -> void:
		_anchor_position = global_pos
		_anchor_valid = true


		# 简单从锚点上方弹出一块
		global_position = global_pos + Vector2(0.0, -size.y) - margin
		visible = true




func toggle_at(global_pos: Vector2) -> void:
		if visible:
				visible = false
		else:
				show_at(global_pos)




# =========================
# —— 槽初始化 —— 
# =========================
func _collect_job_slots() -> void:
		_job_slots.clear()
		if _job_slot_root == null:
				return


		for child in _job_slot_root.get_children():
				if child is Node2D:
						var slot_node: Node2D = child as Node2D
						if slot_node != null:
								# 避免把输出槽当成输入槽（当输出槽也是 Node2D 时）
								if _output_slot != null and slot_node == _output_slot:
										continue
								_job_slots.append(slot_node)


		if debug_log:
				print("[crafting_desk_job] collected %d input slots" % _job_slots.size())




# =========================
# —— 输入卡 snap 逻辑 —— 
# =========================
func _try_snap_card(card: Node2D, drop_global: Vector2) -> bool:
		if card == null or not is_instance_valid(card):
				return false
		if _job_slots.is_empty():
				return false


		var radius_sq: float = job_slot_snap_radius * job_slot_snap_radius
		var best_slot: Node2D = null
		var best_dist_sq: float = INF


		# 找最近且空闲的输入槽
		for slot in _job_slots:
				if slot == null or not is_instance_valid(slot):
						continue


				var existing_v: Variant = _job_slot_occupants.get(slot, null)
				var existing: Node2D = existing_v as Node2D
				if existing != null and is_instance_valid(existing):
						continue


				var slot_pos: Vector2 = slot.global_position
				var d2: float = drop_global.distance_squared_to(slot_pos)
				if d2 > radius_sq:
						continue
				if d2 < best_dist_sq:
						best_dist_sq = d2
						best_slot = slot


		if best_slot == null:
				return false


		# 把卡 reparent 到 JobSlotRoot 内部，保持 global_position
		if _job_slot_root != null and card.get_parent() != _job_slot_root:
				var gp: Vector2 = card.global_position
				card.reparent(_job_slot_root, true)
				card.global_position = gp


		# 磁铁式 snap tween
		var tw: Tween = card.create_tween()
		tw.set_trans(job_snap_transition).set_ease(job_snap_ease)
		if job_snap_delay > 0.0:
				tw.set_delay(job_snap_delay)
		tw.tween_property(card, "global_position", best_slot.global_position, job_snap_duration)


		_job_slot_occupants[best_slot] = card


		if debug_log:
				print("[crafting_desk_job] snapped card %s into slot %s" % [card, best_slot])


		return true




# 卡开始拖拽时，清理槽占用（WorkUnitBase 会转发到这里）
func _on_card_begin_drag(card: Node2D) -> void:
		if card == null or not is_instance_valid(card):
				return


		# 输入槽：如果这张卡在某个槽里，占用记录要清掉
		if not _job_slot_occupants.is_empty():
				for slot in _job_slot_occupants.keys():
						var card_in_slot: Node2D = _job_slot_occupants[slot] as Node2D
						if card_in_slot == card:
								_job_slot_occupants.erase(slot)
								if debug_log:
										print("[crafting_desk_job] input slot cleared by drag:", slot)
								break


		# 输出槽：如果拖的是输出卡，也清掉引用（方便下一次合成）
		if _output_card == card:
				_output_card = null
				if debug_log:
						print("[crafting_desk_job] output card taken:", card)




# =========================
# —— 合成按钮 —— 
# =========================
func _on_craft_pressed() -> void:
		if debug_log:
				print("[crafting_desk_job] craft button pressed")


		# 如果输出槽上还有卡，就先不允许继续合成（避免堆成一团）
		if _output_card != null and is_instance_valid(_output_card):
				if debug_log:
						print("[crafting_desk_job] output slot occupied, craft aborted")
				return


		# 收集当前所有输入槽里的卡牌（只看非空槽）
		var input_cards: Array[Node2D] = []
		for slot in _job_slots:
				var c_v: Variant = _job_slot_occupants.get(slot, null)
				var c: Node2D = c_v as Node2D
				if c != null and is_instance_valid(c):
						input_cards.append(c)


		if input_cards.is_empty():
				if debug_log:
						print("[crafting_desk_job] no cards in slots")
				return


		var rm: Node = _get_recipe_manager()
		if rm == null or not rm.has_method("craft_in_desk"):
				if debug_log:
						print("[crafting_desk_job] RecipeManager.craft_in_desk not available")
				return


		var spawn_parent: Node = _get_spawn_parent()
		var spawn_pos: Vector2 = _get_output_slot_spawn_pos()


		# 调用 RecipeManager：完全由它负责「是否匹配配方 / 删除旧卡 / 生成新卡」
		var new_any: Variant = rm.call("craft_in_desk", input_cards, spawn_parent, spawn_pos)
		var new_card: Node2D = null
		if new_any is Node2D:
				new_card = new_any as Node2D


		# 若成功，新卡已经被 add_child 到 spawn_parent，这里只记录引用 & 清掉输入槽状态
		if new_card != null and is_instance_valid(new_card):
				_output_card = new_card
				_job_slot_occupants.clear()


				# 再 tween 一下，强制纠正到 OutputSlot 位置，防止坐标系差一点偏移
				if _output_slot != null and is_instance_valid(_output_slot):
						var target_pos := _get_output_slot_spawn_pos()
						var tw := new_card.create_tween()
						tw.tween_property(new_card, "global_position", target_pos, 0.18)


				if debug_log:
						print("[crafting_desk_job] craft success, new card:", new_card)
		else:
				if debug_log:
						print("[crafting_desk_job] craft_in_desk returned null (no matching desk recipe)")




# =========================
# —— 工具：找到 RecipeManager —— 
# =========================
func _get_recipe_manager() -> Node:
		var root: Node = get_tree().root


		# 1）优先尝试 Autoload 常用名字
		var n: Node = root.get_node_or_null(^"/root/RecipeManager")
		if n != null:
				if debug_log:
						print("[crafting_desk_job] found RecipeManager at /root/RecipeManager")
				return n


		n = root.get_node_or_null(^"/root/recipemanager")
		if n != null:
				if debug_log:
						print("[crafting_desk_job] found RecipeManager at /root/recipemanager")
				return n


		# 2）再尝试在 current_scene 里按节点名查找
		var scene := get_tree().current_scene
		if scene != null:
				var in_scene: Node = scene.find_child("RecipeManager", true, false)
				if in_scene == null:
						in_scene = scene.find_child("recipemanager", true, false)
				if in_scene != null:
						if debug_log:
								print("[crafting_desk_job] found RecipeManager in scene as node:", in_scene.name)
						return in_scene


		# 3）最后保险：按脚本 class_name 搜一遍根节点的直接子节点
		for child in root.get_children():
				var s: Script = child.get_script() as Script
				if s == null:
						continue
				var cls := s.get_class()
				if cls == "recipemanager" or cls == "RecipeManager":
						if debug_log:
								print("[crafting_desk_job] found RecipeManager by script on node:", child.name)
						return child


		if debug_log:
				var names: Array[String] = []
				for c in root.get_children():
						names.append(c.name)
				print("[crafting_desk_job] _get_recipe_manager: NOT FOUND. root children=", names)


		return null




# =========================
# —— 工具：spawn_parent（场景路径解析成 Node） —— 
# =========================
func _get_spawn_parent() -> Node:
		var root: Node = get_tree().root


		# 1）如果 Inspector 填了场景路径：优先用 current_scene
		if spawn_parent_path != "":
				var cur_scene := get_tree().current_scene
				if cur_scene != null and cur_scene.scene_file_path != "":
						if _norm_path(cur_scene.scene_file_path) == _norm_path(spawn_parent_path):
								# 在这个场景里找 CardsLayer，当作卡牌 parent
								var cl := cur_scene.find_child("CardsLayer", true, false)
								if cl != null:
										return cl
								return cur_scene


				# 2）没匹配到 current_scene，就在 root 下找 scene_file_path 一致的实例
				for child in root.get_children():
						if child.scene_file_path != "" and _norm_path(child.scene_file_path) == _norm_path(spawn_parent_path):
								var cl2 := child.find_child("CardsLayer", true, false)
								if cl2 != null:
										return cl2
								return child


		# 3）spawn_parent_path 为空时，退回旧逻辑：找任何叫 CardsLayer 的节点
		var n2: Node = root.find_child("CardsLayer", true, false)
		if n2 != null:
				return n2


		# 4）再退一步，用 current_scene
		if get_tree().current_scene != null:
				return get_tree().current_scene


		# 5）兜底：自己
		return self




# =========================
# —— 工具：输出槽坐标 —— 
# =========================
func _get_output_slot_spawn_pos() -> Vector2:
		# 默认退回到锚点（desk 的世界坐标）
		if _output_slot == null or not is_instance_valid(_output_slot):
				return _anchor_position


		# Node2D：用 global_position（世界坐标）
		if _output_slot is Node2D:
				return (_output_slot as Node2D).global_position


		# Control：用 global_position（屏幕坐标）
		if _output_slot is Control:
				return (_output_slot as Control).global_position


		return _anchor_position




# =========================
# —— 小工具 —— 
# =========================
func _norm_path(p: String) -> String:
		return p.replace("\\", "/")
