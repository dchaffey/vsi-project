extends Node3D

## MODE TOGGLE INSTRUCTIONS:
## 1. DESKTOP MODE (Default):
##    - Set ENABLE_VR = false (below).
##    - In project.godot: [rendering] xr/enabled=false, vrs/mode=0.
## 2. VR MODE:
##    - Set ENABLE_VR = true (below).
##    - (Optional but recommended for performance) In project.godot: [rendering] xr/enabled=true, vrs/mode=2.

const ENABLE_VR := false

var terrain: StaticBody3D
var defence_objective: Area3D
var player: CharacterBody3D
var game_board: Node3D
var enemy_spawn: Node3D       # single spawn point for all waves
var is_vr_enabled := false
var is_passthrough := true    # enable MR passthrough when VR headset is detected
var _start_xr: Node = null    # reference to StartXR node for runtime passthrough toggle

## Wave system state
var _waves: Array = []         # parsed wave defs: [{enemy_count, spawn_rate}, ...]
var _current_wave: int = -1    # index of wave currently running; -1 before the first wave starts
var _next_wave_index: int = 0  # index the 3D next-wave button will start on click
var _alive_enemies: int = 0    # enemies still alive this wave — hits 0 → expose next-wave button
var _spawned_this_wave: int = 0  # how many have been spawned so far this wave
var _spawn_timer: Timer        # fires at wave's spawn rate

## 3D wave HUD state
var _wave_hud: Node3D          # container anchoring both wave label and next-wave button above the field
var _wave_label_3d: Label3D    # static-rotation readout "Wave X / Y"
var _next_wave_button: Area3D  # clickable region with a Label3D child — player-initiated wave advance
var _next_wave_label: Label3D  # text on the next-wave button, e.g. "START WAVE 3"

func _ready() -> void:
	# Immediately disable XR to avoid black screen on desktop fallback.
	# We will re-enable it only if XR initialization succeeds.
	get_viewport().use_xr = false
	
	if ENABLE_VR:
		var xr_interface = XRServer.find_interface("OpenXR")
		if xr_interface:
			print("OpenXR interface found. Attempting to initialize VR...")
			var start_xr_scene := preload("res://addons/godot-xr-tools/xr/start_xr.tscn")
			_start_xr = start_xr_scene.instantiate()
			_start_xr.enable_passthrough = is_passthrough
			add_child(_start_xr)  # This triggers StartXR._ready() which calls initialize()
			
			# Give StartXR a frame to complete its internal initialization
			await get_tree().process_frame
			
			if xr_interface.is_initialized():
				is_vr_enabled = true
				is_passthrough = _start_xr.enable_passthrough
				
				# Successfully initialized, now we can enable XR on the viewport
				get_viewport().use_xr = true
				
				# Docs recommendation: Disable VSync to prevent frame capping by desktop monitor
				DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
				
				# Docs recommendation: Match physics ticks to HMD refresh rate (Quest 3 default is ~90Hz)
				Engine.physics_ticks_per_second = 90
				
				print("OpenXR initialized successfully. VR mode active (90Hz Physics, VSync Disabled).")
			else:
				print("OpenXR failed to initialize. Falling back to desktop mode.")
				# Clean up the XR start node
				_start_xr.queue_free()
				_start_xr = null
		else:
			print("OpenXR interface not found. Desktop mode active.")
	else:
		print("VR manually disabled via ENABLE_VR. Desktop mode active.")

	# Boost global gravity programmatically (optional but effective)
	ProjectSettings.set_setting("physics/3d/default_gravity", 19.6)
	
	spawn_environment()
	spawn_sunlight()

	# Must happen in this order
	spawn_terrain()
	spawn_objectives()
	spawn_walls()
	spawn_player()
	_assign_player_to_spawns() # player ref needed for death rewards
	await spawn_game_board()
	_load_waves("res://assets/levels/lvl1.csv")
	_init_wave_timers()
	_spawn_wave_hud()
	_show_next_wave_button()  # initial state — player must click to start wave 1
	# spawn_flow_debug()


func _process(delta: float) -> void:
	var l_pressed = Input.is_key_pressed(KEY_L)
	if l_pressed and not _fullscreen_pressed:
		var mode = DisplayServer.window_get_mode()
		if mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	_fullscreen_pressed = l_pressed

func spawn_objectives() -> void:
	# Half-extents (same as mesh construction) for grid -> world conversion
	assert(terrain != null, "Terrain should be initialized before.")

	var half_w: float = (terrain.terrain_width - 1) * terrain.cell_size * 0.5
	var half_d: float = (terrain.terrain_depth - 1) * terrain.cell_size * 0.5

	# Defence objective cube at the goal position
	assert(terrain._in_bounds(terrain.road_goal), "We should assume that positions have been places correctly.")
	var pos_def_obj : Vector3 = terrain._grid_to_world(terrain.road_goal, half_w, half_d)
	defence_objective = Area3D.new()
	defence_objective.name = "DefenceObjective"
	var goal_y: float = terrain.get_height_at(pos_def_obj.x, pos_def_obj.z)
	defence_objective.position = Vector3(pos_def_obj.x, goal_y + 2.0, pos_def_obj.z)
	defence_objective.set_script(load("res://scripts/defence_objective.gd"))
	defence_objective.game_over.connect(_on_game_over)
	add_child(defence_objective)
	print("Defence objective spawned at goal.")

	var start: Vector2i = terrain.road_starts[0]
	assert(terrain._in_bounds(start))
	var pos_enemy_spawn: Vector3 = terrain._grid_to_world(start, half_w, half_d)
	var spawn_y: float = terrain.get_height_at(pos_enemy_spawn.x, pos_enemy_spawn.z)
	enemy_spawn = Node3D.new()
	enemy_spawn.name = "EnemySpawn"
	enemy_spawn.position = Vector3(pos_enemy_spawn.x, spawn_y + 2.0, pos_enemy_spawn.z)
	enemy_spawn.set_script(load("res://scripts/enemy_spawn.gd"))
	add_child(enemy_spawn)
	enemy_spawn.terrain = terrain
	enemy_spawn.defence_objective = defence_objective
	print("Enemy spawn placed.")

func spawn_environment() -> void:
	var world_env = WorldEnvironment.new()
	var env = Environment.new()

	if is_vr_enabled and is_passthrough:
		# Transparent background lets the camera passthrough feed show
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0, 0, 0, 0)
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		env.ambient_light_color = Color(0.6, 0.6, 0.6)  # compensate for missing sky ambient
		env.ambient_light_energy = 0.5
	else:
		var sky = Sky.new()
		sky.sky_material = ProceduralSkyMaterial.new()
		env.sky = sky
		env.background_mode = Environment.BG_SKY
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		env.ambient_light_energy = 0.7 # Reduced from default 1.0

	world_env.environment = env
	add_child(world_env)
	print("Environment spawned.")

func spawn_sunlight() -> void:
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 45, 0)
	sun.shadow_enabled = true
	sun.light_energy = 0.8 # Reduced from default 1.0
	add_child(sun)
	print("Sun light spawned.")

func spawn_terrain() -> void:
	var terrain_scene := preload("res://scenes/lvl2.tscn")
	terrain = terrain_scene.instantiate()
	add_child(terrain)
	print("Terrain spawned.")

func spawn_player() -> void:
	player = CharacterBody3D.new()
	var spawn_y: float = terrain.get_height_at(0.0, 0.0) + 3.0
	player.position = Vector3(0, spawn_y, 0)
	player.name = "Player"
	player.collision_layer = 4 # Layer 3 (bit 2^2=4)
	player.collision_mask = 1 | 2 # Detect Ground and Enemies
	
	# Only attach script; Player builds itself in _ready()
	if is_vr_enabled:
		player.set_script(load("res://scripts/vr_player.gd"))
	else:
		player.set_script(load("res://scripts/player_controller.gd"))
	
	add_child(player)
	player.add_to_group("player")  # allows other nodes to locate the player via group lookup
	player.terrain = terrain
	print("Player spawned with first-person camera.")

func spawn_game_board() -> void:
	game_board = Node3D.new()
	game_board.set_script(load("res://scripts/game_board.gd"))
	add_child(game_board)
	await game_board.initialize(player, defence_objective, terrain, is_vr_enabled)
	player.game_board = game_board
	print("GameBoard spawned and initialized.")

func _assign_player_to_spawns() -> void:
	enemy_spawn.player = player  # player ref needed for death rewards


## Parse a tab-separated wave file into _waves array.
func _load_waves(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	assert(file != null, "Failed to open wave file: " + path)
	file.get_line() # skip header row
	while not file.eof_reached():
		var line := file.get_line().strip_edges()
		if line.is_empty():
			continue
		var cols := line.split(",")
		assert(cols.size() >= 3, "Wave line needs 3 columns: " + line)
		_waves.append({
			"enemy_count": int(cols[1]),
			"spawn_rate": float(cols[2]),
		})
	file.close()
	assert(_waves.size() > 0, "No waves found in " + path)
	print("Loaded %d waves from %s" % [_waves.size(), path])


## Create the spawn timer used by the wave system.
func _init_wave_timers() -> void:
	_spawn_timer = Timer.new()
	_spawn_timer.one_shot = false
	_spawn_timer.timeout.connect(_on_spawn_tick)
	add_child(_spawn_timer)


## Build the 3D wave HUD (wave readout + next-wave button) hovering above the field.
func _spawn_wave_hud() -> void:
	assert(terrain != null, "Terrain must be built before the wave HUD is spawned.")
	var hud_y: float = terrain.max_height + 30.0
	_wave_hud = Node3D.new()
	_wave_hud.position = Vector3(0.0, hud_y, 0.0)
	add_child(_wave_hud)
	_build_wave_label_3d()
	_build_next_wave_button()


func _build_wave_label_3d() -> void:
	# Static-rotation wave readout — player can see progress without moving the camera.
	_wave_label_3d = Label3D.new()
	_wave_label_3d.text = "Wave 0 / %d" % _waves.size()
	_wave_label_3d.position = Vector3(0.0, 6.0, 0.0)
	_wave_label_3d.pixel_size = 0.05
	_wave_label_3d.font_size = 96
	_wave_label_3d.outline_size = 16
	_wave_label_3d.modulate = Color(1.0, 1.0, 0.5)
	_wave_label_3d.no_depth_test = true
	_wave_label_3d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_wave_hud.add_child(_wave_label_3d)


const _NEXT_WAVE_BASE_COLOR := Color(0.25, 1.0, 0.4)  # resting color — matches tower upgrade green
const _NEXT_WAVE_HOVER_COLOR := Color(1.0, 0.95, 0.2)  # yellow — click affordance on mouse enter

func _build_next_wave_button() -> void:
	# Clickable Area3D + Label3D pair that gates wave progression on player input.
	_next_wave_button = Area3D.new()
	_next_wave_button.collision_layer = 1 << 20  # off the ground layer so placement raycasts ignore it
	_next_wave_button.collision_mask = 0
	_next_wave_button.input_ray_pickable = true
	_wave_hud.add_child(_next_wave_button)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(24.0, 6.0, 6.0)  # generous hit area so the button is easy to click
	col.shape = shape
	_next_wave_button.add_child(col)

	_next_wave_label = Label3D.new()
	_next_wave_label.pixel_size = 0.05
	_next_wave_label.font_size = 96
	_next_wave_label.outline_size = 16
	_next_wave_label.modulate = _NEXT_WAVE_BASE_COLOR
	_next_wave_label.no_depth_test = true
	_next_wave_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_next_wave_button.add_child(_next_wave_label)

	# Yellow hover feedback mirrors the tower menu buttons.
	_next_wave_button.mouse_entered.connect(func(): _next_wave_label.modulate = _NEXT_WAVE_HOVER_COLOR)
	_next_wave_button.mouse_exited.connect(func(): _next_wave_label.modulate = _NEXT_WAVE_BASE_COLOR)

	_next_wave_button.input_event.connect(_on_next_wave_input)


func _on_next_wave_input(_cam: Node, event: InputEvent, _pos: Vector3, _norm: Vector3, _idx: int) -> void:
	# Left-click on the 3D button consumes the event and advances to the pending wave.
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if _next_wave_index >= _waves.size():
		return
	_hide_next_wave_button()
	_start_wave(_next_wave_index)
	get_viewport().set_input_as_handled()


func _show_next_wave_button() -> void:
	# Reveal the button with text naming the wave that will start on click.
	assert(_next_wave_index < _waves.size(), "No more waves — should not show button")
	_next_wave_label.text = "START WAVE %d" % (_next_wave_index + 1)
	_next_wave_button.visible = true


func _hide_next_wave_button() -> void:
	_next_wave_button.visible = false


## Begin spawning enemies for the given wave index.
func _start_wave(index: int) -> void:
	assert(index < _waves.size(), "Wave index out of bounds")
	_current_wave = index
	_next_wave_index = index + 1
	_spawned_this_wave = 0
	_alive_enemies = _waves[index].enemy_count  # pre-set to full wave count; decremented on each death
	var wave = _waves[index]
	_spawn_timer.wait_time = 1.0 / wave.spawn_rate
	_spawn_timer.start()
	if _wave_label_3d:
		_wave_label_3d.text = "Wave %d / %d" % [index + 1, _waves.size()]
	print("Wave %d: %d enemies at %.1f/sec" % [index + 1, wave.enemy_count, wave.spawn_rate])


## Spawn one enemy per tick until the wave count is exhausted.
func _on_spawn_tick() -> void:
	var enemy: CharacterBody3D = enemy_spawn.create_enemy()
	add_child(enemy)
	enemy.died.connect(func(_m: float) -> void: _on_enemy_died())
	_spawned_this_wave += 1
	if _spawned_this_wave >= _waves[_current_wave].enemy_count:
		_spawn_timer.stop()


## Called when any wave enemy dies. Exposes the next-wave button when the wave is cleared.
func _on_enemy_died() -> void:
	assert(_alive_enemies > 0, "alive_enemies went negative — died signal fired too many times")
	_alive_enemies -= 1
	if _alive_enemies == 0:
		if _next_wave_index < _waves.size():
			_show_next_wave_button()
			print("Wave %d cleared. Press the 3D button to start wave %d." % [_current_wave + 1, _next_wave_index + 1])
		else:
			print("All waves complete.")


func _on_game_over() -> void:
	_spawn_timer.stop()
	_hide_next_wave_button()

	if player:
		player._is_locked = true

	if game_board:
		game_board.show_game_over()


var _flow_debug_mi: MeshInstance3D
var _flow_debug_mat: StandardMaterial3D
var _fullscreen_pressed := false  # tracks L key state for toggle

func spawn_flow_debug() -> void:
	_flow_debug_mi = MeshInstance3D.new()
	_flow_debug_mi.name = "FlowDebug"
	_flow_debug_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_flow_debug_mat = StandardMaterial3D.new()
	_flow_debug_mat.albedo_color = Color(1.0, 0.2, 0.2)
	_flow_debug_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flow_debug_mat.no_depth_test = true
	_flow_debug_mi.material_override = _flow_debug_mat

	add_child(_flow_debug_mi)
	_rebuild_flow_debug()
	terrain.flow_field_changed.connect(_rebuild_flow_debug)
	print("Flow debug arrows spawned.")

func _rebuild_flow_debug() -> void:
	var half_w: float = (terrain.terrain_width - 1) * terrain.cell_size * 0.5
	var half_d: float = (terrain.terrain_depth - 1) * terrain.cell_size * 0.5
	var step := 3
	var arrow_len := 1.5
	var lift := 0.3

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for gx in range(0, terrain.terrain_width, step):
		for gz in range(0, terrain.terrain_depth, step):
			var wx: float = gx * terrain.cell_size - half_w
			var wz: float = gz * terrain.cell_size - half_d
			var flow: Vector2 = terrain.get_flow_direction(wx, wz)
			if flow.length_squared() < 0.001:
				continue
			var wy: float = terrain.get_height_at(wx, wz) + lift
			var origin := Vector3(wx, wy, wz)
			var dir3 := Vector3(flow.x, 0, flow.y).normalized() * arrow_len
			var tip := origin + dir3

			# Shaft
			mesh.surface_add_vertex(origin)
			mesh.surface_add_vertex(tip)

			# Arrowhead wings
			var right := dir3.cross(Vector3.UP).normalized() * 0.3
			mesh.surface_add_vertex(tip)
			mesh.surface_add_vertex(tip - dir3 * 0.3 + right)
			mesh.surface_add_vertex(tip)
			mesh.surface_add_vertex(tip - dir3 * 0.3 - right)
	mesh.surface_end()
	_flow_debug_mi.mesh = mesh

func spawn_walls() -> void:
	var wall_height = terrain.max_height + 30.0 # Walls extend from terrain max height upward
	var wall_thickness = 1.0
	var base_height = 2.0 # Floor platform height

	# Derive terrain half-extents from the terrain node
	var half_w: float = (terrain.terrain_width - 1) * terrain.cell_size * 0.5
	var half_d: float = (terrain.terrain_depth - 1) * terrain.cell_size * 0.5
	var terrain_w: float = half_w * 2.0
	var terrain_d: float = half_d * 2.0

	var wall_material = StandardMaterial3D.new()
	wall_material.albedo_color = Color(0.3, 0.3, 0.3) # Dark grey

	# Wall data: [position, size] — walls extend from ground (y=0) downward
	var wall_base_y = -wall_height / 2.0
	var walls = [
		[Vector3(0, wall_base_y, -half_d), Vector3(terrain_w, wall_height, wall_thickness)], # North
		[Vector3(0, wall_base_y, half_d), Vector3(terrain_w, wall_height, wall_thickness)],  # South
		[Vector3(-half_w, wall_base_y, 0), Vector3(wall_thickness, wall_height, terrain_d)], # West
		[Vector3(half_w, wall_base_y, 0), Vector3(wall_thickness, wall_height, terrain_d)],  # East
	]

	for wall_data in walls:
		var pos = wall_data[0]
		var size = wall_data[1]

		var static_body = StaticBody3D.new()
		static_body.position = pos
		static_body.collision_layer = 1 # Ground layer

		# Mesh
		var mesh_instance = MeshInstance3D.new()
		var box_mesh = BoxMesh.new()
		box_mesh.size = size
		mesh_instance.mesh = box_mesh
		mesh_instance.material_override = wall_material
		static_body.add_child(mesh_instance)

		# Collision
		var collision_shape = CollisionShape3D.new()
		var shape = BoxShape3D.new()
		shape.size = size
		collision_shape.shape = shape
		static_body.add_child(collision_shape)

		add_child(static_body)

	print("Walls spawned around the terrain.")
