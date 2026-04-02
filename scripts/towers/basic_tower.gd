
extends StaticBody3D

func _ready() -> void:
	# Visual mesh from imported GLB asset
	var tower_scene: PackedScene = load("res://assets/Basic Tower.glb")
	var tower_instance := tower_scene.instantiate()
	add_child(tower_instance)

	# Collision shape approximating the tower geometry
	var collision_shape := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.height = 17 # cylinder + part of sphere
	shape.radius = 1.6
	collision_shape.shape = shape
	collision_shape.position = Vector3(0, 8.5, 0)
	add_child(collision_shape)

