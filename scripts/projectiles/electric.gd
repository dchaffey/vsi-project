extends Area3D

const EnemyQuery = preload("res://scripts/utils/enemy_query.gd")  # shared enemy sphere query helper

## Damage dealt to each enemy in the chain.
var damage: float = 20.0
## Max world-unit jump distance between chain targets.
var chain_range: float = 15.0
## Max additional enemies hit after the initial target.
var max_jumps: int = 5

## First enemy — set via setup() before or after add_child, consumed in _run_chain.
var _initial_target: Node3D = null
## Instance-id keyed dict — prevents hitting the same enemy twice.
var _hit_enemies: Dictionary = {}
## World positions of each zapped enemy, in chain order, for line drawing.
var _chain_positions: Array[Vector3] = []
## Seconds the lightning lines remain visible before queue_free.
var _line_lifetime: float = 0.35
## Elapsed seconds since lines were drawn.
var _line_timer: float = 0.0
## Deferred flag — runs chain on first _physics_process so space_state is accessible.
var _pending_chain: bool = false
## Reused sphere shape for EnemyQuery calls.
var _query_shape := SphereShape3D.new()
## Child MeshInstance3D that holds the ImmediateMesh lightning lines.
var _line_mesh_instance: MeshInstance3D


## Call after add_child — records the first enemy to zap.
func setup(initial_target: Node3D) -> void:
	assert(initial_target != null, "electric: initial_target must not be null")
	_initial_target = initial_target


func _ready() -> void:
	collision_layer = 0
	collision_mask = 0
	_pending_chain = true
	_build_line_mesh()


## Create the MeshInstance3D child that will hold lightning geometry.
func _build_line_mesh() -> void:
	_line_mesh_instance = MeshInstance3D.new()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.8, 0.9, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(0.5, 0.8, 1.0)
	mat.emission_energy_multiplier = 6.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_line_mesh_instance.material_override = mat
	add_child(_line_mesh_instance)


func _physics_process(delta: float) -> void:
	if _pending_chain:
		_pending_chain = false
		_run_chain()
		return

	_line_timer += delta
	if _line_timer >= _line_lifetime:
		queue_free()


## Execute the full chain: zap initial target then walk to nearest unvisited neighbours.
func _run_chain() -> void:
	assert(_initial_target != null, "electric: _run_chain called without initial_target")
	if not is_instance_valid(_initial_target):
		queue_free()
		return

	_chain_positions.append(global_position)  # tower origin — first segment draws tower→enemy
	_chain_positions.append(_initial_target.global_position)
	_zap(_initial_target)

	var current_pos: Vector3 = _initial_target.global_position
	for _i in range(max_jumps):
		var next := _find_next_target(current_pos)
		if next == null:
			break
		current_pos = next.global_position
		_chain_positions.append(current_pos)
		_zap(next)

	_draw_lines()


## Damage one enemy and record it as visited.
func _zap(enemy: Node3D) -> void:
	_hit_enemies[enemy.get_instance_id()] = true
	if enemy.has_method("apply_dmg"):
		enemy.apply_dmg(damage)


## Return the nearest unvisited enemy within chain_range of from_pos, or null.
func _find_next_target(from_pos: Vector3) -> Node3D:
	var candidates := EnemyQuery.get_enemies_in_sphere(self, _query_shape, from_pos, chain_range)
	var best: Node3D = null
	var best_dist: float = INF
	for c in candidates:
		if _hit_enemies.has(c.get_instance_id()):
			continue
		var d: float = c.global_position.distance_to(from_pos)
		if d < best_dist:
			best_dist = d
			best = c
	return best


## Build ImmediateMesh line segments: tower origin → first enemy → chain targets.
func _draw_lines() -> void:
	if _chain_positions.size() < 2:
		return
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for i in range(_chain_positions.size() - 1):
		mesh.surface_add_vertex(to_local(_chain_positions[i]))
		mesh.surface_add_vertex(to_local(_chain_positions[i + 1]))
	mesh.surface_end()
	_line_mesh_instance.mesh = mesh
