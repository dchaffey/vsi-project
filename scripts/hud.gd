extends Node3D

# --- 2D UI Components ---
class HUD2D extends CanvasLayer:
	var hp_label: Label
	var money_label: Label
	var wave_label: Label
	var crosshair: ColorRect
	var ring_drawer: Node # We'll move RingDrawer here
	var _countdown_secs: float = 0.0
	var _next_wave_num: int = 0
	var _total_waves: int = 0

	func _ready() -> void:
		# HP Label
		hp_label = Label.new()
		hp_label.position = Vector2(20, 20)
		hp_label.add_theme_font_size_override("font_size", 32)
		add_child(hp_label)

		# Money Label
		money_label = Label.new()
		money_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		money_label.position = Vector2(-220, 20)
		money_label.add_theme_font_size_override("font_size", 32)
		money_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		add_child(money_label)

		# Wave Label
		wave_label = Label.new()
		wave_label.position = Vector2(20, 60)
		wave_label.add_theme_font_size_override("font_size", 32)
		add_child(wave_label)
		
		# Crosshair
		crosshair = ColorRect.new()
		crosshair.size = Vector2(4, 4)
		crosshair.set_anchors_preset(Control.PRESET_CENTER)
		crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
		crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
		add_child(crosshair)

	func update_hp(curr: float, max_hp: float) -> void:
		hp_label.text = "Objective HP: %d / %d" % [curr, max_hp]

	func update_money(amount: float) -> void:
		money_label.text = "Money: $%.2f" % amount

	func update_wave(current: int, total: int) -> void:
		_countdown_secs = 0.0
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
		wave_label.text = "Wave: %d / %d  —  Next in %ds" % [_next_wave_num - 1, _total_waves, ceili(_countdown_secs)]

# --- Ring Drawer (re-implemented as a child of HUD2D) ---
class RingDrawer extends Control:
	var selected_building: Node3D = null
	var ring_screen_pos: Vector2 = Vector2.ZERO
	var hovered_button: int = -1
	var ring_radius: float = 120.0
	var button_radius: float = 50.0
	var ring_buttons: Array = [
		{"name": "Upgrade", "action": "upgrade", "angle": PI/6, "color": Color.GREEN},
		{"name": "Destroy", "action": "destroy", "angle": -PI/2, "color": Color.RED},
		{"name": "Close", "action": "close", "angle": 5*PI/6, "color": Color.GRAY},
	]

	func _ready() -> void:
		mouse_filter = MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)

	func _process(_delta: float) -> void:
		if not is_instance_valid(selected_building):
			selected_building = null
			queue_redraw()
			return
		var cam := get_viewport().get_camera_3d()
		if not cam or cam.is_position_behind(selected_building.global_position):
			queue_redraw()
			return
		ring_screen_pos = cam.unproject_position(selected_building.global_position)
		queue_redraw()

	func _draw() -> void:
		if not selected_building: return
		var center := ring_screen_pos
		draw_arc(center, ring_radius, 0.0, TAU, 64, Color.WHITE, 3.0)
		for i in range(ring_buttons.size()):
			var button = ring_buttons[i]
			var button_pos = center + Vector2(cos(button.angle), sin(button.angle)) * ring_radius
			var color = button.color if i == hovered_button else Color(button.color, 0.6)
			draw_circle(button_pos, button_radius, color)

	func _input(event: InputEvent) -> void:
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
		get_viewport().set_input_as_handled()

# --- Main HUD Manager (Node3D) ---
var _internal_hud: HUD2D
var _ring_drawer: RingDrawer
var _tower_shelf: Node3D
var _vr_board: Node3D
var _is_vr: bool = false

func _ready() -> void:
	add_to_group("hud")
	_is_vr = XRServer.find_interface("OpenXR") != null
	
	_setup_3d_elements()
	_setup_2d_elements()

func _setup_3d_elements() -> void:
	# Add the 3D tower shelf
	var shelf_script = preload("res://scripts/vr_tower_shelf.gd")
	_tower_shelf = Node3D.new()
	_tower_shelf.set_script(shelf_script)
	add_child(_tower_shelf)
	_tower_shelf.position = Vector3(0, 2.5, 9.5)
	_tower_shelf.rotation_degrees = Vector3(-10, 0, 0)

	if _is_vr:
		# Setup VR floating board
		var vp_scene = preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
		_vr_board = vp_scene.instantiate()
		add_child(_vr_board)
		_vr_board.screen_size = Vector2(3.0, 2.0)
		_vr_board.viewport_size = Vector2(1920, 1080)
		_vr_board.position = Vector3(0, 4.0, 10.0)
		_vr_board.rotation_degrees = Vector3(-15, 0, 0)

func _setup_2d_elements() -> void:
	_internal_hud = HUD2D.new()
	
	if _is_vr:
		# Viewport initialization takes a frame
		await get_tree().process_frame
		var vp = _vr_board.get_node_or_null("Viewport")
		if vp:
			vp.add_child(_internal_hud)
		else:
			push_error("HUD: Viewport not found in Viewport2DIn3D")
	else:
		# Standard screen overlay
		add_child(_internal_hud)

	# Ring drawer is always 2D overlay on top of everything
	_ring_drawer = RingDrawer.new()
	_internal_hud.add_child(_ring_drawer)

func initialize(player: CharacterBody3D, objective: Area3D) -> void:
	if not _internal_hud.is_inside_tree():
		await _internal_hud.ready
	
	objective.hp_changed.connect(_internal_hud.update_hp)
	_internal_hud.update_hp(objective.current_hp, objective.max_hp)
	
	player.money_changed.connect(_internal_hud.update_money)
	_internal_hud.update_money(player.money)

	# Connect shelf to player
	_tower_shelf.tower_selected.connect(func(script_path, cost):
		if player.money >= cost:
			player.start_placement(script_path)
	)

func update_wave(current: int, total: int) -> void:
	_internal_hud.update_wave(current, total)

func start_wave_countdown(next_wave: int, total: int, delay: float) -> void:
	_internal_hud.start_wave_countdown(next_wave, total, delay)

func show_building_ring(building: Node3D) -> void:
	_ring_drawer.selected_building = building
	_ring_drawer.hovered_button = -1

func hide_building_ring() -> void:
	_ring_drawer.selected_building = null

func show_game_over() -> void:
	# Game over is always a screen-space overlay for clarity
	var overlay_hud = CanvasLayer.new()
	overlay_hud.layer = 100
	add_child(overlay_hud)
	
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.7)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay_hud.add_child(overlay)
	
	var center = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay_hud.add_child(center)
	
	var v_box = VBoxContainer.new()
	center.add_child(v_box)
	
	var label = Label.new()
	label.text = "GAME OVER"
	label.add_theme_font_size_override("font_size", 64)
	v_box.add_child(label)
	
	var restart = Button.new()
	restart.text = "RESTART"
	restart.pressed.connect(func(): get_tree().reload_current_scene())
	v_box.add_child(restart)
	
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
