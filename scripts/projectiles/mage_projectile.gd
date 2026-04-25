extends Area3D

const EnemyQuery = preload("res://scripts/utils/enemy_query.gd")  # shared enemy query helper for explosion target collection

var start_pos: Vector3
var target_node: Node3D
var control1: Vector3
var control2_offset: Vector3
var duration: float = 1.2
var elapsed_time: float = 0.0
var impact_force: float = 5.0  # magnitude of impulse applied in explosion
var explosion_radius: float = 30.0  # radius for knocking back multiple enemies
var explosion_force: float = 25.0  # force applied per unit falloff in explosion
var explosion_damage: float = 30.0  # HP removed at direct hit, scaled by distance falloff
var _query_shape := SphereShape3D.new()  # reused sphere for physics queries

var _pending_explosion := false  # deferred explosion to _physics_process for proper space_state access
var _explosion_pos := Vector3.ZERO  # position to detonate at

func setup(p_start: Vector3, p_target: Node3D) -> void:
	start_pos = p_start
	target_node = p_target
	
	# Randomize flight path characteristics
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	
	# Control 1: Pushes the missile OUT/UP from the tower in a random arc
	var out_dir = (Vector3(rng.randf_range(-1, 1), rng.randf_range(0.5, 2.0), rng.randf_range(-1, 1))).normalized()
	control1 = start_pos + out_dir * rng.randf_range(10.0, 20.0)
	
	# Control 2 Offset: Relative to the target, makes it "dive" in from a side
	control2_offset = Vector3(rng.randf_range(-15, 15), rng.randf_range(5, 15), rng.randf_range(-15, 15))
	
	# Mesh
	var mesh_instance = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 0.3
	mesh_instance.mesh = sphere_mesh
	
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.3, 1.0) # Glowing Blue
	mat.emission_enabled = true
	mat.emission = Color(0.0, 0.2, 1.0)
	mat.emission_energy_multiplier = 4.0
	mesh_instance.material_override = mat
	add_child(mesh_instance)

	# Collision
	var collision_shape = CollisionShape3D.new()
	var shape = CapsuleShape3D.new()
	shape.radius = 0.2
	shape.height = 0.7
	collision_shape.shape = shape
	collision_shape.rotation_degrees.x = 90
	add_child(collision_shape)

	body_entered.connect(_on_body_entered)
	collision_mask = 2
	collision_layer = 0
	input_ray_pickable = false

func _physics_process(delta: float) -> void:
	if _pending_explosion:
		_pending_explosion = false
		_explode(_explosion_pos)
		queue_free()
		return

	if not is_instance_valid(target_node):
		queue_free()
		return

	elapsed_time += delta
	var t = clamp(elapsed_time / duration, 0.0, 1.0)

	# Cubic Bezier
	var p0 = start_pos
	var p1 = control1
	var p3 = target_node.global_position
	var p2 = p3 + control2_offset

	var final_pos = _calculate_bezier(t, p0, p1, p2, p3)

	if not final_pos.is_equal_approx(global_position):
		look_at(final_pos)
		rotate_object_local(Vector3.RIGHT, PI/2)

	global_position = final_pos

	if t >= 1.0:
		queue_free()

func _calculate_bezier(t_val: float, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> Vector3:
	return (1.0 - t_val)**3 * p0 + 3.0 * (1.0 - t_val)**2 * t_val * p1 + 3.0 * (1.0 - t_val) * t_val**2 * p2 + t_val**3 * p3

func _explode(impact_pos: Vector3) -> void:
	# deferred to _physics_process — direct_space_state inaccessible in signal callbacks
	var bodies = _get_bodies_in_sphere(impact_pos, explosion_radius)
	for body in bodies:
		if not body.has_method("apply_impulse"):
			continue
		var diff = body.global_position - impact_pos
		var dist = diff.length()
		var falloff = 1.0 - clamp(dist / explosion_radius, 0.0, 1.0)
		var dir = diff.normalized()
		if dir.is_zero_approx():
			dir = Vector3.UP
		body.apply_impulse(dir, explosion_force * falloff)
		body.apply_dmg(explosion_damage * falloff)

func _on_body_entered(body: Node3D) -> void:
	if body == target_node:
		_explosion_pos = body.global_position
		_pending_explosion = true

func _get_bodies_in_sphere(center: Vector3, radius: float) -> Array[Node3D]:
	return EnemyQuery.get_enemies_in_sphere(self, _query_shape, center, radius, [get_rid()])
