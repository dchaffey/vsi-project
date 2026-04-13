extends "res://scripts/towers/building.gd"

var range_radius: float = 20.0  # detection radius for enemies
var wind_force: float = 20.0  # impulse magnitude per blast
var wind_direction: Vector3 = Vector3(0, 0, -1)  # static wind direction (forward)
var cylinder_radius: float = 4.0  # radius of the visualization cylinder
var blast_cooldown: float = 6.0  # time between blasts in seconds
var blast_duration: float = 0.3  # how long each blast lasts in seconds
var _time_since_last_blast: float = 0.0  # elapsed time since last wind blast
var _blast_active_time: float = 0.0  # elapsed time during current blast

var _model_visual: Node3D  # animated windmill model
var _cylinder_visual: MeshInstance3D  # semi-transparent cylinder showing wind blast area
var _detection_area: Area3D  # persistent area for enemy detection

const MODEL = preload("res://assets/mühle.glb")

static func get_cost() -> int:
	return 80  # purchase cost

func _ready() -> void:
	_model_visual = MODEL.instantiate()
	add_child(_model_visual)
	var anim_player = _model_visual.find_child("AnimationPlayer", true, false)
	anim_player.play("Plane_001Action")

	# Create the cylinder visualization
	_cylinder_visual = MeshInstance3D.new()
	var cylinder_mesh = CylinderMesh.new()
	cylinder_mesh.top_radius = cylinder_radius
	cylinder_mesh.bottom_radius = cylinder_radius
	cylinder_mesh.height = range_radius
	_cylinder_visual.mesh = cylinder_mesh

	# Rotate the cylinder to point forward along -Z (standard Godot forward)
	_cylinder_visual.rotation.x = deg_to_rad(90)
	_cylinder_visual.position = Vector3(0, 0, -range_radius / 2.0)

	# Material for the cylinder (semi-transparent)
	var mat = StandardMaterial3D.new()
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.5, 0.8, 1.0, 0.3) # Light blue, transparent
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	_cylinder_visual.material_override = mat
	_model_visual.add_child(_cylinder_visual)

	# Collision shape for tower itself
	var collision_shape = CollisionShape3D.new()
	var shape = SphereShape3D.new()
	shape.radius = 1.5
	collision_shape.shape = shape
	collision_shape.position = Vector3(0, 1.5, 0)
	add_child(collision_shape)

	# Persistent detection area — wait 2 frames for physics to initialize
	await get_tree().physics_frame
	await get_tree().physics_frame
	_setup_detection_area()

func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation

func upgrade() -> void:
	# Wind tower upgrade placeholder
	pass

func _setup_detection_area() -> void:
	# Create persistent Area3D for enemy detection (scale 1,1,1 to avoid Jolt Physics issues)
	_detection_area = Area3D.new()
	_detection_area.scale = Vector3.ONE  # Ensure no scaling inheritance
	_detection_area.collision_mask = 2 # Only detect enemies
	var col = CollisionShape3D.new()
	col.scale = Vector3.ONE  # Ensure collision shape has uniform scale
	var sphere = SphereShape3D.new()
	sphere.radius = range_radius
	col.shape = sphere
	_detection_area.add_child(col)
	_detection_area.position = Vector3(0, 1.5, 0)
	add_child(_detection_area)

func _physics_process(delta: float) -> void:
	# Guard: if detection area not yet ready, skip
	if not is_instance_valid(_detection_area):
		return

	_time_since_last_blast += delta
	if _time_since_last_blast >= blast_cooldown:
		_blast_active_time = 0.0
		_time_since_last_blast = 0.0

	if _blast_active_time < blast_duration:
		var enemies = _detection_area.get_overlapping_bodies()
		if not enemies.is_empty():
			_apply_wind_to_enemies(enemies)
		_blast_active_time += delta

func _apply_wind_to_enemies(enemies: Array) -> void:
	# Transform wind direction to world space based on tower's rotation
	var world_wind_direction = global_basis * wind_direction
	# Apply constant wind impulse to all enemies in range
	for enemy in enemies:
		if enemy is RigidBody3D:
			enemy.receive_impact_impulse(world_wind_direction, wind_force)
