extends StaticBody3D

var range_radius: float = 30.0
var shoot_interval: float = 0.5
var shoot_timer: float = 0.0
var projectiles_per_shot: int = 3

func _ready() -> void:
	# Visual mesh from imported GLB asset
	var tower_scene: PackedScene = load("res://assets/Tower.glb")
	var tower_instance := tower_scene.instantiate()
	tower_instance.position = Vector3(0, 4, 0)  # lift model above node origin
	add_child(tower_instance)

	# Collision shape approximating the tower geometry
	var collision_shape := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.height = 17 # cylinder + part of sphere
	shape.radius = 1.6
	collision_shape.shape = shape
	collision_shape.position = Vector3(0, 8.5, 0)
	add_child(collision_shape)

func _physics_process(delta: float) -> void:
	shoot_timer += delta
	if shoot_timer >= shoot_interval:
		shoot_timer = 0.0
		_shoot_at_enemies()

func _shoot_at_enemies() -> void:
	var enemies = await _get_enemies_in_range(global_position, range_radius)
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
	projectile.set_script(load("res://scripts/projectile.gd"))
	
	# Projectile starts from the top sphere position
	var start_pos = global_position + Vector3(0, 9, 0)
	
	# Add to scene tree first, then call setup
	get_parent().add_child(projectile)
	projectile.setup(start_pos, target)

func _get_enemies_in_range(center: Vector3, radius: float) -> Array:
	var area = Area3D.new()
	area.collision_mask = 2 # Only detect enemies
	var col = CollisionShape3D.new()
	var sphere = SphereShape3D.new()
	sphere.radius = radius
	col.shape = sphere
	area.add_child(col)
	
	get_parent().add_child(area)
	area.global_position = center
	
	# Need to wait 2 physics frames for Area3D to populate its internal list
	await get_tree().physics_frame
	await get_tree().physics_frame
	
	var bodies = area.get_overlapping_bodies()
	area.queue_free()
	
	return bodies
