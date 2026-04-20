extends StaticBody3D
class_name Building

# Abstract base class for all tower buildings — subclasses must implement cost, place, destroy, and upgrade

var _hover_mat: StandardMaterial3D = null  # cached overlay — allocated on first hover, shared across frames

func _notification(what: int) -> void:
	# Fires even when subclass overrides _ready() without super — create collision immediately, defer debug
	if what == NOTIFICATION_READY:
		_create_collision_shape_node()
		call_deferred("_spawn_collision_debug_meshes")

func _create_collision_shape_node() -> void:
	# Create and add collision shape node from subclass
	var collision_node := _create_collision_shape()
	if collision_node:
		add_child(collision_node)

func _create_collision_shape() -> CollisionShape3D:
	# Return fully configured collision shape node — subclass must override
	assert(false, "Building._create_collision_shape() must be overridden")
	return null

func _spawn_collision_debug_meshes() -> void:
	# Semi-transparent orange overlay matching each CollisionShape3D child's geometry
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.5, 0.0, 0.3)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # visible from inside and outside
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_attach_debug_mesh_to_shapes(self, mat)

func _attach_debug_mesh_to_shapes(node: Node, mat: StandardMaterial3D) -> void:
	# Recursively finds CollisionShape3D nodes and parents a matching MeshInstance3D to each
	if node is CollisionShape3D and node.shape != null:
		var mesh := _shape_to_debug_mesh(node.shape)
		if mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = mat
			node.add_child(mi)
	for child in node.get_children():
		_attach_debug_mesh_to_shapes(child, mat)

func _shape_to_debug_mesh(shape: Shape3D) -> Mesh:
	# Converts a collision shape to an equivalent renderable mesh
	if shape is CylinderShape3D:
		var m := CylinderMesh.new()
		m.height = shape.height
		m.top_radius = shape.radius
		m.bottom_radius = shape.radius
		return m
	if shape is SphereShape3D:
		var m := SphereMesh.new()
		m.radius = shape.radius
		m.height = shape.radius * 2.0
		return m
	if shape is BoxShape3D:
		var m := BoxMesh.new()
		m.size = shape.size
		return m
	return null

static func get_cost() -> int:
	# Purchase cost in currency units — subclass must override
	assert(false, "Building.get_cost() must be overridden")
	return 0

func _mouse_enter() -> void:
	# Overlay a semi-transparent tint to indicate the building is interactable
	if not _hover_mat:
		_hover_mat = StandardMaterial3D.new()
		_hover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_hover_mat.albedo_color = Color(0.3, 0.8, 1.0, 0.25)  # light blue highlight
		_hover_mat.emission = Color(0.3, 0.8, 1.0, 1.0)  # glow for visibility
		_hover_mat.emission_energy_multiplier = 0.5
		_hover_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_apply_overlay(self, _hover_mat)

func _mouse_exit() -> void:
	# Remove highlight overlay to restore normal appearance
	_apply_overlay(self, null)

func _apply_overlay(node: Node, mat: StandardMaterial3D) -> void:
	# Recursively set material_overlay on all mesh surfaces — leaves original materials intact
	if node is MeshInstance3D:
		node.material_overlay = mat
	for child in node.get_children():
		_apply_overlay(child, mat)

func _input_event(_camera: Camera3D, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	# Relay left-click to HUD to open radial menu for this building
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var board := get_tree().get_first_node_in_group("game_board")
	if board:
		board.show_building_ring(self)
	get_viewport().set_input_as_handled()  # prevent click from also triggering the player's dismiss handler

func place(_p_position: Vector3, _p_rotation: Vector3 = Vector3.ZERO) -> void:
	# Position building at given position and rotation, add to scene — subclass must override
	assert(false, "Building.place() must be overridden")

func destroy() -> void:
	# Refund half the purchase cost to the player before removing from scene.
	var player := get_tree().get_first_node_in_group("player")
	if player:
		player.money += get_cost() / 2
	queue_free()

func upgrade() -> void:
	# Upgrade building stats — subclass must override
	assert(false, "Building.upgrade() must be overridden")
