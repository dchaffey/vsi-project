extends Node3D

# --- GameBoard UI (Stats Display) ---
class GameBoardUI extends Control:
	var hp_label: Label
	var money_label: Label
	var wave_label: Label
	var _countdown_secs: float = 0.0
	var _next_wave_num: int = 0
	var _total_waves: int = 0

	func _ready() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		
		# Background
		var bg = ColorRect.new()
		bg.color = Color(0.1, 0.1, 0.1, 0.8)
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		add_child(bg)

		# HP Label
		hp_label = Label.new()
		hp_label.position = Vector2(40, 40)
		hp_label.add_theme_font_size_override("font_size", 48)
		add_child(hp_label)

		# Money Label
		money_label = Label.new()
		money_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		money_label.position = Vector2(-400, 40)
		money_label.add_theme_font_size_override("font_size", 48)
		money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(money_label)

		# Wave Label
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

# --- Ring Drawer (Radial Menu on the board) ---
class RingDrawer extends Control:
	var selected_building: Node3D = null
	var ring_screen_pos: Vector2 = Vector2.ZERO
	var hovered_button: int = -1
	var ring_radius: float = 180.0
	var button_radius: float = 70.0
	var ring_buttons: Array = [
		{"name": "Upgrade", "action": "upgrade", "angle": PI/6, "color": Color.GREEN},
		{"name": "Destroy", "action": "destroy", "angle": -PI/2, "color": Color.RED},
		{"name": "Close", "action": "close", "angle": 5*PI/6, "color": Color.GRAY},
	]

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_PASS
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _process(_delta: float) -> void:
		if not is_instance_valid(selected_building):
			selected_building = null
			queue_redraw()
			return
		
		ring_screen_pos = size / 2.0
		queue_redraw()

	func _draw() -> void:
		if not selected_building: return
		var center := ring_screen_pos
		draw_arc(center, ring_radius, 0.0, TAU, 64, Color.WHITE, 5.0)
		for i in range(ring_buttons.size()):
			var button = ring_buttons[i]
			var button_pos = center + Vector2(cos(button.angle), sin(button.angle)) * ring_radius
			var color = button.color if i == hovered_button else Color(button.color, 0.6)
			draw_circle(button_pos, button_radius, color)

	func _gui_input(event: InputEvent) -> void:
		if not selected_building: return
		if event is InputEventMouseMotion:
			_update_hovered_button(event.position)
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_handle_button_click(event.position)

	func _update_hovered_button(mouse_pos: Vector2) -> void:
		var old_hovered = hovered_button
		hovered_button = -1
		for i in range(ring_buttons.size()):
			var button = ring_buttons[i]
			var button_pos = ring_screen_pos + Vector2(cos(button.angle), sin(button.angle)) * ring_radius
			if mouse_pos.distance_to(button_pos) <= button_radius:
				hovered_button = i
				break
		if old_hovered != hovered_button: queue_redraw()

	func _handle_button_click(mouse_pos: Vector2) -> void:
		if hovered_button < 0: return
		var button = ring_buttons[hovered_button]
		match button.action:
			"upgrade": if selected_building.has_method("upgrade"): selected_building.upgrade()
			"destroy": if selected_building.has_method("destroy"): selected_building.destroy()
			"close": selected_building = null
		accept_event()

# --- Main GameBoard Manager (Node3D) ---
var _ui := GameBoardUI.new()
var _ring_drawer := RingDrawer.new()
var _tower_shelf := Node3D.new()
var _board_panel: Node3D
var _terrain: StaticBody3D

func _ready() -> void:
	add_to_group("game_board")
	add_to_group("hud")
	
	_ui.add_child(_ring_drawer)
	_tower_shelf.set_script(preload("res://scripts/vr_tower_shelf.gd"))

func _setup_3d_elements() -> void:
	# Default dimensions if terrain is not yet provided
	var half_w = 32.0
	var half_d = 32.0
	var max_h = 10.0
	
	if _terrain:
		half_w = (_terrain.terrain_width - 1) * _terrain.cell_size * 0.5
		half_d = (_terrain.terrain_depth - 1) * _terrain.cell_size * 0.5
		max_h = _terrain.max_height

	# 1. Main Stats Board
	var vp_scene = preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
	_board_panel = vp_scene.instantiate()
	add_child(_board_panel)
	
	# Board size (meters) - Scaled 5x
	var board_w = 300.0
	var board_h = 200.0
	_board_panel.screen_size = Vector2(board_w, board_h)
	_board_panel.viewport_size = Vector2(1280, 800)
	
	# Position it in the middle of the West edge (negative X)
	# We offset it so it's outside the terrain walls
	var pos_x = -half_w - 50.0
	var pos_z = 0.0
	# Above the wall top (max_h + 30). 
	# With board_h=200, center at max_h+150 puts the bottom at max_h+50, which is 20m above the wall top.
	var pos_y = max_h + 150.0
	
	_board_panel.position = Vector3(pos_x, pos_y, pos_z)
	
	# Face East (towards the center of the terrain)
	_board_panel.rotation_degrees = Vector3(0, -90, 0)
	
	# Ensure it's on layer 1 for mouse raycast
	_board_panel.collision_layer = 1 | (1 << 20)

	# 2. Tower Shelf
	add_child(_tower_shelf)
	
	# Position shelf below the board, scaled offset
	_tower_shelf.position = _board_panel.position + _board_panel.transform.basis.y * (-board_h * 0.5 - 60.0) + _board_panel.transform.basis.z * 25.0
	_tower_shelf.rotation = _board_panel.rotation
	_tower_shelf.rotate_object_local(Vector3.RIGHT, -deg_to_rad(15)) # Angle it slightly up
	
	# Scale the shelf 5x (6.0 -> 30.0)
	_tower_shelf.scale = Vector3(30.0, 30.0, 30.0)

func _setup_ui_elements() -> void:
	# Wait for viewport to be ready and render one frame so the texture is valid
	if not _board_panel.is_node_ready(): await _board_panel.ready
	await get_tree().process_frame
	var vp = _board_panel.get_node_or_null("Viewport")
	assert(vp != null, "GameBoard: Viewport not found in Viewport2DIn3D")
	vp.add_child(_ui)

func initialize(player: CharacterBody3D, objective: Area3D, terrain: StaticBody3D) -> void:
	_terrain = terrain
	_setup_3d_elements()
	_setup_ui_elements()
	
	# Ensure UI is ready before connecting signals
	if not _ui.is_node_ready(): await _ui.ready
	
	objective.hp_changed.connect(_ui.update_hp)
	_ui.update_hp(objective.current_hp, objective.max_hp)
	
	player.money_changed.connect(_ui.update_money)
	_ui.update_money(player.money)

	_tower_shelf.tower_selected.connect(func(script_path, cost):
		if player.money >= cost:
			player.start_placement(script_path)
	)

func update_wave(current: int, total: int) -> void:
	_ui.update_wave(current, total)

func start_wave_countdown(next_wave: int, total: int, delay: float) -> void:
	_ui.start_wave_countdown(next_wave, total, delay)

func show_building_ring(building: Node3D) -> void:
	_ring_drawer.selected_building = building
	_ring_drawer.hovered_button = -1

func hide_building_ring() -> void:
	_ring_drawer.selected_building = null

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
