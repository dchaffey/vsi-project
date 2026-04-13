extends CharacterBody3D

signal money_changed(new_amount: float)
var money: float = 100.0:
	set(val):
		money = val
		money_changed.emit(money)

var explosion_force: float = 60.0
var explosion_radius: float = 20.0
var tower_path_clearance: float = 2.0  # minimum distance from paths for tower placement

var terrain: StaticBody3D = null
var game_board: Node3D = null  # set by world.gd — used to dismiss building selection ring

var _is_locked: bool = false
var _suck_timer := 0.0
var _active_suck_area: Area3D = null
var _ghost_rotation_step: float = deg_to_rad(45.0)

var _placement_script: String = ""
var _placement_cost: int = 0
var _ghost_tower: Node3D = null
var _ghost_rotation: Vector3 = Vector3.ZERO

# VR Nodes
var camera: XRCamera3D
var right_hand: XRController3D
var left_hand: XRController3D
var laser_pointer: Node3D
var _world_raycast: RayCast3D

var l_id: int = -1
var r_id: int = -1

const EXPLOSION_PREFAB = preload("res://addons/ExplosionExport/Prefab.tscn")

func _ready() -> void:
	var xr_origin = XROrigin3D.new()
	xr_origin.name = "XROrigin3D"
	add_child(xr_origin)

	camera = XRCamera3D.new()
	xr_origin.add_child(camera)

	left_hand = XRController3D.new()
	left_hand.tracker = "left_hand"
	xr_origin.add_child(left_hand)

	right_hand = XRController3D.new()
	right_hand.tracker = "right_hand"
	xr_origin.add_child(right_hand)

	# Instantiate laser pointer for UI interactions
	var pointer_scene = preload("res://addons/godot-xr-tools/functions/function_pointer.tscn")
	assert(pointer_scene)

	laser_pointer = pointer_scene.instantiate()
	assert(laser_pointer.has_method("set_collide_with_areas")
	right_hand.add_child(laser_pointer)
	# Ensure it can hit our 3D interactables
	laser_pointer.set_collide_with_areas(true)

	# Dedicated raycast for world interaction (avoids depending on XR Tools internal UI pointer logic)
	_world_raycast = RayCast3D.new()
	_world_raycast.target_position = Vector3(0, 0, -100) # 100 meters forward
	_world_raycast.collision_mask = 1
	right_hand.add_child(_world_raycast)

	await get_tree().process_frame

func _physics_process(delta: float) -> void:
	if _is_locked:
		return

	# Update Joypad IDs
	l_id = left_hand.get_joy_id()
	r_id = right_hand.get_joy_id()

	if _ghost_tower:
		# --- PLACEMENT MODE ---
		if l_id != -1:
			if Input.is_action_just_pressed("trigger_click", l_id):
				_rotate_ghost_tower()

		if r_id != -1:
			if Input.is_action_just_pressed("trigger_click", r_id):
				_confirm_placement()
			
			if Input.is_action_just_pressed("ax_button", r_id) or Input.is_action_just_pressed("by_button", r_id):
				cancel_placement()

		# Update ghost position
		if is_instance_valid(_world_raycast) and _world_raycast.is_colliding():
			_world_raycast.add_exception_rid(_ghost_tower.get_rid())
		_update_ghost_position()
	
	else:
		# --- MAGIC / SELECTION MODE ---
		if l_id != -1:
			if Input.is_action_just_pressed("ax_button", l_id):
				_explode_at_mouse()
			
			if Input.is_action_just_pressed("by_button", l_id):
				_start_suck()

		if r_id != -1:
			if Input.is_action_just_pressed("trigger_click", r_id):
				if game_board:
					game_board.hide_building_ring()

		# Process active magic (Suck)
		if _suck_timer > 0.0:
			_suck_timer -= delta
			_process_suck()
			if _suck_timer <= 0.0:
				_stop_suck()

func start_placement(script_path: String) -> void:
	cancel_placement()
	_stop_suck() # Ensure magic stops when placing
	_placement_script = script_path
	_ghost_rotation = Vector3.ZERO
	var building_class = load(script_path) as Script
	_placement_cost = building_class.get_cost()

	_ghost_tower = StaticBody3D.new()
	_ghost_tower.collision_layer = 0
	_ghost_tower.collision_mask = 0
	_ghost_tower.set_script(load(script_path))
	get_parent().add_child(_ghost_tower)
	_ghost_tower.set_physics_process(false)
	_ghost_tower.set_process(false)
	_apply_ghost_material(_ghost_tower)
	
	if is_instance_valid(_world_raycast):
		_world_raycast.add_exception_rid(_ghost_tower.get_rid())

func cancel_placement() -> void:
	if _ghost_tower:
		if is_instance_valid(_world_raycast):
			_world_raycast.remove_exception_rid(_ghost_tower.get_rid())
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

	var building_script = load(_placement_script) as Script
	var tower = building_script.new()
	get_parent().add_child(tower)
	tower.place(hit_point, Vector3(0, _ghost_rotation.y, 0))
	if terrain:
		terrain.deflect_obstacle(hit_point.x, hit_point.z, 2.5, 8.0)

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
	_active_suck_area.collision_mask = 2
	var col = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = explosion_radius
	col.shape = sphere
	_active_suck_area.add_child(col)
	get_parent().add_child(_active_suck_area)

func _stop_suck() -> void:
	if _active_suck_area:
		_active_suck_area.queue_free()
		_active_suck_area = null
	_suck_timer = 0.0

var _suck_log_cooldown := 0.0

func _process_suck() -> void:
	if not _active_suck_area:
		return

	var hit_point = _get_raycast_hit_point()
	if hit_point != Vector3.INF:
		_active_suck_area.global_position = hit_point

	var bodies = _active_suck_area.get_overlapping_bodies()
	var suck_point = _active_suck_area.global_position

	_suck_log_cooldown -= get_physics_process_delta_time()
	if _suck_log_cooldown <= 0.0:
		_suck_log_cooldown = 0.5

	for body in bodies:
		if not body is RigidBody3D:
			continue
		var diff = body.global_position - suck_point
		var dist = diff.length()
		var falloff = 1.0 - clamp(dist / explosion_radius, 0.0, 1.0)
		var dir = -diff.normalized()
		if dir.is_zero_approx():
			dir = Vector3.UP
		body.linear_velocity += dir * explosion_force * falloff * 0.2

func _get_raycast_hit_point() -> Vector3:
	if is_instance_valid(_world_raycast) and _world_raycast.is_colliding():
		return _world_raycast.get_collision_point()
	return Vector3.INF

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
