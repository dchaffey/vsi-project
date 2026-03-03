extends Node3D

func _ready() -> void:
	# Boost global gravity programmatically (optional but effective)
	ProjectSettings.set_setting("physics/3d/default_gravity", 19.6)
	
	spawn_environment()
	spawn_sunlight()
	spawn_platform()
	spawn_walls()
	spawn_enemies()
	spawn_player()
	spawn_crosshair()


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

func spawn_platform() -> void:
	var platform_size = Vector3(100, 1, 100)
	var static_body = StaticBody3D.new()
	static_body.position = Vector3(0, -0.5, 0)
	static_body.collision_layer = 1 # Layer 1: Ground
	
	# Mesh
	var mesh_instance = MeshInstance3D.new()
	var box_mesh = BoxMesh.new()
	box_mesh.size = platform_size
	mesh_instance.mesh = box_mesh
	var platform_material = StandardMaterial3D.new()
	platform_material.albedo_color = Color(0.5, 0.3, 1.0)
	mesh_instance.material_override = platform_material
	static_body.add_child(mesh_instance)
	
	# Collision
	var collision_shape = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = platform_size
	collision_shape.shape = shape
	static_body.add_child(collision_shape)
	
	add_child(static_body)
	print("Platform spawned.")

func spawn_player() -> void:
	var player = CharacterBody3D.new()
	player.position = Vector3(0, 5, 0)
	player.name = "Player"
	player.collision_layer = 4 # Layer 3 (bit 2^2=4)
	player.collision_mask = 1 | 2 # Detect Ground and Enemies
	
	# Mesh
	var mesh_instance = MeshInstance3D.new()
	var capsule_mesh = CapsuleMesh.new()
	mesh_instance.mesh = capsule_mesh
	player.add_child(mesh_instance)
	
	# Collision
	var collision_shape = CollisionShape3D.new()
	var shape = CapsuleShape3D.new()
	collision_shape.shape = shape
	player.add_child(collision_shape)
	
	# Script
	player.set_script(load("res://scripts/player_controller.gd"))
	
	add_child(player)
	
	# Camera (First-person perspective for the crosshair)
	var camera = Camera3D.new()
	camera.name = "Camera3D"
	camera.position = Vector3(0, 0.5, 0) # Near eye level
	player.add_child(camera)
	camera.make_current()
	
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
	for i in range(30):
		var enemy = RigidBody3D.new()
		var x = rng.randi_range(-20, 20)
		var y = rng.randi_range(-20, 20)
		enemy.position = Vector3(x, 2, y)
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
	var platform_size = 50.0
	var wall_height = 20.0
	var wall_thickness = 1.0
	var half_size = platform_size / 2.0
	
	var wall_material = StandardMaterial3D.new()
	wall_material.albedo_color = Color(0.3, 0.3, 0.3) # Dark grey
	wall_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wall_material.albedo_color.a = 0.5 # Semi-transparent
	
	# Wall data: [position, size]
	var walls = [
		[Vector3(0, wall_height/2, -half_size), Vector3(platform_size, wall_height, wall_thickness)], # North
		[Vector3(0, wall_height/2, half_size), Vector3(platform_size, wall_height, wall_thickness)], # South
		[Vector3(-half_size, wall_height/2, 0), Vector3(wall_thickness, wall_height, platform_size)], # West
		[Vector3(half_size, wall_height/2, 0), Vector3(wall_thickness, wall_height, platform_size)]  # East
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
	
	print("Walls spawned around the platform.")
