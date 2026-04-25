extends Node3D

# --- GameBoard UI (Stats Display) ---
class GameBoardUI extends Control:
	var money_label: Label  # current cash readout (mirrored in 3D by the tower shelf label)

	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)

		# Background panel — dark translucent backdrop for readability
		var bg = ColorRect.new()
		bg.color = Color(0.1, 0.1, 0.1, 0.8)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)

		# Money Label — top right
		money_label = Label.new()
		money_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		money_label.position = Vector2(-400, 40)
		money_label.add_theme_font_size_override("font_size", 48)
		money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(money_label)

	func update_money(amount: float) -> void:
		assert(money_label != null, "GameBoardUI: update_money called before _ready")
		money_label.text = "Money: $%.2f" % amount


# --- Building Menu (3D billboarded Label3D buttons above the selected building) ---
class BuildingMenu3D extends Node3D:
	# Two clickable world-space text buttons (upgrade / sell) that float near a selected building.
	signal action_selected(action: String)  # emits "upgrade" or "sell" on label click

	var _building: Node3D = null  # building this menu acts on — used only to anchor position
	var _hovered_action: String = ""  # action name of the button currently under the cursor; "" if none
	var _tower_was_pickable: bool = true  # remembered state of the building's input_ray_pickable before we disabled it

	const CLICK_RADIUS: float = 1.4  # sphere hit area covering the billboarded text from any camera angle
	const VERTICAL_GAP: float = 2.0  # vertical spacing between tower top anchor and each label
	const UPGRADE_COLOR := Color(0.25, 1.0, 0.35)  # green — tied to money outflow / new tier
	const SELL_COLOR := Color(1.0, 0.3, 0.3)  # red — tied to destroy / refund
	const HOVER_COLOR := Color(1.0, 0.95, 0.2)  # yellow — applied on mouse_entered as click affordance

	func setup(building: Node3D) -> void:
		# Anchor the menu at the building's top; spawn upgrade above and sell below that anchor.
		# The upgrade button is skipped entirely when the tower is already at its final tier.
		_building = building
		# Disable picking on the tower while the menu is up so its collision box can't shadow
		# our buttons (e.g. the sell button that sits below the roofline). Restored in _exit_tree.
		if building is CollisionObject3D:
			_tower_was_pickable = (building as CollisionObject3D).input_ray_pickable
			(building as CollisionObject3D).input_ray_pickable = false
		var top_y := _building_top_y(building)
		global_position = building.global_position + Vector3(0.0, top_y, 0.0)
		if _building_can_upgrade(building):
			var upgrade_cost := _get_upgrade_cost(building)
			_create_button("upgrade", Vector3(0.0, VERTICAL_GAP, 0.0),
				"UPGRADE\n-$%d" % upgrade_cost, UPGRADE_COLOR)
		var sell_refund := _get_sell_refund(building)
		_create_button("sell", Vector3(0.0, -VERTICAL_GAP, 0.0),
			"SELL\n+$%d" % sell_refund, SELL_COLOR)

	func _exit_tree() -> void:
		# Re-enable mouse picking on the tower so the next click can reopen the menu.
		if is_instance_valid(_building) and _building is CollisionObject3D:
			(_building as CollisionObject3D).input_ray_pickable = _tower_was_pickable

	func _unhandled_input(event: InputEvent) -> void:
		# Single source of truth for clicks: if a button is hovered, commit its action; otherwise
		# treat the click as a dismiss. This decouples the click from physics-pick order so hover
		# highlight and click action can never disagree.
		if not (event is InputEventMouseButton): return
		if not event.pressed or event.button_index != MOUSE_BUTTON_LEFT: return
		if _hovered_action != "":
			action_selected.emit(_hovered_action)
		else:
			queue_free()
		get_viewport().set_input_as_handled()

	func _building_can_upgrade(building: Node3D) -> bool:
		# Only draw the upgrade button when the tower reports another tier is available.
		return building.has_method("can_upgrade") and building.can_upgrade()

	func _building_top_y(building: Node3D) -> float:
		# Height of the building's collision box — used to place menu near its roof
		if building.has_method("_get_collision_box_size"):
			var size: Vector3 = building._get_collision_box_size()
			return size.y
		return 4.0

	func _get_upgrade_cost(building: Node3D) -> int:
		# Per-building upgrade cost — falls back to 0 if the subclass forgot to override
		if building.has_method("get_upgrade_cost"):
			return building.get_upgrade_cost()
		return 0

	func _get_sell_refund(building: Node3D) -> int:
		# Sell value comes from building-level invested-cost tracking.
		if building.has_method("get_sell_refund"):
			return building.get_sell_refund()
		return 0

	func _create_button(action: String, offset: Vector3, text: String, color: Color) -> void:
		# Build one clickable Label3D: Area3D + sphere collision + billboarded text, wired to action_selected.
		var area := Area3D.new()
		area.position = offset
		area.collision_layer = 1  # same layer as ground/towers so mouse raycasts pick it up
		area.collision_mask = 0
		area.input_ray_pickable = true
		add_child(area)

		var col := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = CLICK_RADIUS
		col.shape = shape
		area.add_child(col)

		var label := Label3D.new()
		label.text = text
		label.pixel_size = 0.015
		label.font_size = 64
		label.outline_size = 12
		label.modulate = color
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED  # always faces the camera
		label.no_depth_test = true  # draw over towers so it never gets occluded
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		area.add_child(label)

		# Yellow hover feedback + hover-state tracking. _unhandled_input on the menu reads
		# _hovered_action to decide which action a click commits, so visual hover and click
		# are driven by the same signal and cannot diverge.
		area.mouse_entered.connect(func():
			_hovered_action = action
			label.modulate = HOVER_COLOR)
		area.mouse_exited.connect(func():
			if _hovered_action == action:
				_hovered_action = ""
			label.modulate = color)


# --- Main GameBoard Manager (Node3D) ---
var _ui := GameBoardUI.new()  # 2D overlay shown on the viewport panel
var _menu: BuildingMenu3D = null  # active action menu for the currently-selected building, if any
var _tower_shelf := Node3D.new()  # world-space shelf of buyable towers
var _shelf_money_label: Label3D = null  # 3D font showing current cash next to the shop
var _board_panel: Node3D  # Viewport2DIn3D hosting the stats UI
var _terrain: StaticBody3D  # referenced for sizing the board placement
var _is_vr: bool = false  # set by initialize() before any setup

func _ready() -> void:
	add_to_group("game_board")
	add_to_group("hud")

func _setup_3d_elements() -> void:
	var half_w = 32.0
	var max_h = 10.0

	if _terrain:
		half_w = (_terrain.terrain_width - 1) * _terrain.cell_size * 0.5
		max_h = _terrain.max_height

	# 1. Main Stats Board (Physical panel in world space)
	var vp_scene = preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
	_board_panel = vp_scene.instantiate()
	add_child(_board_panel)

	var board_w = 300.0
	var board_h = 200.0
	_board_panel.screen_size = Vector2(board_w, board_h)
	_board_panel.viewport_size = Vector2(1280, 800)

	var pos_x = -half_w - 50.0
	var pos_y = max_h + 150.0
	_board_panel.position = Vector3(pos_x, pos_y, 0.0)
	_board_panel.rotation_degrees = Vector3(0, -90, 0)
	# Ensure it can be hit by both mouse and VR pointer
	_board_panel.collision_layer = 1 | (1 << 20)

	# 2. Tower Shelf — world-space shop of buyable towers
	_tower_shelf.set_script(preload("res://scripts/vr_tower_shelf.gd"))
	add_child(_tower_shelf)
	_tower_shelf.position = _board_panel.position + _board_panel.transform.basis.y * (-board_h * 0.5 - 60.0) + _board_panel.transform.basis.z * 25.0
	_tower_shelf.rotation = _board_panel.rotation
	_tower_shelf.rotate_object_local(Vector3.RIGHT, -deg_to_rad(15))
	_tower_shelf.scale = Vector3(30.0, 30.0, 30.0)

	# 3. 3D Money Label — floats beside the shelf so cash is visible while shopping
	_shelf_money_label = Label3D.new()
	_shelf_money_label.text = "$0"
	_shelf_money_label.pixel_size = 0.006
	_shelf_money_label.font_size = 96
	_shelf_money_label.outline_size = 16
	_shelf_money_label.modulate = Color(1.0, 0.9, 0.3)
	_shelf_money_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_shelf_money_label.no_depth_test = true
	# Place to the right of the shelf (shelf-local space) and slightly above
	_shelf_money_label.position = Vector3(3.2, 2.0, 0.0)
	_tower_shelf.add_child(_shelf_money_label)

func _setup_ui_elements() -> void:
	# Wait for the board panel to be ready in the tree
	if not _board_panel.is_node_ready(): await _board_panel.ready

	# Viewport2DIn3D needs an extra frame to finish setting up its internal Viewport and Mesh
	await get_tree().process_frame
	await get_tree().process_frame

	var vp = _board_panel.get_node_or_null("Viewport")
	if vp:
		vp.add_child(_ui)
	else:
		push_error("GameBoard: Viewport not found in Viewport2DIn3D")

func initialize(player: CharacterBody3D, objective: Area3D, terrain: StaticBody3D, is_vr: bool = false) -> void:
	_terrain = terrain
	_is_vr = is_vr
	_setup_3d_elements()
	await _setup_ui_elements()

	if not _ui.is_node_ready(): await _ui.ready

	# Objective HP is shown in 3D above defence_objective itself — no 2D mirror needed here.
	# Route money changes to both the 2D overlay and the 3D shelf label
	player.money_changed.connect(_ui.update_money)
	player.money_changed.connect(_update_shelf_money)
	_ui.update_money(player.money)
	_update_shelf_money(player.money)

	# Shelf signal connection for both VR and Desktop
	_tower_shelf.tower_selected.connect(func(script_path, cost, source_position):
		if player.money >= cost:
			player.start_placement(script_path, source_position)
	)

func _update_shelf_money(amount: float) -> void:
	# Refresh the 3D cash label next to the shop — integer dollars are enough for the shop view
	if _shelf_money_label:
		_shelf_money_label.text = "$%d" % int(amount)

func show_building_menu(building: Node3D) -> void:
	# Close any prior menu, then spawn the 3D sphere menu anchored to this building
	hide_building_menu()
	_menu = BuildingMenu3D.new()
	add_child(_menu)
	_menu.setup(building)
	_menu.action_selected.connect(func(action: String):
		_on_menu_action(action, building)
	)

func hide_building_menu() -> void:
	if is_instance_valid(_menu):
		_menu.queue_free()
	_menu = null

func _on_menu_action(action: String, building: Node3D) -> void:
	# Dispatch the clicked label to the building's matching handler, then close the menu.
	# Close BEFORE sell because destroy() frees the building and would invalidate the menu's anchor.
	hide_building_menu()
	if not is_instance_valid(building):
		return
	match action:
		"upgrade":
			_try_upgrade(building)
		"sell":
			if building.has_method("destroy"): building.destroy()

func _try_upgrade(building: Node3D) -> void:
	# Building.upgrade() owns payment + level transition; this call is a single action dispatch.
	assert(building.has_method("upgrade"), "Tower must implement upgrade()")
	building.upgrade()

func show_game_over() -> void:
	var canvas = CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)

	var bg = ColorRect.new()
	bg.color = Color(0, 0, 0, 0.8)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(bg)

	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(center)

	var v_box = VBoxContainer.new()
	center.add_child(v_box)

	var l = Label.new()
	l.text = "GAME OVER"
	l.add_theme_font_size_override("font_size", 100)
	v_box.add_child(l)

	var btn = Button.new()
	btn.text = "RESTART"
	btn.custom_minimum_size = Vector2(200, 80)
	btn.pressed.connect(func(): get_tree().reload_current_scene())
	v_box.add_child(btn)

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
