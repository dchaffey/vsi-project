extends CharacterBody3D

var mouse_sensitivity: float = 0.002
var zoom_speed: float = 1.1 # Multiplier
var rotation_sensitivity: float = 0.005

signal money_changed(new_amount: float)
var money: float = 100.0:
	set(val):
		money = val
		money_changed.emit(money)

var explosion_force: float = 60.0
var explosion_radius: float = 20.0
var tower_path_clearance: float = 2.0  # minimum distance from paths for tower placement

var terrain: StaticBody3D = null
var camera: Camera3D
var game_board: Node3D = null  # set by world.gd — used to dismiss building selection ring

var _zoom_level: float = 80.0
var _min_zoom: float = 10.0
var _max_zoom: float = 300.0
var _is_locked: bool = false  # locks input when game over

var _suck_timer := 0.0
var _active_suck_area: Area3D = null  ## persistent sphere for suck detection
var _pending_explosion := false
var _pending_confirm_placement := false  # deferred to _physics_process to access space state
var _pending_rotate_ghost := false  # deferred rotation of ghost tower during placement
var _ghost_rotation_step: float = deg_to_rad(45.0)  # snap rotation increment

var _placement_script: String = ""
var _placement_cost: int = 0  # cost of tower being placed
var _ghost_tower: Node3D = null
var _ghost_rotation: Vector3 = Vector3.ZERO  # preserve ghost rotation for placement

const EXPLOSION_PREFAB = preload("res://addons/ExplosionExport/Prefab.tscn")

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	
	# Camera setup
	camera = Camera3D.new()
	camera.name = "Camera3D"
	add_child(camera)
	camera.make_current()
	
	# Initial position/rotation (Bird's eye)
	# Set a slight angle so it's not looking perfectly straight down (more RTS feel)
	camera.rotation.x = -PI / 2.5
	_update_camera_position()

	await get_tree().process_frame

func _unhandled_input(event: InputEvent) -> void:
	if _is_locked:
		return
	if _ghost_tower and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			# defer to _physics_process — direct_space_state inaccessible outside physics
			_pending_confirm_placement = true
			get_viewport().set_input_as_handled()
			return
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			cancel_placement()
			get_viewport().set_input_as_handled()
			return

	# Left-click on empty space — dismiss any open building ring
	if not _ghost_tower and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if game_board:
			game_board.hide_building_ring()

func _input(event: InputEvent) -> void:
	if _is_locked:
		return
	# Zoom
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_level = clamp(_zoom_level / zoom_speed, _min_zoom, _max_zoom)
			_update_camera_position()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_level = clamp(_zoom_level * zoom_speed, _min_zoom, _max_zoom)
			_update_camera_position()

	# Pan & Rotate
	if event is InputEventMouseMotion:
		if event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			# Pan the world (move camera opposite to mouse motion)
			var forward = -global_transform.basis.z
			var right = global_transform.basis.x
			var move_amount = (right * -event.relative.x + forward * event.relative.y) * mouse_sensitivity * (_zoom_level * 0.5)
			global_translate(move_amount)
			
		elif event.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			# Rotate camera
			rotate_y(-event.relative.x * rotation_sensitivity)
			camera.rotate_x(-event.relative.y * rotation_sensitivity)
			camera.rotation.x = clamp(camera.rotation.x, -deg_to_rad(85), -deg_to_rad(5))
			_update_camera_position()

	# Actions (set flags for _physics_process)
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Q:
			_pending_explosion = true
		elif event.keycode == KEY_E:
			_start_suck() # This just sets timer, safe to call here
		elif event.keycode == KEY_R and _ghost_tower:
			_pending_rotate_ghost = true
		elif event.keycode == KEY_ESCAPE:
			cancel_placement()

	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _update_camera_position() -> void:
	camera.position = Vector3.ZERO + (camera.transform.basis.z * _zoom_level)

func _physics_process(delta: float) -> void:
	if _is_locked:
		return
	if _pending_explosion:
		_pending_explosion = false
		_explode_at_mouse()
		

	if _pending_confirm_placement:
		_pending_confirm_placement = false
		_confirm_placement()

	if _pending_rotate_ghost:
		_pending_rotate_ghost = false
		_rotate_ghost_tower()

	if _ghost_tower:
		_update_ghost_position()

	if _suck_timer > 0.0:
		_suck_timer -= delta
		_process_suck()
		if _suck_timer <= 0.0:
			_stop_suck()

func start_placement(script_path: String) -> void:
	cancel_placement()
	_placement_script = script_path
	_ghost_rotation = Vector3.ZERO

	# Get cost from building class (static method)
	var building_class = load(script_path) as Script
	_placement_cost = building_class.get_cost()

	_ghost_tower = StaticBody3D.new()
	_ghost_tower.collision_layer = 0
	_ghost_tower.collision_mask = 0

	_ghost_tower.set_script(load(script_path))
	get_parent().add_child(_ghost_tower)
	_ghost_tower.set_physics_process(false)  # prevent ghost from shooting
	_ghost_tower.set_process(false)
	_apply_ghost_material(_ghost_tower)

func cancel_placement() -> void:
	if _ghost_tower:
		_ghost_tower.queue_free()
		_ghost_tower = null
	_placement_script = ""
	_placement_cost = 0

func _rotate_ghost_tower() -> void:
	if _ghost_tower:
		_ghost_tower.rotation.y += _ghost_rotation_step
		_ghost_rotation.y = _ghost_tower.rotation.y

func _update_ghost_position() -> void:
	var hit_point = _get_raycast_hit_point()
	if hit_point != Vector3.INF:
		_ghost_tower.global_position = hit_point
		var valid = true
		if terrain and terrain.get_path_distance(hit_point.x, hit_point.z) < tower_path_clearance:
			valid = false
		_update_ghost_color(valid)

func _update_ghost_color(valid: bool) -> void:
	var color = Color(0, 1, 0, 0.4) if valid else Color(1, 0, 0, 0.4)
	_apply_custom_color(_ghost_tower, color)

func _apply_ghost_material(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mat = StandardMaterial3D.new()
			mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(1, 1, 1, 0.4)
			child.material_override = mat
		_apply_ghost_material(child)

func _apply_custom_color(node: Node, color: Color) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			if child.material_override is StandardMaterial3D:
				child.material_override.albedo_color = color
		_apply_custom_color(child, color)

func _confirm_placement() -> void:
	var hit_point = _get_raycast_hit_point()
	if hit_point == Vector3.INF:
		return
	if terrain and terrain.get_path_distance(hit_point.x, hit_point.z) < tower_path_clearance:
		return

	# Create building instance, add to scene tree first, then call place()
	var building_script = load(_placement_script) as Script
	var tower = building_script.new()
	get_parent().add_child(tower)
	tower.place(hit_point, Vector3(0, _ghost_rotation.y, 0))
	if terrain:
		terrain.deflect_obstacle(hit_point.x, hit_point.z, 2.5, 8.0)

	# Subtract cost from money
	money -= _placement_cost

	cancel_placement()

func _explode_at_mouse() -> void:
	var hit_point = _get_raycast_hit_point()
	if hit_point == Vector3.INF:
		return

	_spawn_explosion(hit_point)

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

func _spawn_explosion(_pos: Vector3) -> void:
	var explosion = EXPLOSION_PREFAB.instantiate()
	get_parent().add_child(explosion)
	explosion.global_position = _pos
	get_tree().create_timer(10.0).timeout.connect(explosion.queue_free)

func _start_suck() -> void:
	_stop_suck()
	_suck_timer = 3.0
	_active_suck_area = Area3D.new()
	_active_suck_area.collision_mask = 2  # only detect enemies
	var col = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = explosion_radius
	col.shape = sphere
	_active_suck_area.add_child(col)
	get_parent().add_child(_active_suck_area)
	print("[SUCK] started, area added to scene, radius=", explosion_radius)

func _stop_suck() -> void:
	if _active_suck_area:
		_active_suck_area.queue_free()
		_active_suck_area = null
	_suck_timer = 0.0

var _suck_log_cooldown := 0.0  ## throttle debug prints to once per 0.5s

func _process_suck() -> void:
	if not _active_suck_area:
		print("[SUCK] ERROR: _active_suck_area is null during suck")
		return

	var hit_point = _get_raycast_hit_point()
	if hit_point != Vector3.INF:
		_active_suck_area.global_position = hit_point

	var bodies = _active_suck_area.get_overlapping_bodies()
	var suck_point = _active_suck_area.global_position

	_suck_log_cooldown -= get_physics_process_delta_time()
	if _suck_log_cooldown <= 0.0:
		_suck_log_cooldown = 0.5
		print("[SUCK] pos=", suck_point, " raycast_ok=", hit_point != Vector3.INF, " bodies=", bodies.size())
		if bodies.size() > 0:
			for b in bodies:
				print("  -> ", b.name, " layer=", b.collision_layer, " is_rigid=", b is RigidBody3D)

	for body in bodies:
		if not body is RigidBody3D:
			continue
		var diff = body.global_position - suck_point
		var dist = diff.length()
		var falloff = 1.0 - clamp(dist / explosion_radius, 0.0, 1.0)
		var dir = -diff.normalized()  # pull toward suck point
		if dir.is_zero_approx():
			dir = Vector3.UP
		# Directly modify velocity instead of apply_central_impulse — the deferred impulse
		# gets overwritten when the enemy sets linear_velocity = corrected in its pathing.
		body.linear_velocity += dir * explosion_force * falloff * 0.2

func _get_raycast_hit_point() -> Vector3:
	if not camera:
		return Vector3.INF
	
	var mouse_pos = get_viewport().get_mouse_position()
	var ray_length = 1000.0
	var from = camera.project_ray_origin(mouse_pos)
	var to = from + camera.project_ray_normal(mouse_pos) * ray_length
	
	var space_state = get_world_3d().direct_space_state
	if not space_state:
		return Vector3.INF
		
	var ray_query = PhysicsRayQueryParameters3D.create(from, to)
	ray_query.collision_mask = 1
	if _ghost_tower:
		ray_query.exclude = [_ghost_tower.get_rid()]
		
	var ray_result = space_state.intersect_ray(ray_query)
	
	if not ray_result:
		return Vector3.INF
	return ray_result.position

func _get_bodies_in_sphere(center: Vector3, radius: float) -> Array[Node3D]:
	var area = Area3D.new()
	area.collision_mask = 2
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
