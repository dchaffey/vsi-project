extends CharacterBody3D

var speed: float = 8.0
var mouse_sensitivity: float = 0.002
var jump_velocity: float = 6.0

var explosion_force: float = 60.0
var explosion_radius: float = 20.0

const GRAVITY = 19.6

var camera: Camera3D
var _pending_explosion := false
var _suck_timer := 0.0
var _active_suck_area: Area3D = null

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().process_frame
	camera = get_node_or_null("Camera3D")

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		rotate_y(-event.relative.x * mouse_sensitivity)
		if camera:
			camera.rotate_x(-event.relative.y * mouse_sensitivity)
			camera.rotation.x = clamp(camera.rotation.x, -deg_to_rad(80), deg_to_rad(80))

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_SPACE:
		if is_on_floor():
			velocity.y = jump_velocity

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_Q:
		_pending_explosion = true

	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_E:
		_start_suck()

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	var input_dir = Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W): input_dir.y -= 1
	if Input.is_physical_key_pressed(KEY_S): input_dir.y += 1
	if Input.is_physical_key_pressed(KEY_A): input_dir.x -= 1
	if Input.is_physical_key_pressed(KEY_D): input_dir.x += 1

	input_dir = input_dir.normalized()

	if input_dir != Vector2.ZERO:
		var move_dir = (global_transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
		velocity.x = move_dir.x * speed
		velocity.z = move_dir.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()

	if _pending_explosion:
		_pending_explosion = false
		_explode_at_crosshair()

	if _suck_timer > 0.0:
		_suck_timer -= delta
		_process_suck()
		if _suck_timer <= 0.0:
			_stop_suck()

func _explode_at_crosshair() -> void:
	var hit_point = _get_raycast_hit_point()
	if hit_point == Vector3.INF:
		return

	var bodies = await _get_bodies_in_sphere(hit_point, explosion_radius)
	for body in bodies:
		if not body is RigidBody3D:
			continue
		var diff = body.global_position - hit_point
		var dist = diff.length()
		var falloff = 1.0 - clamp(dist / explosion_radius, 0.0, 1.0)
		var dir = diff.normalized()
		if dir.is_zero_approx():
			dir = Vector3.UP
		body.apply_central_impulse(dir * explosion_force * falloff)

func _start_suck() -> void:
	_stop_suck() # Clear any existing suck
	_suck_timer = 3.0
	
	_active_suck_area = Area3D.new()
	_active_suck_area.collision_mask = 2 # Only detect enemies
	var col = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = explosion_radius
	col.shape = sphere
	_active_suck_area.add_child(col)
	get_parent().add_child(_active_suck_area)
	
	print("[DEBUG] Started 3s suck effect.")

func _stop_suck() -> void:
	if _active_suck_area:
		_active_suck_area.queue_free()
		_active_suck_area = null
	_suck_timer = 0.0

func _process_suck() -> void:
	if not _active_suck_area:
		return
		
	var hit_point = _get_raycast_hit_point()
	if hit_point == Vector3.INF:
		# If raycast fails, keep area at last position or move far away?
		# Let's keep it at the last valid position to be less jarring.
		pass
	else:
		_active_suck_area.global_position = hit_point

	# In continuous mode, we just query overlapping bodies.
	# We don't need to await here because the area is persistent.
	var bodies = _active_suck_area.get_overlapping_bodies()
	var suck_point = _active_suck_area.global_position
	
	for body in bodies:
		if not body is RigidBody3D:
			continue
		var diff = body.global_position - suck_point
		var dist = diff.length()
		var falloff = 1.0 - clamp(dist / explosion_radius, 0.0, 1.0)
		var dir = -diff.normalized() # Pull towards
		
		if dir.is_zero_approx():
			dir = Vector3.UP
		
		# Since this runs every frame, we use a smaller force (divided by 60 approx)
		# or just use a dedicated suck force variable.
		# Let's scale by delta for consistent behavior.
		body.apply_central_impulse(dir * explosion_force * falloff * 0.1)

func _get_raycast_hit_point() -> Vector3:
	if not camera:
		return Vector3.INF
	var space_state = get_world_3d().direct_space_state
	var from = camera.global_position
	var to = from + (-camera.global_transform.basis.z) * 200.0
	var ray_query = PhysicsRayQueryParameters3D.create(from, to)
	ray_query.collision_mask = 1 # Only hit the ground
	ray_query.exclude = [get_rid()]
	var ray_result = space_state.intersect_ray(ray_query)
	if not ray_result:
		return Vector3.INF
	return ray_result.position

func _get_bodies_in_sphere(center: Vector3, radius: float) -> Array[Node3D]:
	var area = Area3D.new()
	area.collision_mask = 2 # Only detect enemies
	var col = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = radius
	col.shape = sphere
	area.add_child(col)
	
	get_parent().add_child(area)
	area.global_position = center
	
	await get_tree().physics_frame
	await get_tree().physics_frame
	
	var bodies = area.get_overlapping_bodies()
	area.queue_free()
	return bodies
