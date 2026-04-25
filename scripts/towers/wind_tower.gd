extends "res://scripts/towers/building.gd"

const EnemyQuery = preload("res://scripts/utils/enemy_query.gd")

var range_radius: float = 20.0  # detection radius for enemies
var wind_force: float = 20.0  # impulse magnitude per blast
var wind_direction: Vector3 = Vector3(0, 0, -1)  # static wind direction (forward)
var cylinder_radius: float = 8.0  # radius of the visualization cylinder
var blast_height_offset: float = 1.5  # shared local Y offset used by both the visual and physics blast volume
var blast_cooldown: float = 3.0  # time between blasts in seconds
var blast_duration: float = 0.3  # how long each blast lasts in seconds
var _time_since_last_blast: float = 0.0  # elapsed time since last wind blast
var _blast_active_time: float = 0.0  # elapsed time during current blast

var _model_visual: Node3D  # animated windmill model
var _cylinder_visual: MeshInstance3D  # semi-transparent cylinder showing wind blast area
var _blast_query_shape := CylinderShape3D.new()  # shared cylinder shape used for blast physics queries
var _cylinder_material: StandardMaterial3D  # shared cylinder material toggled between idle and active blast visuals

const _BLAST_IDLE_COLOR := Color(0.5, 0.8, 1.0, 0.25)  # baseline cylinder tint when no gust is active
const _BLAST_ACTIVE_COLOR := Color(0.9, 0.98, 1.0, 0.58)  # brighter cylinder tint while gust is actively applying force

const MODEL = preload("res://assets/mühle.glb")

static func get_cost() -> int:
	return 40  # purchase cost

func get_max_upgrades() -> int:
	# Wind tower has one purchased upgrade tier above base.
	return 1

func _get_collision_box_size() -> Vector3:
	# Compact cube for the windmill base — used for physics and mouse picking
	return Vector3(3.0, 3.0, 3.0)

func get_range() -> float:
	# Wind blast radius already has its own persistent cylinder visual, so suppress the hover sphere
	return 0.0

func _ready() -> void:
	_model_visual = MODEL.instantiate()
	add_child(_model_visual)
	var anim_player = _model_visual.find_child("AnimationPlayer", true, false)
	anim_player.play("Plane_001Action")
	_create_blast_visuals()
	initialize_level()

func _create_blast_visuals() -> void:
	# Build one reusable cylinder visual driven by _apply_level and blast state.
	_cylinder_visual = MeshInstance3D.new()
	var cylinder_mesh := CylinderMesh.new()
	cylinder_mesh.top_radius = cylinder_radius
	cylinder_mesh.bottom_radius = cylinder_radius
	cylinder_mesh.height = range_radius
	_cylinder_visual.mesh = cylinder_mesh
	_cylinder_visual.rotation.x = deg_to_rad(90)
	_cylinder_visual.position = Vector3(0, blast_height_offset, -range_radius * 0.5)
	_cylinder_material = StandardMaterial3D.new()
	_cylinder_material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	_cylinder_material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
	_cylinder_material.emission_enabled = true
	_cylinder_visual.material_override = _cylinder_material
	_set_blast_visual_active(false)
	_model_visual.add_child(_cylinder_visual)

func _apply_level(level: int) -> void:
	# Map level to wind force/cooldown while reusing the same model and blast geometry.
	assert(level >= 0 and level <= get_max_upgrades(), "Wind level out of range")
	range_radius = 20.0
	cylinder_radius = 8.0
	if level == 0:
		wind_force = 20.0
		blast_cooldown = 3.0
	else:
		wind_force = 35.0
		blast_cooldown = 2.0
	_refresh_blast_shape_and_visual()

func _refresh_blast_shape_and_visual() -> void:
	# Sync query shape and cylinder mesh dimensions with mapped level stats.
	_blast_query_shape.radius = cylinder_radius
	_blast_query_shape.height = range_radius
	assert(_cylinder_visual.mesh is CylinderMesh, "Wind blast visual must use CylinderMesh")
	var cylinder_mesh := _cylinder_visual.mesh as CylinderMesh
	cylinder_mesh.top_radius = cylinder_radius
	cylinder_mesh.bottom_radius = cylinder_radius
	cylinder_mesh.height = range_radius
	_cylinder_visual.position = Vector3(0, blast_height_offset, -range_radius * 0.5)

func place(p_position: Vector3, p_rotation: Vector3 = Vector3.ZERO) -> void:
	global_position = p_position
	rotation = p_rotation

func _physics_process(delta: float) -> void:
	_time_since_last_blast += delta
	if _time_since_last_blast >= blast_cooldown:
		_blast_active_time = 0.0
		_time_since_last_blast = 0.0

	if _blast_active_time < blast_duration:
		_set_blast_visual_active(true)
		var enemies = EnemyQuery.get_enemies_in_shape(self, _blast_query_shape, _get_blast_shape_transform())
		if not enemies.is_empty():
			_apply_wind_to_enemies(enemies)
		_blast_active_time += delta
	else:
		_set_blast_visual_active(false)

func _get_blast_shape_transform() -> Transform3D:
	var local_rotation := Basis(Vector3.RIGHT, deg_to_rad(90.0))  # rotate cylinder Y-axis to local Z-axis (forward volume)
	var world_rotation := global_basis * local_rotation
	var local_center := Vector3(0.0, blast_height_offset, -_blast_query_shape.height * 0.5)  # center placed halfway forward from tower origin
	var world_center := to_global(local_center)
	return Transform3D(world_rotation, world_center)

func _set_blast_visual_active(is_active: bool) -> void:
	if not _cylinder_material:
		return
	if is_active:
		_cylinder_material.albedo_color = _BLAST_ACTIVE_COLOR
		_cylinder_material.emission = _BLAST_ACTIVE_COLOR
		_cylinder_material.emission_energy_multiplier = 2.0
		return
	_cylinder_material.albedo_color = _BLAST_IDLE_COLOR
	_cylinder_material.emission = _BLAST_IDLE_COLOR
	_cylinder_material.emission_energy_multiplier = 0.3

func _apply_wind_to_enemies(enemies: Array) -> void:
	# Transform wind direction to world space based on tower's rotation
	var world_wind_direction = global_basis * wind_direction
	# Apply constant wind impulse to all enemies in range — per-frame impulse preserves old tuning and ragdolls on first frame above threshold
	for enemy in enemies:
		if enemy.has_method("apply_impulse"):
			enemy.apply_impulse(world_wind_direction, wind_force)
