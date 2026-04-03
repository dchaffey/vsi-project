extends StaticBody3D

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
