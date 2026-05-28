extends Area3D

## Emitted when an enemy body enters the objective volume.
signal enemy_entered(enemy: Node3D)
## Emitted when HP changes.
signal hp_changed(current: float, max_hp: float)
## Emitted when HP reaches zero.
signal game_over()

## Visual half-size of the cube in world units.
var size: float = 4.0

var max_hp: float = 100.0
var current_hp: float = 100.0
var _is_game_over: bool = false
var _hp_label: Label3D  # floating readout above the house — updated on hp_changed


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

	_spawn_hp_label()

	body_entered.connect(_on_body_entered)


func _spawn_hp_label() -> void:
	# Static-rotation 3D text floating above the house so players read HP in-world.
	_hp_label = Label3D.new()
	_hp_label.position = Vector3(0.0, size + 2.0, 0.0)  # clear of the house roof
	_hp_label.pixel_size = 0.02
	_hp_label.font_size = 72
	_hp_label.outline_size = 14
	_hp_label.modulate = Color(1.0, 0.35, 0.35)
	_hp_label.no_depth_test = true
	_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_hp_label)
	_refresh_hp_label()


func _refresh_hp_label() -> void:
	# Mirror current_hp / max_hp into the 3D label text.
	assert(_hp_label != null, "HP label must exist before refresh")
	_hp_label.text = "HP: %d / %d" % [current_hp, max_hp]


func _on_body_entered(body: Node3D) -> void:
	if _is_game_over:
		return

	if "hp" in body:
		current_hp -= body.hp / 10
		current_hp = max(0.0, current_hp)
		hp_changed.emit(current_hp, max_hp)
		_refresh_hp_label()

		if current_hp <= 0.0:
			_is_game_over = true
			game_over.emit()
	
	enemy_entered.emit(body)
