extends Node3D

# --- GameBoard UI (Stats Display) ---
class GameBoardUI extends Control:
	var hp_label: Label  # defence objective HP readout
	var money_label: Label  # current cash readout (mirrored in 3D by the tower shelf label)
	var wave_label: Label  # current wave / countdown to next
	var _countdown_secs: float = 0.0  # seconds until next wave — drives countdown text
	var _next_wave_num: int = 0  # wave number displayed during countdown
	var _total_waves: int = 0  # total waves for "X / Y" display

	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)

		# Background panel — dark translucent backdrop for readability
		var bg = ColorRect.new()
		bg.color = Color(0.1, 0.1, 0.1, 0.8)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)

		# HP Label — top left
		hp_label = Label.new()
		hp_label.position = Vector2(40, 40)
		hp_label.add_theme_font_size_override("font_size", 48)
		add_child(hp_label)

		# Money Label — top right
		money_label = Label.new()
		money_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		money_label.position = Vector2(-400, 40)
		money_label.add_theme_font_size_override("font_size", 48)
		money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(money_label)

		# Wave Label — below HP
		wave_label = Label.new()
		wave_label.position = Vector2(40, 120)
		wave_label.add_theme_font_size_override("font_size", 48)
		add_child(wave_label)

	func update_hp(curr: float, max_hp: float) -> void:
		assert(hp_label != null, "GameBoardUI: update_hp called before _ready")
		hp_label.text = "Objective HP: %d / %d" % [curr, max_hp]

	func update_money(amount: float) -> void:
		assert(money_label != null, "GameBoardUI: update_money called before _ready")
		money_label.text = "Money: $%.2f" % amount

	func update_wave(current: int, total: int) -> void:
		_countdown_secs = 0.0
		assert(wave_label != null, "GameBoardUI: update_wave called before _ready")
		wave_label.text = "Wave: %d / %d" % [current, total]

	func start_wave_countdown(next_wave: int, total: int, delay: float) -> void:
		_next_wave_num = next_wave
		_total_waves = total
		_countdown_secs = delay
		_update_wave_text()

	func _process(delta: float) -> void:
		if _countdown_secs > 0.0:
			_countdown_secs -= delta
			_update_wave_text()

	func _update_wave_text() -> void:
		assert(wave_label != null, "GameBoardUI: _update_wave_text called before _ready")
		wave_label.text = "Wave: %d / %d  —  Next in %ds" % [_next_wave_num - 1, _total_waves, ceili(_countdown_secs)]


# --- Building Menu (3D clickable spheres that replace the old radial menu) ---
class BuildingMenu3D extends Node3D:
	# Three clickable world-space spheres (upgrade / sell / move) that float above a selected building.
	signal action_selected(action: String)  # emits "upgrade", "sell", or "move" on sphere click

	var _building: Node3D = null  # building this menu acts on — used only to anchor position

	const SPHERE_RADIUS: float = 1.0  # visual radius of each action sphere
	const SPHERE_SPACING: float = 3.5  # horizontal gap between spheres
	const MENU_HEIGHT_OFFSET: float = 2.0  # extra height above tower top so spheres don't clip model

	func setup(building: Node3D) -> void:
		# Anchor the menu above the building's top and spawn the three action spheres
		_building = building
		var top_y := _building_top_y(building)
		global_position = building.global_position + Vector3(0.0, top_y + MENU_HEIGHT_OFFSET, 0.0)
		_create_sphere("upgrade", Vector3(-SPHERE_SPACING, 0.0, 0.0), Color(0.2, 1.0, 0.3))
		_create_sphere("sell", Vector3(0.0, 0.0, 0.0), Color(1.0, 0.25, 0.25))
		_create_sphere("move", Vector3(SPHERE_SPACING, 0.0, 0.0), Color(0.3, 0.6, 1.0))

	func _building_top_y(building: Node3D) -> float:
		# Height of the building's collision box — used to place menu above its roof
		if building.has_method("_get_collision_box_size"):
			var size: Vector3 = building._get_collision_box_size()
			return size.y
		return 4.0

	func _create_sphere(action: String, offset: Vector3, color: Color) -> void:
		# Build one clickable action sphere: Area3D + collision + mesh + label, wired to action_selected.
		var area := Area3D.new()
		area.position = offset
		area.collision_layer = 1  # same layer as ground/towers so mouse raycasts pick it up
		area.collision_mask = 0
		area.input_ray_pickable = true
		add_child(area)

		var col := CollisionShape3D.new()
		var shape := SphereShape3D.new()
		shape.radius = SPHERE_RADIUS
		col.shape = shape
		area.add_child(col)

		var mesh_inst := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = SPHERE_RADIUS
		mesh.height = SPHERE_RADIUS * 2.0
		mesh_inst.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.emission_enabled = true
		mat.emission = color
		mat.emission_energy_multiplier = 0.6
		mesh_inst.material_override = mat
		area.add_child(mesh_inst)

		# Always-facing label so the player can read the action
		var label := Label3D.new()
		label.text = action.capitalize()
		label.position = Vector3(0.0, SPHERE_RADIUS + 0.6, 0.0)
		label.pixel_size = 0.012
		label.font_size = 48
		label.outline_size = 8
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		area.add_child(label)

		area.input_event.connect(func(_cam, event, _pos, _norm, _idx):
			if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				action_selected.emit(action)
				get_viewport().set_input_as_handled()
		)


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

	objective.hp_changed.connect(_ui.update_hp)
	_ui.update_hp(objective.current_hp, objective.max_hp)

	# Route money changes to both the 2D overlay and the 3D shelf label
	player.money_changed.connect(_ui.update_money)
	player.money_changed.connect(_update_shelf_money)
	_ui.update_money(player.money)
	_update_shelf_money(player.money)

	# Shelf signal connection for both VR and Desktop
	_tower_shelf.tower_selected.connect(func(script_path, cost):
		if player.money >= cost:
			player.start_placement(script_path)
	)

func _update_shelf_money(amount: float) -> void:
	# Refresh the 3D cash label next to the shop — integer dollars are enough for the shop view
	if _shelf_money_label:
		_shelf_money_label.text = "$%d" % int(amount)

func update_wave(current: int, total: int) -> void:
	_ui.update_wave(current, total)

func start_wave_countdown(next_wave: int, total: int, delay: float) -> void:
	_ui.start_wave_countdown(next_wave, total, delay)

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
	# Dispatch the clicked sphere to the building's matching handler, then close the menu.
	# Close BEFORE sell/move because those free the building and would invalidate the menu's anchor.
	hide_building_menu()
	if not is_instance_valid(building):
		return
	match action:
		"upgrade":
			if building.has_method("upgrade"): building.upgrade()
		"sell":
			if building.has_method("destroy"): building.destroy()
		"move":
			if building.has_method("move"): building.move()

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
