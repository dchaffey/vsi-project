extends StaticBody3D

func _ready() -> void:
	# Cylinder base
	var cylinder_mesh_instance = MeshInstance3D.new()
	var cylinder_mesh = CylinderMesh.new()
	cylinder_mesh.top_radius = 3.5
	cylinder_mesh.bottom_radius = 3.5
	cylinder_mesh.height = 9.0
	cylinder_mesh_instance.mesh = cylinder_mesh
	cylinder_mesh_instance.position = Vector3(0, 1, 0)
	add_child(cylinder_mesh_instance)
	
	# Sphere top
	var sphere_mesh_instance = MeshInstance3D.new()
	var sphere_mesh = SphereMesh.new()
	sphere_mesh.radius = 4.0
	sphere_mesh.height = 8.0
	sphere_mesh_instance.mesh = sphere_mesh
	sphere_mesh_instance.position = Vector3(0, 9.0, 0)
	add_child(sphere_mesh_instance)
	
	# Collision (simplified as a cylinder or box)
	var collision_shape = CollisionShape3D.new()
	var shape = CylinderShape3D.new()
	shape.height = 17 # cylinder + part of sphere
	shape.radius = 3.6
	collision_shape.shape = shape
	collision_shape.position = Vector3(0, 1.3, 0)
	add_child(collision_shape)
