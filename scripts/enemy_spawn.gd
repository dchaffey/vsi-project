extends Node3D

## Visual size of the spawn marker cube in world units.
var size: float = 4.0
## Horizontal radius around the spawn where the player cannot place towers.
## Queried by vr_player via the "enemy_spawn" group; tweak per-instance if needed.
var no_build_radius: float = 50.0

var terrain: StaticBody3D        ## terrain node — used for height queries when placing the enemy
var defence_objective: Area3D    ## navigation target passed to spawned enemies
var player: CharacterBody3D      ## player ref used to award money on enemy death

var _rng := RandomNumberGenerator.new() ## per-spawn RNG for position jitter
var _enemy_index: int = 0               ## running counter for unique enemy names


func _ready() -> void:
	add_to_group("enemy_spawn")  # registers this spawn so the player can query no-build zones
	_build_marker_mesh()


## Builds the red semi-transparent cube that marks this spawn point.
func _build_marker_mesh() -> void:
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(size, size, size)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.2, 0.2)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.6
	box_mesh.material = mat
	mesh_instance.mesh = box_mesh
	add_child(mesh_instance)


## Create one enemy near this spawn point with position jitter. Called by wave manager.
func create_enemy(wave_number: int = 1) -> CharacterBody3D:
	assert(terrain != null, "terrain must be set on EnemySpawn before spawning")
	assert(defence_objective != null, "defence_objective must be set on EnemySpawn before spawning")

	var x: float = position.x + _rng.randf_range(-2.0, 2.0)  # jittered world X
	var z: float = position.z + _rng.randf_range(-2.0, 2.0)  # jittered world Z
	var y: float = terrain.get_height_at(x, z) + 2.0          # just above terrain surface

	var enemy := CharacterBody3D.new()
	enemy.position = Vector3(x, y, z)
	enemy.name = "%s_Enemy_%d" % [name, _enemy_index]
	enemy.collision_layer = 2            # Layer 2 — Enemies
	enemy.collision_mask = 1 | 4 | 8 # Ground, Player, Boulder — enemies pass through each other; soft separation force handles spacing

	# Set the script first
	enemy.set_script(load("res://scripts/enemy.gd"))

	# Now set the properties - they should be accessible after set_script
	# Use set() method to avoid type checking issues
	enemy.set("terrain", terrain)
	enemy.set("defence_objective", defence_objective)

	# Wave base speed: 10 at wave 1, +2 per wave, capped at 20.
	var wave_base_speed: float = min(10.0 + float(wave_number - 1) * 2.0, 20.0)

	# 100 resource points randomly split between HP/size and speed.
	# Speed costs 50 pts for +2 (ratio 50:2); HP costs 1 pt for +1 HP and +1% size (ratio 100:1).
	var speed_points: int = _rng.randi_range(0, 100)
	var hp_points: int = 100 - speed_points

	var final_max_hp: float = 100.0 * float(wave_number) + float(hp_points)
	var final_speed: float = min(wave_base_speed + float(speed_points) * (2.0 / 50.0), 20.0)
	var size_mult: float = 1.0 + float(hp_points) * 0.01

	enemy.set("max_hp", final_max_hp)
	enemy.set("hp", final_max_hp)
	enemy.set("move_speed", final_speed)
	enemy.scale = Vector3(size_mult, size_mult, size_mult)

	_attach_mesh(enemy)
	_attach_collision(enemy)

	enemy.died.connect(func(m_hp: float) -> void:
		if player:
			player.money += m_hp / 200.0  # reward money proportional to max HP
	)

	# Assign a laterally-offset copy of one of the A* road paths.
	var paths: Array = terrain.get_road_paths_world()
	if paths.size() > 0:
		var path_idx: int = _enemy_index % paths.size()
		var lateral_offset: float = _rng.randf_range(-1.5, 1.5)
		var offset_path: Array = _apply_lateral_offset(paths[path_idx], lateral_offset)
		enemy.call("assign_path", offset_path, path_idx)

	_enemy_index += 1
	return enemy


## Instantiate the dwarf GLB and attach it to enemy. Feet sit at the bottom of the 2.0-tall collision box.
func _attach_mesh(enemy: CharacterBody3D) -> void:
	var dwarf_scene: PackedScene = load("res://assets/early_dwarf.glb") as PackedScene
	assert(dwarf_scene != null, "Failed to load res://assets/early_dwarf.glb")
	var model := dwarf_scene.instantiate()
	model.position = Vector3(0.0, -1.0, 0.0)  # drop so feet sit at the bottom of the collision box
	model.scale = Vector3(0.75, 0.75, 0.75)
	enemy.add_child(model)

	# Transparent overlay — alpha 0 at full HP so original textures show through.
	# enemy.gd raises alpha to red-tint the model on damage flash and low HP.
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.0, 0.0, 0.0)
	enemy.set("material", mat)
	for mesh_node in _collect_mesh_instances(model):
		mesh_node.material_overlay = mat


## Recursively gather every MeshInstance3D under a node.
func _collect_mesh_instances(node: Node) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		result.append(node as MeshInstance3D)
	for child in node.get_children():
		result.append_array(_collect_mesh_instances(child))
	return result


## Builds a copy of `path` with each waypoint offset laterally by `offset` world units.
func _apply_lateral_offset(path: Array, offset: float) -> Array:
	if path.size() < 2:
		return path.duplicate()
	var result: Array = []
	for i in range(path.size()):
		var pt: Vector3 = path[i]
		var prev: Vector3 = path[maxi(i - 1, 0)]
		var next: Vector3 = path[mini(i + 1, path.size() - 1)]
		var along := Vector2(next.x - prev.x, next.z - prev.z).normalized()
		var perp := Vector2(-along.y, along.x)  # 90° left perpendicular
		result.append(Vector3(pt.x + perp.x * offset, pt.y, pt.z + perp.y * offset))
	return result


## Build a capsule collision shape for the enemy. Capsule's rounded sides slide over
## uneven terrain better than a box.
func _attach_collision(enemy: CharacterBody3D) -> void:
	var capsule_radius := 0.6
	var capsule_height := 2.0  # total height incl. hemispherical caps

	var collision_shape := CollisionShape3D.new()
	var capsule_shape := CapsuleShape3D.new()
	capsule_shape.radius = capsule_radius
	capsule_shape.height = capsule_height
	collision_shape.shape = capsule_shape
	enemy.add_child(collision_shape)
