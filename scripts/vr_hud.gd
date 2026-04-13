extends Node3D

var _internal_hud: CanvasLayer
var _vr_board: Node3D
var _tower_shelf: Node3D

func _ready() -> void:
	# Load the XR Tools Viewport2DIn3D
	var vp_scene = preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
	_vr_board = vp_scene.instantiate()
	add_child(_vr_board)
	
	# Configure the VR board size and position
	_vr_board.screen_size = Vector2(3.0, 2.0)
	_vr_board.viewport_size = Vector2(1920, 1080)
	
	# Position the board floating near the enemy spawn / center area
	_vr_board.position = Vector3(0, 4.0, 10.0)
	_vr_board.rotation_degrees = Vector3(-15, 0, 0)

	# Add the 3D tower shelf below the main board
	var shelf_script = preload("res://scripts/vr_tower_shelf.gd")
	_tower_shelf = Node3D.new()
	_tower_shelf.set_script(shelf_script)
	add_child(_tower_shelf)
	_tower_shelf.position = Vector3(0, 2.5, 9.5) # Raised height
	_tower_shelf.rotation_degrees = Vector3(-10, 0, 0)
	
	# Wait for the scene tree to initialize the Viewport node
	await get_tree().process_frame
	
	# Instantiate our actual HUD and place it inside the viewport
	_internal_hud = CanvasLayer.new()
	_internal_hud.set_script(preload("res://scripts/hud.gd"))
	
	var vp = _vr_board.get_node_or_null("Viewport")
	if vp:
		vp.add_child(_internal_hud)
	else:
		push_error("VR HUD could not find Viewport inside Viewport2DIn3D")
	
	# Also add this wrapper to the hud group
	add_to_group("hud")

func initialize(player: CharacterBody3D, objective: Area3D) -> void:
	# Wait for internal HUD _ready to finish if called immediately
	if not _internal_hud.is_inside_tree():
		await _internal_hud.ready
	_internal_hud.initialize(player, objective)
	_internal_hud.hide_tower_selection()

	# Connect shelf selection to player placement
	_tower_shelf.tower_selected.connect(func(script_path, cost):
		if player.money >= cost:
			player.start_placement(script_path)
	)

func update_wave(current: int, total: int) -> void:
	if _internal_hud:
		_internal_hud.update_wave(current, total)

func start_wave_countdown(next_wave: int, total: int, delay: float) -> void:
	if _internal_hud:
		_internal_hud.start_wave_countdown(next_wave, total, delay)

func show_building_ring(building: Node3D) -> void:
	if _internal_hud:
		_internal_hud.show_building_ring(building)

func hide_building_ring() -> void:
	if _internal_hud:
		_internal_hud.hide_building_ring()

func show_game_over() -> void:
	if _internal_hud:
		_internal_hud.show_game_over()
