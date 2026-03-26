extends Node3D

## Visual size of the spawn marker cube in world units.
var size: float = 4.0


func _ready() -> void:
	# Mesh — red semi-transparent cube
	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = Vector3(size, size, size)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.2, 0.2)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color.a = 0.6
	box_mesh.material = mat
	mesh_instance.mesh = box_mesh
	add_child(mesh_instance)
