extends Node3D

var terrain: StaticBody3D
var defence_objective: Area3D
var player: CharacterBody3D

func _ready() -> void:
	# Boost global gravity programmatically (optional but effective)
	ProjectSettings.set_setting("physics/3d/default_gravity", 19.6)
	
	spawn_environment()
	spawn_sunlight()


	# Must happen in this order
	spawn_terrain()
	spawn_objectives()


	spawn_walls()
	spawn_enemies()
	spawn_player()
	spawn_hud()
	spawn_tower()

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
	add_child(defence_objective)
	print("Defence objective spawned at goal.")

	# Enemy spawn markers
	var enemy_spawn_script = load("res://scripts/enemy_spawn.gd")
	for i in range(terrain.road_starts.size()):
		var start: Vector2i = terrain.road_starts[i]
		assert(terrain._in_bounds(start))
		var pos_enemy_spawn : Vector3 = terrain._grid_to_world(start, half_w, half_d)
		var spawn_y: float = terrain.get_height_at(pos_enemy_spawn.x, pos_enemy_spawn.z)
		var enemy_spawn := Node3D.new()
		enemy_spawn.name = "EnemySpawn_%d" % i
		enemy_spawn.position = Vector3(pos_enemy_spawn.x, spawn_y + 2.0, pos_enemy_spawn.z)
		enemy_spawn.set_script(enemy_spawn_script)
		add_child(enemy_spawn)
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
	print("Player spawned with first-person camera.")

func spawn_hud() -> void:
	var canvas = CanvasLayer.new()
	var crosshair = ColorRect.new()
	
	# Small 4x4 dot in the center
	crosshair.size = Vector2(4, 4)
	crosshair.color = Color.WHITE
	
	# Use standard layout properties to center it
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.grow_horizontal = Control.GROW_DIRECTION_BOTH
	crosshair.grow_vertical = Control.GROW_DIRECTION_BOTH
	
	canvas.add_child(crosshair)
	
	# --- Objective HP Label ---
	var hp_label := Label.new()
	hp_label.name = "HPLabel"
	hp_label.set_anchors_preset(Control.PRESET_TOP_LEFT)
	hp_label.position = Vector2(20, 20)
	hp_label.add_theme_font_size_override("font_size", 32)
	
	# Initial value
	if defence_objective:
		hp_label.text = "Objective HP: %d / %d" % [defence_objective.current_hp, defence_objective.max_hp]
		defence_objective.hp_changed.connect(func(curr, max_hp):
			hp_label.text = "Objective HP: %d / %d" % [curr, max_hp]
		)
		defence_objective.game_over.connect(_on_game_over)
	
	canvas.add_child(hp_label)
	
	add_child(canvas)
	print("Crosshair and HP Label spawned.")

func _on_game_over() -> void:
	if player:
		player._is_locked = true
	
	var canvas = CanvasLayer.new()
	canvas.layer = 100 # Ensure it's on top
	
	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.7)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(overlay)
	
	var center_container = CenterContainer.new()
	center_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(center_container)
	
	var v_box = VBoxContainer.new()
	center_container.add_child(v_box)
	
	var label = Label.new()
	label.text = "GAME OVER"
	label.add_theme_font_size_override("font_size", 64)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v_box.add_child(label)
	
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	v_box.add_child(spacer)
	
	var restart_button = Button.new()
	restart_button.text = "RESTART"
	restart_button.custom_minimum_size = Vector2(200, 60)
	restart_button.add_theme_font_size_override("font_size", 32)
	restart_button.pressed.connect(func():
		get_tree().reload_current_scene()
	)
	v_box.add_child(restart_button)
	
	var quit_spacer = Control.new()
	quit_spacer.custom_minimum_size = Vector2(0, 10)
	v_box.add_child(quit_spacer)
	
	var quit_button = Button.new()
	quit_button.text = "QUIT"
	quit_button.custom_minimum_size = Vector2(200, 60)
	quit_button.add_theme_font_size_override("font_size", 32)
	quit_button.pressed.connect(func():
		get_tree().quit()
	)
	v_box.add_child(quit_button)
	
	add_child(canvas)
	
	# Unlock mouse
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func spawn_enemies() -> void:
	var rng = RandomNumberGenerator.new()
	var start_positions: Array = terrain.get_start_world_positions()
	if start_positions.size() == 0:
		print("No road starts — skipping enemy spawn.")
		return

	var enemy_script = load("res://scripts/enemy.gd")

	for i in range(30):
		var enemy = RigidBody3D.new()
		# Pick a random road start and offset slightly so they don't all stack
		var start_pos: Vector3 = start_positions[rng.randi_range(0, start_positions.size() - 1)]
		var x: float = start_pos.x + rng.randf_range(-2.0, 2.0)
		var z: float = start_pos.z + rng.randf_range(-2.0, 2.0)
		var y: float = terrain.get_height_at(x, z) + 2.0
		enemy.position = Vector3(x, y, z)
		enemy.mass = 1.0
		enemy.name = "Enemy_" + str(i)
		enemy.collision_layer = 2 # Layer 2
		enemy.collision_mask = 1 | 2 | 4 # Ground, Enemies, Player

		# Attach the enemy AI script
		enemy.set_script(enemy_script)
		enemy.terrain = terrain
		enemy.defence_objective = defence_objective
	
		# Mesh
		var mesh_instance = MeshInstance3D.new()
		var capsule_mesh = CapsuleMesh.new()
		var mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.85, 0.85, 0.85)
		capsule_mesh.material = mat
		mesh_instance.mesh = capsule_mesh
		enemy._material = mat
		enemy.add_child(mesh_instance)
		
		# Collision
		var collision_shape = CollisionShape3D.new()
		var shape = CapsuleShape3D.new()
		collision_shape.shape = shape
		enemy.add_child(collision_shape)

		add_child(enemy)

func spawn_walls() -> void:
	var wall_height = 30.0
	var wall_thickness = 1.0

	# Derive terrain half-extents from the terrain node
	var half_w: float = (terrain.terrain_width - 1) * terrain.cell_size * 0.5
	var half_d: float = (terrain.terrain_depth - 1) * terrain.cell_size * 0.5
	var terrain_w: float = half_w * 2.0
	var terrain_d: float = half_d * 2.0

	var wall_material = StandardMaterial3D.new()
	wall_material.albedo_color = Color(0.3, 0.3, 0.3) # Dark grey
	wall_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wall_material.albedo_color.a = 0.5 # Semi-transparent

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

func spawn_tower() -> void:
	var tower = StaticBody3D.new()
	# Place at terrain center, sunk slightly so the base blends into the ground
	var tower_x := 0.0
	var tower_z := 0.0
	var tower_y: float = terrain.get_height_at(tower_x, tower_z) - 2.0
	tower.position = Vector3(tower_x, tower_y, tower_z)
	tower.set_script(load("res://scripts/tower.gd"))
	
	add_child(tower)
	print("Tower spawned in the middle of the terrain.")
