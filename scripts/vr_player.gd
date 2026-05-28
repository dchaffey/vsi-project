extends CharacterBody3D

const PLAYER_MAGE_PROJECTILE_PATH := "res://scripts/projectiles/player_mage_projectile.gd"

## Tabletop-VR scale: 1m of physical motion = WORLD_SCALE meters of game motion. Tweak to taste.
const WORLD_SCALE := 60.0
## Target world yaw applied by _recenter_player(); 0 rad = facing -Z (north, toward terrain center from south edge).
const RECENTER_YAW := 0.0

signal money_changed(new_amount: float)
var money: float = 100.0:
	set(val):
		money = val
		money_changed.emit(money)

var tower_path_clearance: float = 2.0  # minimum distance from paths for tower placement
## Fallback projectile endpoint distance when the controller ray doesn't hit anything.
var fire_max_distance: float = 100.0
## Horizontal spread radius (meters) randomly applied to the projectile endpoint.
var fire_endpoint_spread: float = 3.0

var terrain: StaticBody3D = null
var game_board: Node3D = null  # set by world.gd — used to dismiss building selection ring
var world_content_root: Node3D = null

var _is_locked: bool = false
var _ghost_rotation_step: float = deg_to_rad(45.0)

var _placement_script: String = ""
var _placement_cost: int = 0
var _ghost_tower: Node3D = null
var _ghost_rotation: Vector3 = Vector3.ZERO
var _placement_source_position: Vector3 = Vector3.INF  # shelf preview world position used for spawn animation
var _ignore_next_placement_confirm := false  # block instant placement after selecting from shelf

# VR Nodes
var xr_origin: XROrigin3D  # root of XR-tracked space; world_scale on this node controls tabletop scaling
var camera: XRCamera3D
var right_hand: XRController3D
var left_hand: XRController3D
var laser_pointer: Node3D
var _world_raycast: RayCast3D
var _rng := RandomNumberGenerator.new()
var _placement_zone_indicators: Array = []


func _ready() -> void:
	_rng.randomize()
	xr_origin = XROrigin3D.new()
	xr_origin.name = "XROrigin3D"
	# Apply tabletop scale: 1m physical headset motion = WORLD_SCALE m game motion.
	# Built-in OpenXR scaling — leaves world geometry, physics, and collision shapes untouched.
	xr_origin.world_scale = WORLD_SCALE
	add_child(xr_origin)

	camera = XRCamera3D.new()
	xr_origin.add_child(camera)

	left_hand = XRController3D.new()
	left_hand.tracker = "left_hand"
	xr_origin.add_child(left_hand)

	right_hand = XRController3D.new()
	right_hand.tracker = "right_hand"
	xr_origin.add_child(right_hand)

	# Wire XR controller button signals — replaces joypad polling
	left_hand.button_pressed.connect(_on_left_button_pressed)
	right_hand.button_pressed.connect(_on_right_button_pressed)

	# Instantiate laser pointer for UI interactions
	var pointer_scene = preload("res://addons/godot-xr-tools/functions/function_pointer.tscn")
	assert(pointer_scene)

	laser_pointer = pointer_scene.instantiate()
	assert(laser_pointer.has_method("set_collide_with_areas"))
	right_hand.add_child(laser_pointer)
	# Ensure it can hit our 3D interactables
	laser_pointer.set_collide_with_areas(true)
	
	# XR Tools updates the laser transform dynamically, so simple node scaling breaks.
	# We must increase its raycast distance and scale the visual meshes directly.
	if "distance" in laser_pointer:
		laser_pointer.distance = 100.0 * WORLD_SCALE
		
	if "target_radius" in laser_pointer:
		laser_pointer.target_radius *= WORLD_SCALE

	# Scale the actual laser beam's thickness
	var laser_mesh_node = laser_pointer.get_node_or_null("Laser")
	if laser_mesh_node and laser_mesh_node.mesh:
		var new_laser_mesh = laser_mesh_node.mesh.duplicate()
		if new_laser_mesh is CylinderMesh:
			new_laser_mesh.top_radius *= WORLD_SCALE
			new_laser_mesh.bottom_radius *= WORLD_SCALE
		elif new_laser_mesh is BoxMesh:
			new_laser_mesh.size.x *= WORLD_SCALE
			new_laser_mesh.size.y *= WORLD_SCALE
		laser_mesh_node.mesh = new_laser_mesh

	# Dedicated raycast for world interaction (avoids depending on XR Tools internal UI pointer logic)
	_world_raycast = RayCast3D.new()
	_world_raycast.target_position = Vector3(0, 0, -100 * WORLD_SCALE) # Scale raycast distance to ensure it reaches the floor
	_world_raycast.collision_mask = 1
	right_hand.add_child(_world_raycast)

	await get_tree().process_frame

func _physics_process(delta: float) -> void:
	if _is_locked:
		return

	if _ghost_tower:
		if is_instance_valid(_world_raycast) and _world_raycast.is_colliding():
			_world_raycast.add_exception_rid(_ghost_tower.get_rid())
		_update_ghost_position()

# Left controller button handler — ax_button=recenter (X)
func _on_left_button_pressed(button_name: String) -> void:
	if _is_locked:
		return
	if button_name == "ax_button":
		_recenter_player()

# Right controller button handler — trigger=confirm/dismiss, ax=cancel placement / fire projectile, by=rotate ghost
func _on_right_button_pressed(button_name: String) -> void:
	if _is_locked:
		return
	if _ghost_tower:
		if button_name == "trigger_click":
			_confirm_placement()
		elif button_name == "ax_button":
			cancel_placement()
		elif button_name == "by_button":
			_rotate_ghost_tower()
	else:
		if button_name == "trigger_click":
			# Pick up the tower the controller is pointing at, if any.
			# Building.move() refunds the full invested cost and re-enters placement mode.
			var pointed_tower := _get_pointed_tower()
			if pointed_tower:
				pointed_tower.move()
			elif game_board:
				game_board.hide_building_menu()
		elif button_name == "ax_button":
			_fire_mage_projectile()

func _fire_mage_projectile() -> void:
	var ray_origin := right_hand.global_position
	var ray_dir := -right_hand.global_transform.basis.z.normalized()
	var endpoint: Vector3
	if is_instance_valid(_world_raycast) and _world_raycast.is_colliding():
		endpoint = _world_raycast.get_collision_point()
	else:
		endpoint = ray_origin + ray_dir * fire_max_distance
	endpoint += Vector3(
		_rng.randf_range(-fire_endpoint_spread, fire_endpoint_spread),
		0.0,
		_rng.randf_range(-fire_endpoint_spread, fire_endpoint_spread),
	)

	# Use Area3D.new() + set_script() — Script.new() on the preloaded GDScript
	# was throwing "Nonexistent function 'new' in base 'GDScript'" at runtime.
	var proj := Area3D.new()
	proj.set_script(load(PLAYER_MAGE_PROJECTILE_PATH))
	if world_content_root:
		world_content_root.add_child(proj)
	else:
		get_parent().add_child(proj)
	proj.setup(ray_origin, endpoint)

func start_placement(script_path: String, source_position: Vector3 = Vector3.INF) -> void:
	cancel_placement()
	_placement_script = script_path
	_ghost_rotation = Vector3.ZERO
	_ignore_next_placement_confirm = true  # block instant placement after selecting from shelf
	_placement_source_position = source_position
	var building_class = load(script_path) as Script
	_placement_cost = building_class.get_cost()

	_ghost_tower = StaticBody3D.new()
	_ghost_tower.collision_layer = 0
	_ghost_tower.collision_mask = 0
	_ghost_tower.set_script(load(script_path))
	if world_content_root:
		world_content_root.add_child(_ghost_tower)
	else:
		get_parent().add_child(_ghost_tower)
	_ghost_tower.set_physics_process(false)
	_ghost_tower.set_process(false)
	_apply_ghost_material(_ghost_tower)
	# Preview the attack radius while the ghost follows the controller ray
	if _ghost_tower.has_method("show_range_indicator"):
		_ghost_tower.show_range_indicator()
	# Spawn ghost from shelf preview position for a natural pick-up transition
	if _placement_source_position != Vector3.INF:
		_ghost_tower.global_position = _placement_source_position
		_update_ghost_color(false)
	else:
		# Fallback when no source position was supplied
		var initial_hit = _get_raycast_hit_point()
		if initial_hit != Vector3.INF:
			_ghost_tower.global_position = initial_hit
		else:
			_ghost_tower.global_position = right_hand.global_position + (-right_hand.global_transform.basis.z * 2.0)
			_update_ghost_color(false)

	if is_instance_valid(_world_raycast):
		_world_raycast.add_exception_rid(_ghost_tower.get_rid())
	_show_placement_zone_indicators()

func cancel_placement() -> void:
	if _ghost_tower:
		if is_instance_valid(_world_raycast):
			_world_raycast.remove_exception_rid(_ghost_tower.get_rid())
		_ghost_tower.queue_free()
		_ghost_tower = null
	_placement_script = ""
	_placement_cost = 0
	_ignore_next_placement_confirm = false
	_placement_source_position = Vector3.INF
	_hide_placement_zone_indicators()

func _rotate_ghost_tower() -> void:
	if _ghost_tower:
		_ghost_tower.rotation.y += _ghost_rotation_step
		_ghost_rotation.y = _ghost_tower.rotation.y

func _update_ghost_position() -> void:
	var hit_point = _get_raycast_hit_point()
	if hit_point != Vector3.INF:
		_ghost_tower.global_position = hit_point
		var valid = true
		if terrain and terrain.is_near_enemy_path(hit_point.x, hit_point.z, tower_path_clearance):
			valid = false
		if _is_in_spawn_no_build_zone(hit_point):
			valid = false
		_update_ghost_color(valid)
	else:
		_update_ghost_color(false)

func _update_ghost_color(valid: bool) -> void:
	var color = Color(0, 1, 0, 0.4) if valid else Color(1, 0, 0, 0.4)
	_apply_custom_color(_ghost_tower, color)

func _apply_ghost_material(node: Node) -> void:
	for child in node.get_children():
		# Skip the tower's range indicator — it owns its own transparent blue material
		if child.is_in_group("range_indicator"):
			continue
		if child is MeshInstance3D:
			var mat = StandardMaterial3D.new()
			mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(1, 1, 1, 0.4)
			child.material_override = mat
		_apply_ghost_material(child)

func _apply_custom_color(node: Node, color: Color) -> void:
	for child in node.get_children():
		# Leave the range indicator blue — don't tint it with the validity color
		if child.is_in_group("range_indicator"):
			continue
		if child is MeshInstance3D:
			if child.material_override is StandardMaterial3D:
				child.material_override.albedo_color = color
		_apply_custom_color(child, color)

func _confirm_placement() -> void:
	# Block instant placement after selecting from shelf
	if _ignore_next_placement_confirm:
		_ignore_next_placement_confirm = false
		return
	var hit_point = _get_raycast_hit_point()
	if hit_point == Vector3.INF:
		cancel_placement()
		return
	if terrain and terrain.is_near_enemy_path(hit_point.x, hit_point.z, tower_path_clearance):
		return
	if _is_in_spawn_no_build_zone(hit_point):
		return

	var building_script = load(_placement_script) as Script
	var tower = building_script.new()
	if world_content_root:
		world_content_root.add_child(tower)
	else:
		get_parent().add_child(tower)
	tower.place(hit_point, Vector3(0, _ghost_rotation.y, 0))

	money -= _placement_cost
	cancel_placement()

# Snap the XR origin so the player ends up at the south edge of the terrain facing north,
# placing the tower shelf (world -X) on the player's left and the wave HUD straight ahead.
func _recenter_player() -> void:
	assert(terrain != null, "_recenter_player requires terrain reference")
	assert(xr_origin != null and camera != null, "_recenter_player requires XR nodes")

	# South-edge target: feet land on terrain ground at z = +half_d, x = 0.
	var half_d: float = (terrain.terrain_depth - 1) * terrain.cell_size * 0.5
	var ground_y: float = terrain.get_height_at(0.0, half_d)
	var feet_target := Vector3(0.0, ground_y, half_d)

	# Head pose in xr_origin's local space — XR-tracked, already in game units due to world_scale.
	var head_local: Transform3D = camera.transform
	var head_local_yaw: float = head_local.basis.get_euler().y
	# Project head offset onto XZ plane — vertical comes from physical head height * world_scale.
	var head_offset_xz := Vector3(head_local.origin.x, 0.0, head_local.origin.z)

	# Pick origin yaw so head ends facing RECENTER_YAW after combining with tracked head yaw.
	var desired_origin_yaw: float = RECENTER_YAW - head_local_yaw
	var origin_basis := Basis(Vector3.UP, desired_origin_yaw)

	# Position xr_origin so head's XZ ends above feet_target XZ. Y stays at terrain ground;
	# the player's head naturally rises by physical_head_height * WORLD_SCALE above that.
	var rotated_offset_xz := origin_basis * head_offset_xz
	var origin_pos := Vector3(
		feet_target.x - rotated_offset_xz.x,
		feet_target.y,
		feet_target.z - rotated_offset_xz.z,
	)

	xr_origin.global_transform = Transform3D(origin_basis, origin_pos)

func _get_raycast_hit_point() -> Vector3:
	if is_instance_valid(_world_raycast) and _world_raycast.is_colliding():
		var collider = _world_raycast.get_collider()
		if terrain and collider != terrain:
			return Vector3.INF
		return _world_raycast.get_collision_point()
	return Vector3.INF


## Returns the Building the controller is currently pointing at, or null if not pointing at one.
## Shares the world raycast (mask=1) — towers and terrain are on the same layer; closest hit wins.
func _get_pointed_tower() -> Building:
	if not is_instance_valid(_world_raycast) or not _world_raycast.is_colliding():
		return null
	var collider := _world_raycast.get_collider()
	if collider is Building:
		return collider as Building
	return null


## True if `pos` is within any enemy spawn's no-build radius. Uses XZ distance only so
## elevation differences (player on a hill above a spawn) don't accidentally allow placement.
func _is_in_spawn_no_build_zone(pos: Vector3) -> bool:
	for spawn in get_tree().get_nodes_in_group("enemy_spawn"):
		if not (spawn is Node3D):
			continue
		var sp := spawn as Node3D
		var dx: float = pos.x - sp.global_position.x
		var dz: float = pos.z - sp.global_position.z
		var radius: float = sp.get("no_build_radius") if "no_build_radius" in sp else 0.0
		if sqrt(dx * dx + dz * dz) < radius:
			return true
	return false


func _show_placement_zone_indicators() -> void:
	_hide_placement_zone_indicators()
	var root: Node3D = world_content_root if world_content_root else get_parent() as Node3D
	if not root:
		return

	# Orange torus ring for each spawn's no-build radius
	for spawn_node in get_tree().get_nodes_in_group("enemy_spawn"):
		if not (spawn_node is Node3D):
			continue
		var sp := spawn_node as Node3D
		var radius: float = sp.get("no_build_radius") if "no_build_radius" in sp else 0.0
		if radius <= 0.0:
			continue

		var ring := MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = maxf(radius - 1.5, 0.1)
		torus.outer_radius = radius + 1.5
		ring.mesh = torus

		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(1.0, 0.45, 0.0, 0.65)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ring.material_override = mat

		root.add_child(ring)
		var hy: float = terrain.get_height_at(sp.global_position.x, sp.global_position.z) + 0.2 if terrain else sp.global_position.y
		ring.global_position = Vector3(sp.global_position.x, hy, sp.global_position.z)
		_placement_zone_indicators.append(ring)

	# Red ribbon along each enemy path showing the tower_path_clearance corridor
	if terrain:
		for path in terrain.get_road_paths_world():
			var ribbon := _create_path_clearance_ribbon(path, tower_path_clearance)
			if ribbon:
				root.add_child(ribbon)
				_placement_zone_indicators.append(ribbon)


func _hide_placement_zone_indicators() -> void:
	for node in _placement_zone_indicators:
		if is_instance_valid(node):
			node.queue_free()
	_placement_zone_indicators.clear()


func _create_path_clearance_ribbon(path: Array, clearance: float) -> MeshInstance3D:
	if path.size() < 2:
		return null
	var imesh := ImmediateMesh.new()
	imesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(path.size() - 1):
		var a: Vector3 = path[i]
		var b: Vector3 = path[i + 1]
		var along := b - a
		if along.length_squared() < 0.0001:
			continue
		along = along.normalized()
		var perp := Vector3(-along.z, 0.0, along.x) * clearance
		var lift := Vector3(0.0, 0.3, 0.0)
		var al := a + perp + lift
		var ar := a - perp + lift
		var bl := b + perp + lift
		var br := b - perp + lift
		imesh.surface_add_vertex(al)
		imesh.surface_add_vertex(ar)
		imesh.surface_add_vertex(bl)
		imesh.surface_add_vertex(bl)
		imesh.surface_add_vertex(ar)
		imesh.surface_add_vertex(br)
	imesh.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = imesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.15, 0.15, 0.4)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	return mi
