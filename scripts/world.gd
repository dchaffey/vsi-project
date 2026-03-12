extends Node3D

var terrain: StaticBody3D

func _ready() -> void:
	# Boost global gravity programmatically (optional but effective)
	ProjectSettings.set_setting("physics/3d/default_gravity", 19.6)
	
	spawn_environment()
	spawn_sunlight()
	spawn_terrain()
	spawn_walls()
	spawn_enemies()
	spawn_player()
	spawn_crosshair()
	spawn_tower()

# func _process(delta: float) -> void:
# 	print("FPS %d" % Engine.get_frames_per_second())

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
	var player = CharacterBody3D.new()
	var spawn_y: float = terrain.get_height_at(0.0, 0.0) + 3.0
	player.position = Vector3(0, spawn_y, 0)
	player.name = "Player"
	player.collision_layer = 4 # Layer 3 (bit 2^2=4)
	player.collision_mask = 1 | 2 # Detect Ground and Enemies
	
	# Only attach script; Player builds itself in _ready()
	player.set_script(load("res://scripts/player_controller.gd"))
	
	add_child(player)
	print("Player spawned with first-person camera.")

func spawn_crosshair() -> void:
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
	add_child(canvas)
	print("Crosshair spawned.")


func spawn_enemies() -> void:
	var rng = RandomNumberGenerator.new()
	# Terrain half-extents for random placement within bounds
	var half_w: float = (terrain.terrain_width - 1) * terrain.cell_size * 0.5
	var half_d: float = (terrain.terrain_depth - 1) * terrain.cell_size * 0.5

	for i in range(30):
		var enemy = RigidBody3D.new()
		var x = rng.randf_range(-half_w + 5.0, half_w - 5.0)
		var z = rng.randf_range(-half_d + 5.0, half_d - 5.0)
		var y = terrain.get_height_at(x, z) + 2.0  # Spawn above the surface
		enemy.position = Vector3(x, y, z)
		enemy.mass = 1.0
		enemy.name = "Enemy_" + str(i)
		enemy.collision_layer = 2 # Layer 2
		enemy.collision_mask = 1 | 2 | 4 # Ground, Enemies, Player
	
		# Mesh
		var mesh_instance = MeshInstance3D.new()
		var capsule_mesh = CapsuleMesh.new()
		mesh_instance.mesh = capsule_mesh
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
