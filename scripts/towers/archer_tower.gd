extends "res://scripts/towers/building.gd"

var range_radius: float = 30.0
var shoot_interval: float = 0.8
var shoot_timer: float = 0.0
var projectiles_per_shot: int = 1
var _tower_model: Node3D  # reference to the base tower model
var _query_shape := SphereShape3D.new()

const MAX_TIER: int = 1  # highest reachable upgrade index for the archer — caps at double-shot / fast-fire
var _tier: int = 0  # current archer upgrade index — 0 = base, 1 = final

static func get_cost() -> int:
	return 20  # purchase cost

static func get_upgrade_cost() -> int:
	return 30  # currency required to unlock the upgraded mage model + faster fire rate

func _get_collision_box_size() -> Vector3:
	# Tall box matching the archer tower model — used for physics and mouse picking
	return Vector3(3.2, 17.0, 3.2)

func get_range() -> float:
	# Expose shooting radius so hover and placement preview can visualize range
	return range_radius

func _ready() -> void:
	_query_shape.radius = range_radius
	# Visual mesh from imported GLB asset
	var tower_scene: PackedScene = load("res://assets/Spear Tower.glb")
	_tower_model = tower_scene.instantiate()
	_tower_model.position = Vector3(0, 4, 0)  # lift model above node origin
	add_child(_tower_model)

func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation

func can_upgrade() -> bool:
	# Archer upgrade is available until tier hits the cap — drives the 3D menu button visibility
	return _tier < MAX_TIER

func upgrade() -> void:
	assert(can_upgrade(), "Archer tower already at max tier")
	_tier += 1
	shoot_interval = 0.4
	projectiles_per_shot = 2
	_query_shape.radius = range_radius

	# Swap to upgraded model
	_tower_model.queue_free()
	var upgraded_scene: PackedScene = load("res://assets/Spear Tower Upgrade .glb")
	_tower_model = upgraded_scene.instantiate()
	_tower_model.position = Vector3(0, 4, 0)
	add_child(_tower_model)

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
	projectile.target = target

	# Must be in the tree before global_position or setup() are valid.
	get_parent().add_child(projectile)
	projectile.global_position = global_position + Vector3(0, 9, 0)
	projectile.setup()

func _get_enemies_in_range(center: Vector3, radius: float) -> Array:
	if radius <= 0.0:
		return []
		
	if not is_equal_approx(_query_shape.radius, radius):
		_query_shape.radius = radius
		
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _query_shape
	query.transform = Transform3D(Basis(), center)
	query.collision_mask = 2 # Only detect enemies
	
	var results = get_world_3d().direct_space_state.intersect_shape(query)
	var bodies := []
	for result in results:
		bodies.append(result.collider)
	
	return bodies
