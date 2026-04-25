extends RefCounted

const ENEMY_GROUP: StringName = &"enemies"  # canonical runtime group containing all active enemy nodes
const ENEMY_COLLISION_MASK: int = 2  # physics layer mask used by enemy bodies
const SHAPE_QUERY_MAX_RESULTS: int = 256  # max overlaps returned per physics shape query


## Returns all enemies in a spherical range using group lookups + physics fallback.
static func get_enemies_in_sphere(source_node: Node3D, sphere_shape: SphereShape3D, center: Vector3, radius: float, exclude_rids: Array[RID] = []) -> Array[Node3D]:
	assert(source_node != null, "source_node is required for enemy sphere query")
	assert(sphere_shape != null, "sphere_shape is required for enemy sphere query")
	assert(radius >= 0.0, "radius must be non-negative")
	if radius <= 0.0:
		return []

	if not is_equal_approx(sphere_shape.radius, radius):
		sphere_shape.radius = radius

	var query := _build_shape_query(sphere_shape, Transform3D(Basis(), center), ENEMY_COLLISION_MASK, exclude_rids)
	var physics_results := source_node.get_world_3d().direct_space_state.intersect_shape(query, SHAPE_QUERY_MAX_RESULTS)
	var enemies: Array[Node3D] = []
	var seen_ids := {}  # instance-id set for deduplicating merged query sources
	_append_group_enemies(source_node, center, radius, enemies, seen_ids)
	_append_shape_query_results(physics_results, center, radius, enemies, seen_ids)
	return enemies


## Returns all enemies intersecting an arbitrary shape query in world space.
static func get_enemies_in_shape(source_node: Node3D, shape: Shape3D, shape_transform: Transform3D, collision_mask: int = ENEMY_COLLISION_MASK, exclude_rids: Array[RID] = []) -> Array[Node3D]:
	assert(source_node != null, "source_node is required for enemy shape query")
	assert(shape != null, "shape is required for enemy shape query")
	var query := _build_shape_query(shape, shape_transform, collision_mask, exclude_rids)
	var physics_results := source_node.get_world_3d().direct_space_state.intersect_shape(query, SHAPE_QUERY_MAX_RESULTS)
	var enemies: Array[Node3D] = []
	var seen_ids := {}  # instance-id set for deduplicating physics overlaps
	for result in physics_results:
		var collider: Object = result.collider  # collider object returned in each shape query hit
		if not (collider is Node3D):
			continue
		var enemy := collider as Node3D
		if not _is_enemy_node(enemy):
			continue
		var enemy_id := enemy.get_instance_id()  # runtime-unique id for dedupe tracking
		if seen_ids.has(enemy_id):
			continue
		seen_ids[enemy_id] = true
		enemies.append(enemy)
	return enemies


## Filters Area3D overlap results down to unique enemy nodes.
static func get_enemies_from_overlaps(overlaps: Array) -> Array[Node3D]:
	var enemies: Array[Node3D] = []
	var seen_ids := {}  # instance-id set for deduplicating overlap arrays
	for overlap in overlaps:
		if not (overlap is Node3D):
			continue
		var enemy := overlap as Node3D
		if not _is_enemy_node(enemy):
			continue
		var enemy_id := enemy.get_instance_id()  # runtime-unique id for dedupe tracking
		if seen_ids.has(enemy_id):
			continue
		seen_ids[enemy_id] = true
		enemies.append(enemy)
	return enemies


## Builds query parameters object shared by all shape-based enemy queries.
static func _build_shape_query(shape: Shape3D, shape_transform: Transform3D, collision_mask: int, exclude_rids: Array[RID]) -> PhysicsShapeQueryParameters3D:
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = shape_transform
	query.collision_mask = collision_mask
	query.collide_with_bodies = true
	query.collide_with_areas = false
	query.exclude = exclude_rids
	return query


## Appends in-range enemies from group membership to the merged result list.
static func _append_group_enemies(source_node: Node3D, center: Vector3, radius: float, enemies: Array[Node3D], seen_ids: Dictionary) -> void:
	var group_nodes := source_node.get_tree().get_nodes_in_group(ENEMY_GROUP)
	for node in group_nodes:
		if not (node is Node3D):
			continue
		var enemy := node as Node3D
		if enemy.global_position.distance_to(center) > radius:
			continue
		_append_enemy(enemy, enemies, seen_ids)


## Appends in-range enemies from shape-query hits to the merged result list.
static func _append_shape_query_results(query_results: Array, center: Vector3, radius: float, enemies: Array[Node3D], seen_ids: Dictionary) -> void:
	for result in query_results:
		var collider: Object = result.collider  # collider object returned in each shape query hit
		if not (collider is Node3D):
			continue
		var enemy := collider as Node3D
		if enemy.global_position.distance_to(center) > radius:
			continue
		_append_enemy(enemy, enemies, seen_ids)


## Adds a node once when it passes enemy identification checks.
static func _append_enemy(enemy: Node3D, enemies: Array[Node3D], seen_ids: Dictionary) -> void:
	if not _is_enemy_node(enemy):
		return
	var enemy_id := enemy.get_instance_id()  # runtime-unique id for dedupe tracking
	if seen_ids.has(enemy_id):
		return
	seen_ids[enemy_id] = true
	enemies.append(enemy)


## Enemy identity check shared across group, physics, and overlap pathways.
static func _is_enemy_node(node: Node3D) -> bool:
	return node.is_in_group(ENEMY_GROUP) or node.has_method("apply_impulse")
