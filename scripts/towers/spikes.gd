extends "res://scripts/towers/building.gd"

const EnemyQuery = preload("res://scripts/utils/enemy_query.gd")  # shared enemy query helper for contact-damage detection

var _damage_per_second: float = 100.0  # HP damage dealt per second of contact
var _enemies_in_range: Dictionary = {}  # tracks enemies in damage zone and their contact time
var _collision_radius: float = 2.0  # matches building collision shape
var _query_shape := CylinderShape3D.new()
var _tower_model: Node3D = null  # visual model instance swapped by level mapping when needed

static func get_cost() -> int:
	return 20  # purchase cost

func get_max_upgrades() -> int:
	# Spikes has one purchased upgrade tier above base.
	return 1

func _get_collision_box_size() -> Vector3:
	# Box matching barracks footprint — width/depth follow the damage radius
	return Vector3(_collision_radius * 2.0, 8.0, _collision_radius * 2.0)

func get_range() -> float:
	# Spikes damage only on contact — no ranged indicator
	return 0.0

func _ready() -> void:
	# Initialize level mapping after local helper shapes are available.
	initialize_level()
	# Spike walls reflect player boulders. The StaticBody3D + box collision (from Building)
	# already stops boulders via the shared Ground layer; this material gives Jolt the
	# restitution needed for a visible ricochet rather than a dead stop.
	var phys_mat := PhysicsMaterial.new()
	phys_mat.bounce = 0.7
	physics_material_override = phys_mat

func _apply_level(level: int) -> void:
	# Map level to trap DPS and visual model.
	assert(level >= 0 and level <= get_max_upgrades(), "Spikes level out of range")
	if level == 0:
		_damage_per_second = 100.0
		_set_tower_model("res://assets/Barracks.glb")
	else:
		_damage_per_second = 180.0
		_set_tower_model("res://assets/Barracks.glb")
	_query_shape.height = 8.0
	_query_shape.radius = _collision_radius

func _set_tower_model(scene_path: String) -> void:
	# Replace active visual with the scene for the provided level mapping.
	var tower_scene: PackedScene = load(scene_path)
	assert(tower_scene != null, "Spikes scene missing: %s" % scene_path)
	if is_instance_valid(_tower_model):
		_tower_model.queue_free()
	_tower_model = tower_scene.instantiate()
	add_child(_tower_model)

func _physics_process(delta: float) -> void:
	if _collision_radius <= 0.0:
		return
		
	# Query for enemies in range using the building's collision shape
	var results = EnemyQuery.get_enemies_in_shape(self, _query_shape, Transform3D(Basis(), global_position + Vector3(0, 4, 0)))
	var enemies_now = {}
	for result in results:
		var body = result
		if body.has_method("_update_color"):  # duck typing check for Enemy
			enemies_now[body] = true

	# Remove enemies that left
	for enemy in _enemies_in_range.keys():
		if not enemy in enemies_now:
			_enemies_in_range.erase(enemy)

	# Track newly entered enemies
	for enemy in enemies_now:
		if not enemy in _enemies_in_range:
			_enemies_in_range[enemy] = 0.0

	# Apply continuous damage to enemies in range
	for enemy in _enemies_in_range:
		_enemies_in_range[enemy] += delta
		var damage := _damage_per_second * delta
		enemy.apply_dmg(damage)

func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation
