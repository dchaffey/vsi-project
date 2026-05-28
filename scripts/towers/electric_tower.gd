extends "res://scripts/towers/building.gd"

const EnemyQuery = preload("res://scripts/utils/enemy_query.gd")  # shared enemy sphere query helper

## Firing range — enemies outside this radius are ignored.
var range_radius: float = 35.0
## Seconds between shots.
var shoot_interval: float = 1.2
## Accumulator for shoot_interval.
var shoot_timer: float = 0.0
## Damage the electric projectile deals per chain jump.
var bolt_damage: float = 20.0
## Max enemies the chain can jump to beyond the initial target.
var bolt_max_jumps: int = 4
## Max world-unit distance between chain jumps.
var bolt_chain_range: float = 15.0

var _tower_model: Node3D  # active visual — swapped on level change
var _query_shape := SphereShape3D.new()  # reused for EnemyQuery calls


static func get_cost() -> int:
	return 30  # purchase cost in currency units


func get_max_upgrades() -> int:
	return 1  # one purchasable upgrade tier above base


func _get_collision_box_size() -> Vector3:
	return Vector3(3.5, 10.0, 3.5)  # box matching Basic Tower footprint


func get_range() -> float:
	return range_radius  # exposed for range-indicator and placement preview


func _ready() -> void:
	initialize_level()


func _apply_level(level: int) -> void:
	assert(level >= 0 and level <= get_max_upgrades(), "Electric tower level out of range")
	if level == 0:
		range_radius = 35.0
		shoot_interval = 1.2
		bolt_damage = 20.0
		bolt_max_jumps = 4
		bolt_chain_range = 15.0
		_query_shape.radius = range_radius
		_set_tower_model("res://assets/tesla__tower.glb", Vector3.ZERO)
		return
	# Level 1: faster fire, more damage, longer chain
	range_radius = 45.0
	shoot_interval = 0.7
	bolt_damage = 30.0
	bolt_max_jumps = 6
	bolt_chain_range = 20.0
	_query_shape.radius = range_radius
	_set_tower_model("res://assets/tesla__tower.glb", Vector3.ZERO)


func _set_tower_model(scene_path: String, local_position: Vector3) -> void:
	var tower_scene: PackedScene = load(scene_path) as PackedScene
	assert(tower_scene != null, "Electric tower scene missing: %s" % scene_path)
	if is_instance_valid(_tower_model):
		_tower_model.queue_free()
	_tower_model = tower_scene.instantiate()
	_tower_model.position = local_position
	add_child(_tower_model)


func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation


func _physics_process(delta: float) -> void:
	shoot_timer += delta
	if shoot_timer >= shoot_interval:
		shoot_timer = 0.0
		_shoot()


func _shoot() -> void:
	var enemies := EnemyQuery.get_enemies_in_sphere(self, _query_shape, global_position, range_radius)
	if enemies.is_empty():
		return
	var target: Node3D = enemies[randi() % enemies.size()]
	if is_instance_valid(target):
		_spawn_bolt(target)


func _spawn_bolt(target: Node3D) -> void:
	var bolt := Area3D.new()
	bolt.set_script(load("res://scripts/projectiles/electric.gd"))
	bolt.set("damage", bolt_damage)
	bolt.set("max_jumps", bolt_max_jumps)
	bolt.set("chain_range", bolt_chain_range)
	# Place bolt at tower top so lines originate from there; chain starts at target.
	get_parent().add_child(bolt)
	bolt.global_position = global_position + Vector3(0, 8, 0)
	bolt.call("setup", target)
