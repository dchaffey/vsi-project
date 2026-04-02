extends Node3D

var terrain: StaticBody3D
var defence_objective: Area3D
var player: CharacterBody3D
var hud: CanvasLayer
var enemy_spawns: Array = []  # all EnemySpawn nodes — populated in spawn_objectives

## Wave system state
var _waves: Array = []             # parsed wave defs: [{enemy_count, spawn_rate}, ...]
var _current_wave: int = 0         # index into _waves
var _spawned_this_wave: int = 0    # enemies spawned so far in current wave
var _spawn_robin: int = 0          # round-robin index across spawn points
var _spawn_timer: Timer            # fires at wave's spawn rate
var _wave_delay_timer: Timer       # 5-second pause between waves

func _ready() -> void:
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
	spawn_hud()
	_load_waves("res://assets/levels/lvl1.csv")
	_init_wave_timers()
	_start_wave(0)
	# spawn_flow_debug()


# func _process(delta: float) -> void:
# 	print("FPS %d" % Engine.get_frames_per_second())

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

	# Enemy spawn markers — each node owns per-spawn enemy creation
	var enemy_spawn_script = load("res://scripts/enemy_spawn.gd")
	for i in range(terrain.road_starts.size()):
		var start: Vector2i = terrain.road_starts[i]
		assert(terrain._in_bounds(start))
		var pos_enemy_spawn: Vector3 = terrain._grid_to_world(start, half_w, half_d)
		var spawn_y: float = terrain.get_height_at(pos_enemy_spawn.x, pos_enemy_spawn.z)
		var enemy_spawn := Node3D.new()
		enemy_spawn.name = "EnemySpawn_%d" % i
		enemy_spawn.position = Vector3(pos_enemy_spawn.x, spawn_y + 2.0, pos_enemy_spawn.z)
		enemy_spawn.set_script(enemy_spawn_script)
		add_child(enemy_spawn)
		enemy_spawn.terrain = terrain
		enemy_spawn.defence_objective = defence_objective
		enemy_spawns.append(enemy_spawn)
	print("Enemy spawns placed.")

func spawn_environment() -> void:
	var world_env = WorldEnvironment.new()
	var env = Environment.new()
	
	# Add a sky
	var sky = Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	env.sky = sky
	env.background_mode = Environment.BG_SKY
	
	world_env.environment = env
	add_child(world_env)
	print("Environment spawned.")

func spawn_sunlight() -> void:
	var sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 45, 0)
	sun.shadow_enabled = true
	add_child(sun)
	print("Sun light spawned.")

func spawn_terrain() -> void:
	var terrain_scene := preload("res://scenes/terrain.tscn")
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
	player.set_script(load("res://scripts/player_controller.gd"))
	
	add_child(player)
	player.terrain = terrain
	print("Player spawned with first-person camera.")

func spawn_hud() -> void:
	hud = CanvasLayer.new()
	hud.set_script(load("res://scripts/hud.gd"))
	add_child(hud)
	hud.initialize(player, defence_objective)
	print("HUD spawned and initialized.")

## Passes the player reference to every enemy spawn so death rewards work.
func _assign_player_to_spawns() -> void:
	for spawn_node in enemy_spawns:
		spawn_node.player = player


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


## Create the two timers used by the wave system.
func _init_wave_timers() -> void:
	_spawn_timer = Timer.new()
	_spawn_timer.one_shot = false
	_spawn_timer.timeout.connect(_on_spawn_tick)
	add_child(_spawn_timer)

	_wave_delay_timer = Timer.new()
	_wave_delay_timer.one_shot = true
	_wave_delay_timer.wait_time = 10.0
	_wave_delay_timer.timeout.connect(_on_wave_delay_done)
	add_child(_wave_delay_timer)


## Begin spawning enemies for the given wave index.
func _start_wave(index: int) -> void:
	assert(index < _waves.size(), "Wave index out of bounds")
	_current_wave = index
	_spawned_this_wave = 0
	var wave = _waves[index]
	_spawn_timer.wait_time = 1.0 / wave.spawn_rate # interval per enemy
	_spawn_timer.start()
	if hud:
		hud.update_wave(index + 1, _waves.size())
	print("Wave %d: %d enemies at %d/sec" % [index + 1, wave.enemy_count, wave.spawn_rate])


## Spawn one enemy per tick, round-robin across spawn points.
func _on_spawn_tick() -> void:
	var wave = _waves[_current_wave]
	var spawn_node = enemy_spawns[_spawn_robin % enemy_spawns.size()]
	var enemy = spawn_node.create_enemy()
	add_child(enemy)
	_spawn_robin += 1
	_spawned_this_wave += 1

	if _spawned_this_wave >= wave.enemy_count:
		_spawn_timer.stop()
		if _current_wave + 1 < _waves.size():
			_wave_delay_timer.start()
			print("Wave %d complete. Next wave in 5 seconds." % [_current_wave + 1])
		else:
			print("All waves complete.")


## Start the next wave after the inter-wave delay.
func _on_wave_delay_done() -> void:
	_start_wave(_current_wave + 1)


func _on_game_over() -> void:
	_spawn_timer.stop()
	_wave_delay_timer.stop()

	if player:
		player._is_locked = true

	if hud:
		hud.show_game_over()


var _flow_debug_mi: MeshInstance3D
var _flow_debug_mat: StandardMaterial3D

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
	var wall_height = 30.0 # Reduced to 30 units — game board aesthetic
	var wall_thickness = 1.0
	var base_height = 2.0 # Floor platform height

	# Derive terrain half-extents from the terrain node
	var half_w: float = (terrain.terrain_width - 1) * terrain.cell_size * 0.5
	var half_d: float = (terrain.terrain_depth - 1) * terrain.cell_size * 0.5
	var terrain_w: float = half_w * 2.0
	var terrain_d: float = half_d * 2.0

	var wall_material = StandardMaterial3D.new()
	wall_material.albedo_color = Color(0.3, 0.3, 0.3) # Dark grey

	# Create base floor platform — much larger for VR standing space
	var base_platform = StaticBody3D.new()
	base_platform.position = Vector3(0, -base_height / 2.0, 0) # Positioned so top sits at y=0
	base_platform.collision_layer = 1

	var vr_floor_size = 500.0 # Large area for VR player to stand on

	var floor_mesh = MeshInstance3D.new()
	var floor_box = BoxMesh.new()
	floor_box.size = Vector3(vr_floor_size, base_height, vr_floor_size)
	floor_mesh.mesh = floor_box

	var floor_material = StandardMaterial3D.new()
	floor_material.albedo_color = Color(0.3, 0.3, 0.3) # Dark grey
	floor_mesh.material_override = floor_material
	base_platform.add_child(floor_mesh)

	var floor_collision = CollisionShape3D.new()
	var floor_shape = BoxShape3D.new()
	floor_shape.size = Vector3(vr_floor_size, base_height, vr_floor_size)
	floor_collision.shape = floor_shape
	base_platform.add_child(floor_collision)

	add_child(base_platform)

	# Wall data: [position, size]
	var walls = [
		[Vector3(0, wall_height / 2, -half_d), Vector3(terrain_w, wall_height, wall_thickness)], # North
		[Vector3(0, wall_height / 2, half_d), Vector3(terrain_w, wall_height, wall_thickness)],  # South
		[Vector3(-half_w, wall_height / 2, 0), Vector3(wall_thickness, wall_height, terrain_d)], # West
		[Vector3(half_w, wall_height / 2, 0), Vector3(wall_thickness, wall_height, terrain_d)],  # East
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
