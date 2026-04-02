extends Node3D

## Visual size of the spawn marker cube in world units.
var size: float = 4.0

var terrain: StaticBody3D        ## terrain node — used for height queries when placing the enemy
var defence_objective: Area3D    ## navigation target passed to spawned enemies
var player: CharacterBody3D      ## player ref used to award money on enemy death

var _rng := RandomNumberGenerator.new() ## per-spawn RNG for position jitter
var _enemy_index: int = 0               ## running counter for unique enemy names


func _ready() -> void:
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
func create_enemy() -> RigidBody3D:
	assert(terrain != null, "terrain must be set on EnemySpawn before spawning")
	assert(defence_objective != null, "defence_objective must be set on EnemySpawn before spawning")

	var x: float = position.x + _rng.randf_range(-2.0, 2.0)  # jittered world X
	var z: float = position.z + _rng.randf_range(-2.0, 2.0)  # jittered world Z
	var y: float = terrain.get_height_at(x, z) + 2.0          # just above terrain surface

	var enemy := RigidBody3D.new()
	enemy.position = Vector3(x, y, z)
	enemy.mass = 1.0
	enemy.name = "%s_Enemy_%d" % [name, _enemy_index]
	enemy.collision_layer = 2        # Layer 2 — Enemies
	enemy.collision_mask = 1 | 2 | 4 # Ground, Enemies, Player

	enemy.set_script(load("res://scripts/enemy.gd"))
	enemy.terrain = terrain
	enemy.defence_objective = defence_objective

	_attach_mesh(enemy)
	_attach_collision(enemy)

	enemy.died.connect(func(m_hp: float) -> void:
		if player:
			player.money += m_hp / 100.0  # reward money proportional to max HP
	)

	_enemy_index += 1
	return enemy


## Build and attach the capsule mesh to enemy.
func _attach_mesh(enemy: RigidBody3D) -> void:
	var mesh_instance := MeshInstance3D.new()
	var capsule_mesh := CapsuleMesh.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.85, 0.85)  # light grey
	capsule_mesh.material = mat
	mesh_instance.mesh = capsule_mesh
	enemy._material = mat  # stored on enemy for HP-based colour changes
	enemy.add_child(mesh_instance)


## Build and attach the capsule collision shape to enemy.
func _attach_collision(enemy: RigidBody3D) -> void:
	var collision_shape := CollisionShape3D.new()
	collision_shape.shape = CapsuleShape3D.new()
	enemy.add_child(collision_shape)
