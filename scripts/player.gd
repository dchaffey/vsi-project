extends Node3D

func _ready() -> void:
	spawn_cube()

func spawn_cube() -> void:
	# 1. Create the MeshInstance3D node
	var cube = MeshInstance3D.new()
	
	# 2. Create and assign a BoxMesh resource
	var mesh = BoxMesh.new()
	mesh.size = Vector3(1, 1, 1)
	cube.mesh = mesh
	
	# 3. Position the cube
	cube.position = Vector3(0, 0, 0)
	
	# 4. Add it as a child of the current node
	add_child(cube)
	
	print("Cube spawned at: ", cube.position)
