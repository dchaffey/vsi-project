extends Area3D

## Player-fired mage projectile.
## Travels along a bezier curve from the controller to a fixed endpoint (no homing).
## On enemy contact: applies a small impulse to that single body, then despawns. No AoE.

var start_pos: Vector3
var end_pos: Vector3
var control1: Vector3
var control2: Vector3
var duration: float = 0.9
var elapsed_time: float = 0.0
## Impulse magnitude applied to the hit body. Tuned low — single-target nudge, not a blast.
var impact_force: float = 8.0

var _consumed := false  # true once we've hit something — prevents double-impulse before queue_free

func setup(p_start: Vector3, p_end: Vector3) -> void:
	start_pos = p_start
	end_pos = p_end
	global_position = start_pos

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	# Lofted arc — first control point lifts off the controller, second hovers above the endpoint.
	var out_dir := Vector3(
		rng.randf_range(-0.4, 0.4),
		rng.randf_range(0.4, 1.2),
		rng.randf_range(-0.4, 0.4)
	).normalized()
	control1 = start_pos + out_dir * rng.randf_range(5.0, 12.0)
	control2 = end_pos + Vector3(
		rng.randf_range(-6.0, 6.0),
		rng.randf_range(2.0, 6.0),
		rng.randf_range(-6.0, 6.0)
	)

	var mesh_instance := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.4
	mesh_instance.mesh = sphere_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.5, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.1, 0.3, 1.0)
	mat.emission_energy_multiplier = 8.0
	mesh_instance.material_override = mat
	add_child(mesh_instance)

	var collision_shape := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
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
	if _consumed:
		return

	elapsed_time += delta
	var t := clampf(elapsed_time / duration, 0.0, 1.0)

	var final_pos := _calculate_bezier(t, start_pos, control1, control2, end_pos)

	if not final_pos.is_equal_approx(global_position):
		look_at(final_pos)
		rotate_object_local(Vector3.RIGHT, PI / 2)

	global_position = final_pos

	if t >= 1.0:
		queue_free()

func _calculate_bezier(t_val: float, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> Vector3:
	return (1.0 - t_val)**3 * p0 + 3.0 * (1.0 - t_val)**2 * t_val * p1 + 3.0 * (1.0 - t_val) * t_val**2 * p2 + t_val**3 * p3

func _on_body_entered(body: Node3D) -> void:
	if _consumed:
		return
	if not body.has_method("apply_impulse"):
		return
	_consumed = true
	var dir := (body.global_position - global_position).normalized()
	if dir.is_zero_approx():
		dir = Vector3.UP
	body.apply_impulse(dir, impact_force, true)
	queue_free()
