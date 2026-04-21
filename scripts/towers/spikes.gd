extends "res://scripts/towers/building.gd"

var _damage_per_second: float = 100.0  # HP damage dealt per second of contact
var _enemies_in_range: Dictionary = {}  # tracks enemies in damage zone and their contact time
var _collision_radius: float = 2.0  # matches building collision shape
var _query_shape := CylinderShape3D.new()

const MAX_TIER: int = 1  # upgrade cap — final tier nearly doubles contact DPS
var _tier: int = 0  # current spikes upgrade index

static func get_cost() -> int:
	return 20  # purchase cost

static func get_upgrade_cost() -> int:
	return 15  # currency required for the spikes upgrade tier

func _get_collision_box_size() -> Vector3:
	# Box matching barracks footprint — width/depth follow the damage radius
	return Vector3(_collision_radius * 2.0, 8.0, _collision_radius * 2.0)

func get_range() -> float:
	# Spikes damage only on contact — no ranged indicator
	return 0.0

func _ready() -> void:
	_query_shape.height = 8.0
	_query_shape.radius = _collision_radius
	# Visual mesh from imported GLB asset
	var tower_scene: PackedScene = load("res://assets/Barracks.glb")
	var tower_instance := tower_scene.instantiate()
	add_child(tower_instance)

func _physics_process(delta: float) -> void:
	if _collision_radius <= 0.0:
		return
		
	# Query for enemies in range using the building's collision shape
	var query = PhysicsShapeQueryParameters3D.new()
	query.shape = _query_shape
	query.transform = Transform3D(Basis(), global_position + Vector3(0, 4, 0))
	query.collision_mask = 2  # Only detect enemies on layer 2

	var results = get_world_3d().direct_space_state.intersect_shape(query)
	var enemies_now = {}
	for result in results:
		var body = result.collider
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

func can_upgrade() -> bool:
	# Spikes upgrade is available until the tier cap is reached
	return _tier < MAX_TIER

func upgrade() -> void:
	# Raise contact DPS — keeps the barracks footprint but makes the trap noticeably deadlier.
	assert(can_upgrade(), "Spikes already at max tier")
	_tier += 1
	_damage_per_second = 180.0
