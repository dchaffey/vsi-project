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
func create_enemy() -> CharacterBody3D:
	assert(terrain != null, "terrain must be set on EnemySpawn before spawning")
	assert(defence_objective != null, "defence_objective must be set on EnemySpawn before spawning")

	var x: float = position.x + _rng.randf_range(-2.0, 2.0)  # jittered world X
	var z: float = position.z + _rng.randf_range(-2.0, 2.0)  # jittered world Z
	var y: float = terrain.get_height_at(x, z) + 2.0          # just above terrain surface

	var enemy := CharacterBody3D.new()
	enemy.position = Vector3(x, y, z)
	enemy.name = "%s_Enemy_%d" % [name, _enemy_index]
	enemy.collision_layer = 2        # Layer 2 — Enemies
	enemy.collision_mask = 1 | 2 | 4 # Ground, Enemies, Player

	# Set the script first
	enemy.set_script(load("res://scripts/enemy.gd"))
	
	# Now set the properties - they should be accessible after set_script
	# Use set() method to avoid type checking issues
	enemy.set("terrain", terrain)
	enemy.set("defence_objective", defence_objective)

	_attach_mesh(enemy)
	_attach_collision(enemy)

	enemy.died.connect(func(m_hp: float) -> void:
		if player:
			player.money += m_hp / 100.0  # reward money proportional to max HP
	)

	_enemy_index += 1
	return enemy


## Build and attach the box mesh to enemy.
func _attach_mesh(enemy: CharacterBody3D) -> void:
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(1.2, 2.0, 1.2)  # Stretched cube (rectangular prism)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.85, 0.85)  # light grey
	box_mesh.material = mat
	mesh_instance.mesh = box_mesh
	enemy.set("material", mat)  # stored on enemy for HP-based colour changes
	enemy.add_child(mesh_instance)


## Build and attach the box collision shape to enemy.
func _attach_collision(enemy: CharacterBody3D) -> void:
	var collision_shape := CollisionShape3D.new()
	var box_shape := BoxShape3D.new()
	box_shape.size = Vector3(1.2, 2.0, 1.2)  # Match mesh size
	collision_shape.shape = box_shape
	enemy.add_child(collision_shape)
