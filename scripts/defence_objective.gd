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

	# House model — visual representation of the defence objective
	var house_scene := load("res://assets/House.glb") as PackedScene
	assert(house_scene != null, "Failed to load res://assets/House.glb")
	var house_instance := house_scene.instantiate()
	house_instance.position = Vector3(0, -2, 0)  # lift model above node origin
	add_child(house_instance)

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
