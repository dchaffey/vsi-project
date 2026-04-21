extends "res://scripts/towers/building.gd"

var range_radius: float = 30.0
var shoot_interval: float = 0.8
var shoot_timer: float = 0.0
var projectiles_per_shot: int = 1
var _tower_model: Node3D  # reference to the base tower model
var _query_shape := SphereShape3D.new()

const MAX_TIER: int = 1  # highest reachable upgrade index for the mage — final form is the Mage2 model
var _tier: int = 0  # current mage upgrade index — 0 = base tower, 1 = Mage2

static func get_cost() -> int:
	return 20  # purchase cost

static func get_upgrade_cost() -> int:
	return 30  # currency required to unlock the upgraded mage model + faster fire rate

func _get_collision_box_size() -> Vector3:
	# Tall box matching the mage tower model — used for physics and mouse picking
	return Vector3(4.2, 9.0, 4.2)

func get_range() -> float:
	# Expose shooting radius so hover and placement preview can visualize range
	return range_radius

func _ready() -> void:
	_query_shape.radius = range_radius
	# Visual mesh from imported GLB asset
	var tower_scene: PackedScene = load("res://assets/Tower.glb")
	_tower_model = tower_scene.instantiate()
	_tower_model.position = Vector3(0, 4, 0)  # lift model above node origin
	add_child(_tower_model)

func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation

func can_upgrade() -> bool:
	# Mage upgrade is available until the tower has been swapped to Mage2
	return _tier < MAX_TIER

func upgrade() -> void:
	# Swap the base tower model for the Mage2 model and speed up fire rate.
	assert(can_upgrade(), "Mage tower already at max tier")
	_tier += 1
	if is_instance_valid(_tower_model):
		_tower_model.queue_free()

	var mage_scene: PackedScene = load("res://assets/Mage2.glb")
	var mage_instance := mage_scene.instantiate()
	mage_instance.position = Vector3(0, 0, 0)
	add_child(mage_instance)
	shoot_interval = 0.5
	_query_shape.radius = range_radius

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
	var projectile = Area3D.new()
	# Attach script manually; in its _ready or setup it will build its visuals
	projectile.set_script(load("res://scripts/projectiles/mage_projectile.gd"))
	
	# Projectile starts from the top sphere position
	var start_pos = global_position + Vector3(0, 9, 0)
	
	# Add to scene tree first, then call setup
	get_parent().add_child(projectile)
	projectile.setup(start_pos, target)

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
