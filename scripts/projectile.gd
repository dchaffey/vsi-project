extends Area3D

var start_pos: Vector3
var target_node: Node3D
var control1: Vector3
var control2_offset: Vector3
var duration: float = 1.2
var elapsed_time: float = 0.0
var impact_force: float = 50.0

# Path visualization
var path_visualizer: MeshInstance3D
var path_material: StandardMaterial3D

func setup(p_start: Vector3, p_target: Node3D, _p_height: float) -> void:
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
	mat.albedo_color = Color(1.0, 0.3, 0.1) # Glowing Orange/Red
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.2, 0.0)
	mat.emission_energy_multiplier = 4.0
	mesh_instance.material_override = mat
	add_child(mesh_instance)
	
	# Path Visualizer Setup
	path_visualizer = MeshInstance3D.new()
	path_visualizer.mesh = ImmediateMesh.new()
	path_material = StandardMaterial3D.new()
	path_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	path_material.albedo_color = Color(1.0, 0.5, 0.0, 0.25) # Transparent Orange
	path_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	path_visualizer.material_override = path_material
	get_parent().add_child.call_deferred(path_visualizer)
	
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

func _exit_tree() -> void:
	if is_instance_valid(path_visualizer):
		path_visualizer.queue_free()

func _physics_process(delta: float) -> void:
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
	_draw_path(t, p0, p1, p2, p3)
	
	if t >= 1.0:
		queue_free()

func _calculate_bezier(t_val: float, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> Vector3:
	return (1.0 - t_val)**3 * p0 + 3.0 * (1.0 - t_val)**2 * t_val * p1 + 3.0 * (1.0 - t_val) * t_val**2 * p2 + t_val**3 * p3

func _draw_path(current_t: float, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	if not is_instance_valid(path_visualizer): return
	
	var im: ImmediateMesh = path_visualizer.mesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	
	var steps = 15
	for i in range(steps + 1):
		var t_step = lerp(current_t, 1.0, float(i) / steps)
		var point = _calculate_bezier(t_step, p0, p1, p2, p3)
		im.surface_add_vertex(point)
	im.surface_end()

func _on_body_entered(body: Node3D) -> void:
	if body == target_node:
		if body is RigidBody3D:
			var impact_dir = (body.global_position - global_position).normalized()
			if impact_dir.is_zero_approx(): impact_dir = Vector3.UP
			body.apply_central_impulse((impact_dir + Vector3.UP * 0.4).normalized() * impact_force)
		queue_free()
