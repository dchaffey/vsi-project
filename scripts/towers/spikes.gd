extends "res://scripts/towers/building.gd"

var _damage_per_second: float = 100.0  # HP damage dealt per second of contact
var _enemies_in_range: Dictionary = {}  # tracks enemies in damage zone and their contact time

static func get_cost() -> int:
	return 20  # purchase cost

func _ready() -> void:
	# Visual mesh from imported GLB asset
	var tower_scene: PackedScene = load("res://assets/Barracks.glb")
	var tower_instance := tower_scene.instantiate()
	add_child(tower_instance)

	# Collision shape approximating the tower geometry
	var collision_shape := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.height = 8
	shape.radius = 2.0
	collision_shape.shape = shape
	collision_shape.position = Vector3(0, 4, 0)
	add_child(collision_shape)

	# Damage trigger zone — detects enemy contact
	var damage_area := Area3D.new()
	damage_area.collision_mask = 2  # Only detect enemies on layer 2
	var damage_shape := CylinderShape3D.new()
	damage_shape.height = 8
	damage_shape.radius = 2.5
	var damage_collision := CollisionShape3D.new()
	damage_collision.shape = damage_shape
	damage_collision.position = Vector3(0, 4, 0)
	damage_area.add_child(damage_collision)
	damage_area.body_entered.connect(_on_enemy_entered)
	damage_area.body_exited.connect(_on_enemy_exited)
	add_child(damage_area)

func _physics_process(delta: float) -> void:
	# Apply continuous damage to enemies in range
	for enemy in _enemies_in_range:
		_enemies_in_range[enemy] += delta
		var damage := _damage_per_second * delta
		enemy.apply_dmg(damage)

func _on_enemy_entered(body: Node3D) -> void:
	# Track enemy entering damage zone
	if body.has_meta("is_enemy") or body.get_class() == "RigidBody3D":
		if body.has_method("_update_color"):  # duck typing check for Enemy
			_enemies_in_range[body] = 0.0

func _on_enemy_exited(body: Node3D) -> void:
	# Remove enemy from tracking when leaving
	_enemies_in_range.erase(body)

func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation

func upgrade() -> void:
	# Spikes upgrade placeholder
	pass
