#working
extends Node3D

## MODE TOGGLE INSTRUCTIONS:
## 1. DESKTOP MODE (Default):
##    - Set ENABLE_VR = false (below).
##    - In project.godot: [rendering] xr/enabled=false, vrs/mode=0.
## 2. VR MODE:
##    - Set ENABLE_VR = true (below).
##    - (Optional but recommended for performance) In project.godot: [rendering] xr/enabled=true, vrs/mode=2.

const ENABLE_VR := true  # toggles VR startup behavior and script selection
const Button3D := preload("res://scripts/ui/button_3d.gd")  # VR+mouse button script preload (avoid class_name cache)

## Persists across scene reloads so retry/quit-to-menu work without an autoload.
static var _selected_level: int = 0  # 0 = show selector; 1/2/3 = level in progress

var terrain: StaticBody3D
var defence_objective: Area3D
var player: CharacterBody3D
var game_board: Node3D
var enemy_spawn: Node3D       # single spawn point for all waves
var is_vr_enabled := false
var is_passthrough := true    # enable MR passthrough when VR headset is detected
var _start_xr: Node = null    # reference to StartXR node for runtime passthrough toggle

## Level selector HUD shown before gameplay starts.
var _level_selector_hud: Node3D

## Wave system state
var _waves: Array = []         # parsed wave defs: [{enemy_count, spawn_rate}, ...]
var _current_wave: int = -1    # index of wave currently running; -1 before the first wave starts
var _next_wave_index: int = 0  # index the 3D next-wave button will start on click
var _alive_enemies: int = 0    # enemies still alive this wave — hits 0 → expose next-wave button
var _spawned_this_wave: int = 0  # how many have been spawned so far this wave
var _spawn_timer: Timer        # fires at wave's spawn rate

## 3D wave HUD state
var _wave_hud: Node3D            # container anchoring both wave label and next-wave button above the field
var _wave_label_3d: Label3D      # static-rotation readout "Wave X / Y"
var _next_wave_button: Node3D  # player-initiated wave advance — VR + mouse interactable
var _retry_button: Node3D  # always-available retry button shown during waves
var _quit_button: Node3D   # returns to level selector during active waves

func _ready() -> void:
	# Do NOT manually toggle get_viewport().use_xr here. Setting it to false at startup
	# tells the renderer "no stereo" and prevents multiview shader variants (tonemapper,
	# glow, etc.) from being compiled. When XR then succeeds and use_xr flips to true,
	# the missing variants cause null-shader errors and a black screen. StartXR (from
	# godot-xr-tools) sets use_xr correctly inside its own _ready() — let it.
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
		is_vr_enabled = false  # explicit desktop mode latch so spawn_player never picks the VR script
		print("VR manually disabled via ENABLE_VR. Desktop mode active.")

	# Boost global gravity programmatically (optional but effective)
	ProjectSettings.set_setting("physics/3d/default_gravity", 19.6)

	print("[World] _ready() done. _selected_level=%d is_vr_enabled=%s" % [_selected_level, is_vr_enabled])

	if _selected_level == 0:
		_spawn_level_selector()
		return

	spawn_environment()
	spawn_sunlight()

	# Must happen in this order
	spawn_terrain()
	spawn_objectives()
	spawn_walls()
	spawn_player()
	_assign_player_to_spawns() # player ref needed for death rewards
	await spawn_game_board()
	_load_waves("res://assets/levels/lvl%d.csv" % _selected_level)
	_init_wave_timers()
	_spawn_wave_hud()
	_show_next_wave_button()  # initial state — player must click to start wave 1
	spawn_flow_debug()


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
	var terrain_scene: PackedScene = load("res://scenes/lvl%d.tscn" % _selected_level)
	terrain = terrain_scene.instantiate()
	add_child(terrain)
	print("Terrain spawned (level %d)." % _selected_level)

func spawn_player() -> void:
	player = CharacterBody3D.new()
	var spawn_y: float = terrain.get_height_at(0.0, 0.0) + 3.0
	player.position = Vector3(0, spawn_y, 0)
	player.name = "Player"
	player.collision_layer = 4 # Layer 3 (bit 2^2=4)
	player.collision_mask = 1 | 2 # Detect Ground and Enemies
	
	# Only attach script; Player builds itself in _ready()
	if ENABLE_VR and is_vr_enabled:
		player.set_script(load("res://scripts/vr_player.gd"))
	else:
		player.set_script(load("res://scripts/player_controller.gd"))
	
	add_child(player)
	player.add_to_group("player")  # allows other nodes to locate the player via group lookup
	player.terrain = terrain
	if not (ENABLE_VR and is_vr_enabled):
		call_deferred("_ensure_desktop_camera_current")
	print("Player spawned with first-person camera.")

func _ensure_desktop_camera_current() -> void:
	# Re-assert desktop camera ownership in case another camera became current during scene setup.
	var desktop_camera := player.get_node_or_null("Camera3D") as Camera3D
	assert(desktop_camera != null, "Desktop player must create Camera3D")
	desktop_camera.make_current()

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
	_build_retry_button()
	_build_quit_button()


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


func _build_next_wave_button() -> void:
	# Button3D handles VR pointer + mouse input uniformly; emits clicked on confirmed press.
	_next_wave_button = Button3D.new()
	_next_wave_button.size = Vector3(24.0, 6.0, 6.0)  # generous hit area for both VR ray and mouse
	_wave_hud.add_child(_next_wave_button)
	_next_wave_button.clicked.connect(_on_next_wave_clicked)


func _build_retry_button() -> void:
	# Persistent retry button shown during active waves — Button3D fires clicked on VR or mouse.
	_retry_button = Button3D.new()
	_retry_button.text = "RETRY"
	_retry_button.size = Vector3(8.0, 6.0, 6.0)
	_wave_hud.add_child(_retry_button)
	_retry_button.clicked.connect(_on_retry_clicked)
	_retry_button.visible = false  # shown only during active waves

func _build_quit_button() -> void:
	_quit_button = Button3D.new()
	_quit_button.text = "QUIT TO MENU"
	_quit_button.size = Vector3(12.0, 6.0, 6.0)
	_quit_button.position = Vector3(0.0, -8.0, 0.0)
	_quit_button.base_color = Color(1.0, 0.3, 0.3)  # red to distinguish from retry
	_wave_hud.add_child(_quit_button)
	_quit_button.clicked.connect(_on_quit_to_menu_clicked)
	_quit_button.visible = false  # shown only during active waves


func _on_retry_clicked() -> void:
	# Reload keeping _selected_level so the same level restarts.
	get_tree().reload_current_scene()

func _on_quit_to_menu_clicked() -> void:
	_selected_level = 0
	get_tree().reload_current_scene()


func _on_next_wave_clicked() -> void:
	# Advance to the pending wave; guarded so end-of-game state can't trigger an extra wave.
	if _next_wave_index >= _waves.size():
		return
	_hide_next_wave_button()
	_start_wave(_next_wave_index)


func _show_next_wave_button() -> void:
	# Reveal the button with text naming the wave that will start on click.
	assert(_next_wave_index < _waves.size(), "No more waves — should not show button")
	_next_wave_button.set_text("START WAVE %d" % (_next_wave_index + 1))
	_next_wave_button.visible = true
	_retry_button.visible = false
	_quit_button.visible = false


func _hide_next_wave_button() -> void:
	_next_wave_button.visible = false
	_retry_button.visible = true
	_quit_button.visible = true  # show quit during active wave


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
			_show_end_game_menu()
			print("All waves complete.")


func _show_end_game_menu() -> void:
	_hide_next_wave_button()
	_retry_button.visible = false
	_quit_button.visible = false

	# "NEXT LEVEL" advances to the next level; wraps back to selector if at the last level.
	var next_button := Button3D.new()
	next_button.text = "NEXT LEVEL"
	next_button.size = Vector3(10.0, 6.0, 6.0)
	_wave_hud.add_child(next_button)
	next_button.position = Vector3(0.0, -8.0, 0.0)
	next_button.clicked.connect(func():
		var next_lvl := _selected_level + 1
		_selected_level = next_lvl if next_lvl <= 3 else 0
		get_tree().reload_current_scene()
	)

	var menu_button := Button3D.new()
	menu_button.text = "LEVEL SELECT"
	menu_button.size = Vector3(10.0, 6.0, 6.0)
	menu_button.base_color = Color(1.0, 0.3, 0.3)
	_wave_hud.add_child(menu_button)
	menu_button.position = Vector3(0.0, -16.0, 0.0)
	menu_button.clicked.connect(func():
		_selected_level = 0
		get_tree().reload_current_scene()
	)


func _on_game_over() -> void:
	_spawn_timer.stop()
	_next_wave_button.visible = false
	_retry_button.visible = true
	_quit_button.visible = true

	if player:
		player._is_locked = true

	if game_board:
		game_board.show_game_over()


## Level selector — shown at startup when _selected_level == 0.
func _spawn_level_selector() -> void:
	print("[LevelSelector] _spawn_level_selector() called. is_vr_enabled=%s ENABLE_VR=%s" % [is_vr_enabled, ENABLE_VR])
	spawn_environment()
	spawn_sunlight()

	_level_selector_hud = Node3D.new()
	add_child(_level_selector_hud)

	var title := Label3D.new()
	title.text = "SELECT LEVEL"
	title.pixel_size = 0.05
	title.font_size = 96
	title.outline_size = 16
	title.modulate = Color(1.0, 1.0, 0.5)
	title.no_depth_test = true
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector3(0.0, 6.0, 0.0)
	_level_selector_hud.add_child(title)

	for i in range(3):
		var level_num := i + 1
		var btn := Button3D.new()
		btn.text = "LEVEL %d" % level_num
		btn.size = Vector3(12.0, 6.0, 6.0)
		btn.position = Vector3(0.0, -i * 9.0, 0.0)
		_level_selector_hud.add_child(btn)
		btn.clicked.connect(_on_level_selected.bind(level_num))

	if ENABLE_VR and is_vr_enabled:
		_spawn_level_selector_xr()
	else:
		print("[LevelSelector] Desktop mode — spawning fallback camera.")
		var cam_node := Node3D.new()
		cam_node.position = Vector3(0.0, 5.0, 5.0)
		add_child(cam_node)
		var cam := Camera3D.new()
		cam_node.add_child(cam)
		cam.make_current()
		_level_selector_hud.position = Vector3(0.0, 5.0, -10.0)
		print("[LevelSelector] Desktop camera at %s, HUD at %s" % [cam_node.position, _level_selector_hud.position])


## Spawns the minimal XR rig needed to see the level selector in VR (no terrain/player yet).
## Mirrors the essential parts of vr_player._ready() so the HMD + laser pointer work.
func _spawn_level_selector_xr() -> void:
	const WORLD_SCALE := 60.0  # must match vr_player.WORLD_SCALE

	var xr_origin := XROrigin3D.new()
	xr_origin.name = "XROrigin3D"
	xr_origin.world_scale = WORLD_SCALE
	add_child(xr_origin)

	var cam := XRCamera3D.new()
	xr_origin.add_child(cam)

	var right_hand := XRController3D.new()
	right_hand.tracker = "right_hand"
	xr_origin.add_child(right_hand)

	var left_hand := XRController3D.new()
	left_hand.tracker = "left_hand"
	xr_origin.add_child(left_hand)

	# Laser pointer for clicking Button3D UI elements (same wiring as vr_player).
	var pointer_scene = preload("res://addons/godot-xr-tools/functions/function_pointer.tscn")
	var laser := pointer_scene.instantiate()
	laser.set_collide_with_areas(true)
	right_hand.add_child(laser)
	if "distance" in laser:
		laser.distance = 100.0 * WORLD_SCALE
	if "target_radius" in laser:
		laser.target_radius *= WORLD_SCALE

	# With world_scale=60, physical 1.7m head height → ~102 world units.
	# Place HUD at eye height (~100 wu) and 1 m physical forward (60 wu).
	_level_selector_hud.position = Vector3(0.0, 100.0, -60.0)
	print("[LevelSelector] XR rig spawned. HUD at %s (world_scale=%.0f)" % [_level_selector_hud.position, WORLD_SCALE])


func _on_level_selected(level: int) -> void:
	print("[LevelSelector] Level %d selected. Reloading scene." % level)
	_selected_level = level
	get_tree().reload_current_scene()


var _flow_debug_mi: MeshInstance3D
var _flow_debug_mat: StandardMaterial3D
var _fullscreen_pressed := false  # tracks L key state for toggle

## Draws the A* road paths as red lines above the terrain for debugging.
func spawn_flow_debug() -> void:
	_flow_debug_mi = MeshInstance3D.new()
	_flow_debug_mi.name = "PathDebug"
	_flow_debug_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_flow_debug_mat = StandardMaterial3D.new()
	_flow_debug_mat.albedo_color = Color(1.0, 0.2, 0.2)
	_flow_debug_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flow_debug_mat.no_depth_test = true
	_flow_debug_mi.material_override = _flow_debug_mat

	add_child(_flow_debug_mi)
	_rebuild_flow_debug()
	print("Path debug lines spawned.")

func _rebuild_flow_debug() -> void:
	var paths: Array = terrain.get_road_paths_world()
	var lift: float = 0.5

	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for path in paths:
		for i in range(path.size() - 1):
			var a: Vector3 = path[i]
			var b: Vector3 = path[i + 1]
			mesh.surface_add_vertex(Vector3(a.x, a.y + lift, a.z))
			mesh.surface_add_vertex(Vector3(b.x, b.y + lift, b.z))
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
