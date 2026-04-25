extends "res://scripts/towers/building.gd"

## Catapult tower — launches a heavy boulder in a fixed forward direction every 3 seconds.
## Direction is set at placement time by rotating the ghost (R key). Indicated by a yellow arrow.

const BOULDER_SCRIPT = preload("res://scripts/projectiles/boulder.gd")  # spawned on each fire

var shoot_interval: float = 3.0  # seconds between launches
var shoot_timer: float = 0.0     # accumulator for shoot_interval
var ball_mass: float = 80.0      # RigidBody3D mass — scales enemy knockback on contact
var _launch_speed: float = 30.0  # forward speed of the boulder in m/s
var _launch_upward: float = 8.0  # upward component added at launch so the boulder arcs slightly

var _tower_model: MeshInstance3D  # main brown box body
var _launch_marker: Node3D        # sits at the front face of the nozzle box — boulder spawns here


static func get_cost() -> int:
	return 50  # purchase cost in currency units


func get_max_upgrades() -> int:
	return 0  # no upgrade tiers


func _get_collision_box_size() -> Vector3:
	return Vector3(4.0, 8.0, 4.0)  # matches _build_tower_mesh box for physics and mouse picking


func _ready() -> void:
	initialize_level()


func _apply_level(level: int) -> void:
	assert(level == 0, "Catapult tower has no upgrades")
	_build_tower_mesh()


func _build_tower_mesh() -> void:
	if is_instance_valid(_tower_model):
		_tower_model.queue_free()
	_tower_model = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4.0, 8.0, 4.0)
	_tower_model.mesh = box
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.32, 0.18)  # earthy brown
	_tower_model.material_override = mat
	_tower_model.position = Vector3(0.0, 4.0, 0.0)  # sit base at y=0
	add_child(_tower_model)

	# Small nozzle box protruding from the front face (-Z) at mid-height.
	# Front face of main box is at z=-2; nozzle (size 1.5) center sits at z=-2.75.
	var nozzle := MeshInstance3D.new()
	var nozzle_box := BoxMesh.new()
	nozzle_box.size = Vector3(1.5, 1.5, 1.5)
	nozzle.mesh = nozzle_box
	nozzle.material_override = mat
	nozzle.position = Vector3(0.0, 6.0, -2.75)
	add_child(nozzle)

	# Marker at the front tip of the nozzle — z = -2.75 - 0.75 = -3.5.
	_launch_marker = Node3D.new()
	_launch_marker.position = Vector3(0.0, 6.0, -3.5)
	add_child(_launch_marker)


func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation


func _physics_process(delta: float) -> void:
	shoot_timer += delta
	if shoot_timer >= shoot_interval:
		shoot_timer = 0.0
		_launch_boulder()


## Spawn a boulder from the nozzle marker and fire it in the tower's forward direction.
func _launch_boulder() -> void:
	assert(_launch_marker != null, "Catapult launch marker must exist before firing")
	var ball: RigidBody3D = BOULDER_SCRIPT.new()
	ball.mass = ball_mass
	get_parent().add_child(ball)
	ball.global_position = _launch_marker.global_position
	var forward := -global_transform.basis.z
	ball.linear_velocity = forward * _launch_speed + Vector3.UP * _launch_upward
