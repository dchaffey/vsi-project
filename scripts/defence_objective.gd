extends Area3D

## Emitted when an enemy RigidBody3D enters the objective volume.
signal enemy_entered(enemy: Node3D)
## Emitted when HP changes.
signal hp_changed(current: float, max_hp: float)
## Emitted when HP reaches zero.
signal game_over()

## Visual half-size of the cube in world units.
var size: float = 4.0

var max_hp: float = 1000.0
var current_hp: float = 1000.0
var _is_game_over: bool = false


func _ready() -> void:
	# Only detect bodies on layer 2 (Enemies).
	collision_layer = 0
	collision_mask = 2

	# Mesh
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(size, size, size)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.1, 0.4, 1.0)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.6
	box_mesh.material = mat
	mesh_instance.mesh = box_mesh
	add_child(mesh_instance)

	# Collision shape
	var collision_shape := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(size, size, size)
	collision_shape.shape = shape
	add_child(collision_shape)

	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node3D) -> void:
	if _is_game_over:
		return

	if "hp" in body:
		current_hp -= body.hp / 10
		current_hp = max(0.0, current_hp)
		hp_changed.emit(current_hp, max_hp)
		
		if current_hp <= 0.0:
			_is_game_over = true
			game_over.emit()
	
	enemy_entered.emit(body)
