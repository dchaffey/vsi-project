extends StaticBody3D

var range_radius: float = 20.0
var wind_force: float = 150.0
var cone_angle: float = 45.0 # Total angle in degrees
var rotation_speed: float = 5.0

var _cone_visual: MeshInstance3D
var _ball_visual: MeshInstance3D

func _ready() -> void:
	# Create the ball (tower body)
	_ball_visual = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 1.5
	sphere_mesh.height = 3.0
	_ball_visual.mesh = sphere_mesh
	_ball_visual.position = Vector3(0, 1.5, 0)
	add_child(_ball_visual)
	
	# Create the cone visualization
	_cone_visual = MeshInstance3D.new()
	var cone_mesh = CylinderMesh.new()
	cone_mesh.top_radius = 0.0 # Make it a cone
	cone_mesh.bottom_radius = range_radius * tan(deg_to_rad(cone_angle / 2.0))
	cone_mesh.height = range_radius
	_cone_visual.mesh = cone_mesh
	
	# Rotate the cone to point forward along -Z (standard Godot forward)
	# CylinderMesh is vertical by default (Y axis), so we rotate it
	_cone_visual.rotation.x = deg_to_rad(-90)
	_cone_visual.position = Vector3(0, 0, -range_radius / 2.0) # Relative to ball center
	
	# Material for the cone (semi-transparent)
	var mat = StandardMaterial3D.new()
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.5, 0.8, 1.0, 0.3) # Light blue, transparent
	mat.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	_cone_visual.material_override = mat
	_ball_visual.add_child(_cone_visual)

	# Collision
	var collision_shape = CollisionShape3D.new()
	var shape = SphereShape3D.new()
	shape.radius = 1.5
	collision_shape.shape = shape
	collision_shape.position = Vector3(0, 1.5, 0)
	add_child(collision_shape)

func _physics_process(delta: float) -> void:
	var enemies = _get_enemies_in_range()
	
	if not enemies.is_empty():
		# Aim at the first enemy (simplification)
		var target_enemy = enemies[0]
		var target_pos = target_enemy.global_position
		target_pos.y = global_position.y + 1.5 # Aim at the same height
		
		var look_transform = global_transform.looking_at(target_pos, Vector3.UP)
		global_transform = global_transform.interpolate_with(look_transform, rotation_speed * delta)
		
		_apply_wind_to_enemies(enemies)

func _get_enemies_in_range() -> Array:
	var space_state = get_world_3d().direct_space_state
	var query = PhysicsShapeQueryParameters3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = range_radius
	query.shape = sphere
	
	# Position the sphere query at the tower's center (1.5 units up)
	var query_transform = Transform3D.IDENTITY
	query_transform.origin = global_position + Vector3(0, 1.5, 0)
	query.transform = query_transform
	query.collision_mask = 2 # Enemies
	
	var results = space_state.intersect_shape(query)
	var enemies = []
	for res in results:
		if is_instance_valid(res.collider):
			enemies.append(res.collider)
	return enemies

func _apply_wind_to_enemies(enemies: Array) -> void:
	var forward = -global_transform.basis.z.normalized()
	var tower_pos = global_position + Vector3(0, 1.5, 0)
	
	for enemy in enemies:
		if not enemy is RigidBody3D:
			continue
			
		var to_enemy = (enemy.global_position - tower_pos).normalized()
		var angle = rad_to_deg(acos(forward.dot(to_enemy)))
		
		if angle <= cone_angle / 2.0:
			# Enemy is within the cone
			var force = forward * wind_force
			enemy.apply_central_force(force)
