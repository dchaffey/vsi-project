extends StaticBody3D
class_name Building

# Abstract base class for all tower buildings — subclasses override _get_collision_box_size, get_range, place, _apply_level

var _hover_mat: StandardMaterial3D = null  # cached hover overlay tint — shared across frames
var _range_indicator: MeshInstance3D = null  # transparent sphere showing attack range — toggled on hover/placement
var _upgrade_level: int = 0  # current upgrade level where 0 is base placement and increments per purchased upgrade

const MAX_UPGRADES_DEFAULT: int = 3  # global ceiling for number of upgrades any tower can expose

func _notification(what: int) -> void:
	# Fires even when subclass overrides _ready() without super — create collision immediately, defer debug
	if what == NOTIFICATION_READY:
		_create_collision_shape_node()
		call_deferred("_spawn_collision_debug_meshes")

func _create_collision_shape_node() -> void:
	# Build one BoxShape3D from the subclass-provided dimensions — used for physics and mouse picking
	var size := _get_collision_box_size()
	assert(size.x > 0.0 and size.y > 0.0 and size.z > 0.0, "Building box size must be positive on all axes")
	var collision_node := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision_node.shape = shape
	collision_node.position = Vector3(0.0, size.y * 0.5, 0.0)  # center box so the base sits on y=0
	add_child(collision_node)

func _get_collision_box_size() -> Vector3:
	# Box dimensions (width, height, depth) for this building — subclass must override
	assert(false, "Building._get_collision_box_size() must be overridden")
	return Vector3.ZERO

func get_range() -> float:
	# Attack radius in world units — 0 means no range visualization (passive buildings). Subclasses override.
	return 0.0

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
	if shape is BoxShape3D:
		var m := BoxMesh.new()
		m.size = shape.size
		return m
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
	return null

static func get_cost() -> int:
	# Purchase cost in currency units — subclass must override
	assert(false, "Building.get_cost() must be overridden")
	return 0

func get_max_upgrades() -> int:
	# Number of upgrade purchases this tower supports — subclasses may override but can never exceed three.
	return MAX_UPGRADES_DEFAULT

func get_upgrade_level() -> int:
	# Current purchased upgrade count for this tower instance.
	return _upgrade_level

func get_upgrade_cost() -> int:
	# Every upgrade purchase costs half of the tower's initial purchase cost.
	assert(can_upgrade(), "Building.get_upgrade_cost() called at max level")
	return int(get_cost() / 2.0)

func get_total_invested_cost() -> int:
	# Total currency spent on this placed tower: base purchase plus fixed half-base upgrade payments.
	var base_cost := get_cost()
	var spent_on_upgrades := _upgrade_level * (base_cost / 2)
	return base_cost + spent_on_upgrades

func get_sell_refund() -> int:
	# Sell refund is always half of the total invested amount at the current level.
	return get_total_invested_cost() / 2

func can_upgrade() -> bool:
	# True while this tower has not reached its declared upgrade cap.
	var max_upgrades := get_max_upgrades()
	assert(max_upgrades >= 0 and max_upgrades <= MAX_UPGRADES_DEFAULT, "Building max upgrades must be in range [0, 3]")
	return _upgrade_level < max_upgrades

func upgrade() -> bool:
	# Deduct money, advance one level, and apply level-specific stats/model mapping.
	if not can_upgrade():
		return false
	var player := get_tree().get_first_node_in_group("player")
	if player == null:
		return false
	var cost := get_upgrade_cost()
	if player.money < cost:
		return false
	player.money -= cost
	_upgrade_level += 1
	_apply_level(_upgrade_level)
	if is_instance_valid(_range_indicator):
		var mesh := _range_indicator.mesh as SphereMesh
		var r := get_range()
		mesh.radius = r
		mesh.height = r * 2.0
	return true

func initialize_level() -> void:
	# Apply the base-level mapping once after subclass setup has created required helper nodes/shapes.
	_upgrade_level = 0
	_apply_level(_upgrade_level)

func _apply_level(_level: int) -> void:
	# Level-to-stats/model mapping hook — subclass must define all per-level state.
	assert(false, "Building._apply_level(level) must be overridden")

func _mouse_enter() -> void:
	# Overlay a semi-transparent tint and show the attack range sphere to indicate interactability
	if not _hover_mat:
		_hover_mat = StandardMaterial3D.new()
		_hover_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_hover_mat.albedo_color = Color(0.3, 0.8, 1.0, 0.25)  # light blue highlight
		_hover_mat.emission = Color(0.3, 0.8, 1.0, 1.0)  # glow for visibility
		_hover_mat.emission_energy_multiplier = 0.5
		_hover_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_apply_overlay(self, _hover_mat)
	show_range_indicator()

func _mouse_exit() -> void:
	# Remove highlight overlay and hide range sphere
	_apply_overlay(self, null)
	hide_range_indicator()

func show_range_indicator() -> void:
	# Reveal a transparent sphere at the tower's attack radius — used on hover and during placement
	var r := get_range()
	if r <= 0.0:
		return
	if not is_instance_valid(_range_indicator):
		_range_indicator = _build_range_indicator(r)
		# Tag so player_controller's ghost material recursion skips this mesh
		_range_indicator.add_to_group("range_indicator")
		add_child(_range_indicator)
	else:
		var mesh := _range_indicator.mesh as SphereMesh
		mesh.radius = r
		mesh.height = r * 2.0
	_range_indicator.visible = true

func hide_range_indicator() -> void:
	# Hide the range sphere if it was created
	if is_instance_valid(_range_indicator):
		_range_indicator.visible = false

func _build_range_indicator(radius: float) -> MeshInstance3D:
	# Construct the transparent sphere mesh+material used to show attack radius
	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.3, 0.8, 1.0, 0.12)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	return mi

func _apply_overlay(node: Node, mat: StandardMaterial3D) -> void:
	# Recursively set material_overlay on all mesh surfaces — leaves original materials intact.
	# Skip the range indicator so the hover tint never paints the range sphere.
	if node == _range_indicator:
		return
	if node is MeshInstance3D:
		node.material_overlay = mat
	for child in node.get_children():
		_apply_overlay(child, mat)

func _input_event(_camera: Camera3D, event: InputEvent, _position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
	# Relay left-click to HUD to open the 3D action menu for this building
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	var board := get_tree().get_first_node_in_group("game_board")
	if board:
		board.show_building_menu(self)
	get_viewport().set_input_as_handled()  # prevent click from also triggering the player's dismiss handler

func place(_p_position: Vector3, _p_rotation: Vector3 = Vector3.ZERO) -> void:
	# Position building at given position and rotation, add to scene — subclass must override
	assert(false, "Building.place() must be overridden")

func destroy() -> void:
	# Refund half the currently invested cost before removing from scene.
	var player := get_tree().get_first_node_in_group("player")
	if player:
		player.money += get_sell_refund()
	queue_free()

func move() -> void:
	# Pick the building back up: full invested refund, re-enter placement with the same script, then delete self.
	var player := get_tree().get_first_node_in_group("player")
	var script_path: String = get_script().resource_path
	if player:
		player.money += get_total_invested_cost()
		if player.has_method("start_placement") and script_path != "":
			player.start_placement(script_path)
	queue_free()
