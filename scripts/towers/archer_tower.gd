extends "res://scripts/towers/building.gd"

const EnemyQuery = preload("res://scripts/utils/enemy_query.gd")  # shared enemy query helper for range targeting

var range_radius: float = 30.0
var shoot_interval: float = 0.8
var shoot_timer: float = 0.0
var projectiles_per_shot: int = 1
var _tower_model: Node3D  # reference to the base tower model
var _query_shape := SphereShape3D.new()

static func get_cost() -> int:
	return 20  # purchase cost

func get_max_upgrades() -> int:
	# Archer has one purchased upgrade tier above base.
	return 1

func _get_collision_box_size() -> Vector3:
	# Tall box matching the archer tower model — used for physics and mouse picking
	return Vector3(3.2, 17.0, 3.2)

func get_range() -> float:
	# Expose shooting radius so hover and placement preview can visualize range
	return range_radius

func _ready() -> void:
	# Initialize level mapping after local helper nodes are available.
	initialize_level()

func _apply_level(level: int) -> void:
	# Map level to fire stats and visual model.
	assert(level >= 0 and level <= get_max_upgrades(), "Archer level out of range")
	if level == 0:
		range_radius = 30.0
		shoot_interval = 0.8
		projectiles_per_shot = 1
		_query_shape.radius = range_radius
		_set_tower_model("res://assets/Spear Tower.glb", Vector3(0, 4, 0))
		return
	range_radius = 30.0
	shoot_interval = 0.4
	projectiles_per_shot = 2
	_query_shape.radius = range_radius
	_set_tower_model("res://assets/Spear Tower Upgrade .glb", Vector3(0, 4, 0))

func _set_tower_model(scene_path: String, local_position: Vector3) -> void:
	# Replace active visual with the scene for the provided level mapping.
	var tower_scene: PackedScene = load(scene_path)
	assert(tower_scene != null, "Archer tower scene missing: %s" % scene_path)
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
		_shoot_at_enemies()

func _shoot_at_enemies() -> void:
	var enemies = _get_enemies_in_range(global_position, range_radius)
	if enemies.is_empty():
		return
		
	# Fire exactly 'projectiles_per_shot' missiles, each targeting a random enemy in range
	for i in range(projectiles_per_shot):
		var random_enemy = enemies[randi() % enemies.size()]
		if is_instance_valid(random_enemy):
			_spawn_projectile(random_enemy)

func _spawn_projectile(target: Node3D) -> void:
	var projectile := Area3D.new()
	projectile.set_script(load("res://scripts/projectiles/arrow.gd"))
	projectile.set("target", target)

	# Must be in the tree before global_position or setup() are valid.
	get_parent().add_child(projectile)
	projectile.global_position = global_position + Vector3(0, 9, 0)
	projectile.call("setup")

func _get_enemies_in_range(center: Vector3, radius: float) -> Array:
	return EnemyQuery.get_enemies_in_sphere(self, _query_shape, center, radius)
