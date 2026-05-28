extends StaticBody3D
class_name Building

# Abstract base class for all tower buildings — subclasses override _get_collision_box_size, get_range, place, _apply_level

var _hover_mat: StandardMaterial3D = null  # cached hover overlay tint — shared across frames
var _range_indicator: MeshInstance3D = null  # transparent sphere showing attack range — toggled on hover/placement
var _upgrade_level: int = 0  # current upgrade level where 0 is base placement and increments per purchased upgrade
var _auto_upgrade_elapsed: float = 0.0  # active-wave seconds accumulated toward next free upgrade
var _bar_root: Node3D = null             # container for the upgrade progress bar — created lazily in _process
var _bar_fill: MeshInstance3D = null     # fill quad, scaled/offset each frame to show progress

const MAX_UPGRADES_DEFAULT: int = 3  # global ceiling for number of upgrades any tower can expose
const _BAR_WIDTH: float = 2.4
const _BAR_HEIGHT: float = 0.6

func _notification(what: int) -> void:
	if what == NOTIFICATION_READY:
		_create_collision_shape_node()

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

func _get_auto_upgrade_duration() -> float:
	# next_lvl^2 * 10s + 20s  →  lvl 0→1: 30s, 1→2: 60s, 2→3: 110s
	var next_lvl := _upgrade_level + 1
	return float(next_lvl * next_lvl) * 10.0 + 20.0

func initialize_level() -> void:
	# Apply the base-level mapping once after subclass setup has created required helper nodes/shapes.
	_upgrade_level = 0
	_auto_upgrade_elapsed = 0.0
	_apply_level(_upgrade_level)

func _apply_level(_level: int) -> void:
	# Level-to-stats/model mapping hook — subclass must define all per-level state.
	assert(false, "Building._apply_level(level) must be overridden")

func _process(delta: float) -> void:
	if _bar_root == null:
		_create_upgrade_bar()
	_bar_root.visible = can_upgrade()
	if not can_upgrade():
		return
	if not get_tree().get_nodes_in_group("enemies").is_empty():
		_auto_upgrade_elapsed += delta
	var duration := _get_auto_upgrade_duration()
	if _auto_upgrade_elapsed >= duration:
		_auto_upgrade_elapsed = 0.0
		_perform_auto_upgrade()
		if not can_upgrade():
			return
	_update_upgrade_bar(_auto_upgrade_elapsed / _get_auto_upgrade_duration())
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var to_cam := cam.global_position - _bar_root.global_position
		to_cam.y = 0.0
		if not to_cam.is_zero_approx():
			_bar_root.rotation.y = atan2(to_cam.x, to_cam.z)

func _perform_auto_upgrade() -> void:
	if not can_upgrade():
		return
	_upgrade_level += 1
	_apply_level(_upgrade_level)
	if is_instance_valid(_range_indicator):
		var mesh := _range_indicator.mesh as SphereMesh
		var r := get_range()
		mesh.radius = r
		mesh.height = r * 2.0

func _create_upgrade_bar() -> void:
	_bar_root = Node3D.new()
	_bar_root.position = Vector3(0.0, _get_collision_box_size().y + 0.3, 0.0)
	var bg_mesh := QuadMesh.new()
	bg_mesh.size = Vector2(_BAR_WIDTH, _BAR_HEIGHT)
	var bg_mat := StandardMaterial3D.new()
	bg_mat.albedo_color = Color(0.15, 0.15, 0.15, 0.75)
	bg_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bg_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bg_mat.no_depth_test = true
	bg_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var bg_mi := MeshInstance3D.new()
	bg_mi.mesh = bg_mesh
	bg_mi.material_override = bg_mat
	_bar_root.add_child(bg_mi)
	var fill_mesh := QuadMesh.new()
	fill_mesh.size = Vector2(_BAR_WIDTH, _BAR_HEIGHT)
	var fill_mat := StandardMaterial3D.new()
	fill_mat.albedo_color = Color(1.0, 0.8, 0.0, 1.0)
	fill_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fill_mat.no_depth_test = true
	fill_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_bar_fill = MeshInstance3D.new()
	_bar_fill.mesh = fill_mesh
	_bar_fill.material_override = fill_mat
	_bar_fill.position.z = 0.01
	_bar_root.add_child(_bar_fill)
	add_child(_bar_root)

func _update_upgrade_bar(progress: float) -> void:
	_bar_fill.scale.x = progress
	_bar_fill.position.x = _BAR_WIDTH * (progress - 1.0) / 2.0

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
	# Skip the range indicator and upgrade bar so the hover tint never paints them.
	if node == _range_indicator or node == _bar_root:
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
