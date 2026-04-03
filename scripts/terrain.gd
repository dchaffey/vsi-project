@tool
extends StaticBody3D

## Terrain dimensions (in vertices). The mesh will be (width-1) x (depth-1) quads.
@export var terrain_width: int = 64:
	set(v):
		terrain_width = v
		_queue_rebuild()
@export var terrain_depth: int = 64:
	set(v):
		terrain_depth = v
		_queue_rebuild()
## World-space distance between vertices
@export var cell_size: float = 1.0:
	set(v):
		cell_size = v
		_queue_rebuild()
## Maximum height of the terrain
@export var max_height: float = 8.0:
	set(v):
		max_height = v
		_queue_rebuild()
## Noise frequency — lower values produce smoother, broader hills
@export var noise_frequency: float = 0.02:
	set(v):
		noise_frequency = v
		_queue_rebuild()
## Noise seed (0 = random each game run, but fixed in-editor for stable preview)
@export var noise_seed: int = 0:
	set(v):
		noise_seed = v
		_queue_rebuild()

@export_group("Roads")
## Goal point in grid coordinates (x, z). All roads lead here.
@export var road_goal: Vector2i = Vector2i(32, 32):
	set(v):
		road_goal = v
		_queue_rebuild()
## Starting points in grid coordinates. A road is built from each to the goal.
@export var road_starts: Array[Vector2i]:
	set(v):
		road_starts = v
		_queue_rebuild()
## Road width in cells (the full width; half extends to each side of the path)
@export var road_width: float = 4.0:
	set(v):
		road_width = v
		_queue_rebuild()
## Steepness cost exponent — higher values penalise slopes more aggressively
@export var steepness_exponent: float = 10.0:
	set(v):
		steepness_exponent = v
		_queue_rebuild()
## Color for road surfaces
@export var road_color: Color = Color(0.5, 0.35, 0.2):
	set(v):
		road_color = v
		_queue_rebuild()
## Color for non-road terrain
@export var terrain_color: Color = Color(0.3, 0.6, 0.2):
	set(v):
		terrain_color = v
		_queue_rebuild()
## Color for start-point indicators
@export var start_indicator_color: Color = Color(1.0, 0.2, 0.2):
	set(v):
		start_indicator_color = v
		_queue_rebuild()
## Color for goal indicator
@export var goal_indicator_color: Color = Color(0.2, 0.3, 1.0):
	set(v):
		goal_indicator_color = v
		_queue_rebuild()
## Radius of the indicator spheres
@export var indicator_radius: float = 1.0:
	set(v):
		indicator_radius = v
		_queue_rebuild()

@export_group("Foliage")
@export var foliage_density: float = 0.5:
	set(v):
		foliage_density = v
		_queue_rebuild()
@export var tree_scale_min: float = 0.8:
	set(v):
		tree_scale_min = v
		_queue_rebuild()
@export var tree_scale_max: float = 1.2:
	set(v):
		tree_scale_max = v
		_queue_rebuild()

signal flow_field_changed

var height_map: Array = [] # 2D array [x][z] of floats
var _is_ready := false
# Per-vertex road blend factor [x][z] in [0, 1]. 1 = full road, 0 = terrain.
var _road_blend: Array = []
var _rebuild_queued := false

## Flow field for enemy navigation. Computed once during initial build.
## [x][z] of Vector2 — normalized direction to move toward the nearest road,
## then along the road toward the goal. Zero vector if no paths exist.
var flow_field: Array = []
## Distance-to-nearest-road field. [x][z] of float. 0.0 = on the road.
## INF if no paths exist.
var path_distance: Array = []
## Whether the flow field has been computed. Once true, rebuilds skip recomputation.
var _flow_field_built := false
## Walkability grid. False for cells blocked by placed obstacles.
var _walkable: Array = []  # [x][z] of bool

var foliage_types: Array[FoliageType] = []


func _ready() -> void:
	_is_ready = true
	_setup_foliage_programmatically()
	_rebuild()


func _process(_delta: float) -> void:
	if _rebuild_queued:
		_rebuild_queued = false
		_rebuild()


## Queue a rebuild for the next frame. Coalesces multiple property changes
## that happen during scene load / inspector edits into a single rebuild.
func _queue_rebuild() -> void:
	if not _is_ready:
		return
	_rebuild_queued = true


## Regenerates the height map, mesh, and collision shape.
## Updates the existing MeshInstance3D and CollisionShape3D children that live
## in the .tscn — no add_child() needed, so the editor viewport sees the mesh.
func _rebuild() -> void:
	if not _is_ready:
		return

	height_map = generate_height_map()

	# --- Road generation ---
	_road_blend = _make_empty_blend_map()
	var paths: Array = []
	if road_starts.size() > 0:
		for start in road_starts:
			var path := _find_path(start, road_goal, height_map)
			if path.size() > 0:
				paths.append(path)
		if paths.size() > 0:
			_stamp_roads(height_map, paths)
		print("Roads: %d path(s) found from %d start(s)." % [paths.size(), road_starts.size()])

	# --- Flow field (computed once, never recomputed) ---
	if not _flow_field_built:
		_build_flow_field(paths)

	var array_mesh := _create_terrain_mesh(height_map)

	# Update the MeshInstance3D that already exists in the scene tree
	var mesh_instance: MeshInstance3D = $MeshInstance3D
	if mesh_instance:
		mesh_instance.mesh = array_mesh
		mesh_instance.material_override = _create_terrain_material()

	# Update the CollisionShape3D that already exists in the scene tree
	var col_shape: CollisionShape3D = $CollisionShape3D
	if col_shape:
		col_shape.shape = array_mesh.create_trimesh_shape()

	# --- Place start / goal indicators ---
	_spawn_indicators()

	_spawn_foliage()

	print("Terrain built (%dx%d, cell %.1f, max height %.1f)." % [terrain_width, terrain_depth, cell_size, max_height])


# ---------------------------------------------------------------------------
# Foliage Generation
# ---------------------------------------------------------------------------

func _extract_mesh_from_scene(scene: PackedScene) -> Mesh:
	var state = scene.get_state()
	for i in range(state.get_node_count()):
		for j in range(state.get_node_property_count(i)):
			var prop_name = state.get_node_property_name(i, j)
			if prop_name == "mesh":
				return state.get_node_property_value(i, j)
	return null

func _spawn_foliage() -> void:
	# Clean up old foliage MultiMeshInstances
	for child in get_children():
		if child.is_in_group("_terrain_foliage"):
			child.queue_free()

	if foliage_types.size() == 0:
		return

	var rng = RandomNumberGenerator.new()
	if noise_seed != 0:
		rng.seed = noise_seed
	elif Engine.is_editor_hint():
		rng.seed = 12345
	else:
		rng.seed = randi()

	# Prepare lists of transforms for each foliage type
	var instances_per_type = []
	for i in range(foliage_types.size()):
		instances_per_type.append([])

	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5

	# Generate random positions
	var total_cells = (terrain_width - 1) * (terrain_depth - 1)
	var max_attempts = int(total_cells * foliage_density * 4.0)

	# Margin in grid cells — keeps foliage inside the walls
	var margin = 2.0
	# Path exclusion radius in grid cells — keeps foliage off enemy walkways
	var path_clearance: float = 1.5

	for attempt in range(max_attempts):
		var x = rng.randf_range(margin, float(terrain_width - 1) - margin)
		var z = rng.randf_range(margin, float(terrain_depth - 1) - margin)

		var wx = x * cell_size - half_w
		var wz = z * cell_size - half_d

		# Skip if on or near a road (blend) or enemy path (distance)
		if get_road_blend_at(wx, wz) > 0.05:
			continue
		if get_path_distance(wx, wz) < path_clearance:
			continue

		var height = get_height_at(wx, wz)

		# Probability based on elevation: more dense at bottom
		var elevation_prob = 1.0 - (height / max_height)
		elevation_prob = clampf(elevation_prob, 0.0, 1.0)
		elevation_prob = pow(elevation_prob, 2.0) # Bias towards lower elevation

		if rng.randf() > elevation_prob:
			continue

		# Choose foliage type via weighted random selection
		var total_weight = 0.0
		for ft in foliage_types:
			total_weight += ft.spawn_weight
		var roll = rng.randf() * total_weight
		var chosen_type_idx = 0
		var current_weight = 0.0
		for i in range(foliage_types.size()):
			current_weight += foliage_types[i].spawn_weight
			if roll <= current_weight:
				chosen_type_idx = i
				break

		# Build basis (rotation + scale) separately, then set origin
		var scale = rng.randf_range(tree_scale_min, tree_scale_max)
		var basis = Basis(Vector3.UP, rng.randf_range(0, TAU))
		basis = basis.scaled(Vector3(scale, scale, scale))
		var t = Transform3D(basis, Vector3(wx, height, wz))

		instances_per_type[chosen_type_idx].append(t)

	# Create MultiMeshInstances
	for i in range(foliage_types.size()):
		var type = foliage_types[i]
		var transforms = instances_per_type[i]

		if transforms.size() == 0 or type.mesh == null:
			continue

		var multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.instance_count = transforms.size()
		multimesh.mesh = type.mesh

		for j in range(transforms.size()):
			multimesh.set_instance_transform(j, transforms[j])

		var mmi = MultiMeshInstance3D.new()
		mmi.multimesh = multimesh
		mmi.name = "Foliage_" + str(i)
		mmi.add_to_group("_terrain_foliage")
		add_child(mmi)
		if Engine.is_editor_hint():
			mmi.set_owner(get_tree().edited_scene_root)

# ---------------------------------------------------------------------------
# Start / goal indicators
# ---------------------------------------------------------------------------

## Remove old indicators and spawn fresh spheres for each start and the goal.
func _spawn_indicators() -> void:
	if not Engine.is_editor_hint():
		# Remove any indicator spheres that were saved into the scene file.
		for child in get_children():
			if child is MeshInstance3D and child.mesh is SphereMesh:
				child.queue_free()
		return
	# Remove previous indicators
	for child in get_children():
		if child.is_in_group("_terrain_indicator"):
			child.queue_free()

	# Half-extents (same as mesh construction) for grid -> world conversion
	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5

	# Goal indicator (blue)
	if _in_bounds(road_goal):
		var pos := _grid_to_world(road_goal, half_w, half_d)
		_create_indicator(pos, goal_indicator_color, "goal")

	# Start indicators (red)
	for i in range(road_starts.size()):
		var start: Vector2i = road_starts[i]
		if _in_bounds(start):
			var pos := _grid_to_world(start, half_w, half_d)
			_create_indicator(pos, start_indicator_color, "start_%d" % i)


## Convert a grid coordinate to world position, sampling the height map.
func _grid_to_world(grid: Vector2i, half_w: float, half_d: float) -> Vector3:
	var wx: float = grid.x * cell_size - half_w
	var wz: float = grid.y * cell_size - half_d
	var wy: float = height_map[grid.x][grid.y]
	return Vector3(wx, wy, wz)


## Create a small sphere MeshInstance3D as a child indicator node.
func _create_indicator(pos: Vector3, color: Color, indicator_name: String) -> void:
	var mi := MeshInstance3D.new()
	mi.name = indicator_name

	var sphere := SphereMesh.new()
	sphere.radius = indicator_radius
	sphere.height = indicator_radius * 2.0
	mi.mesh = sphere

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.6
	mi.material_override = mat

	# Position the sphere so its bottom sits on the terrain surface
	mi.position = pos + Vector3(0, indicator_radius, 0)

	mi.add_to_group("_terrain_indicator")
	add_child(mi)
	# Let the editor own the node so it shows in the viewport
	if Engine.is_editor_hint():
		mi.set_owner(get_tree().edited_scene_root)


# ---------------------------------------------------------------------------
# Height-map generation
# ---------------------------------------------------------------------------

## Returns a 2D array [x][z] of height values in [0, max_height].
## Uses Godot's built-in FastNoiseLite (OpenSimplex2 by default) which
## produces smooth, natural-looking Perlin-style noise.
func generate_height_map() -> Array:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.frequency = noise_frequency
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 4
	noise.fractal_lacunarity = 2.0
	noise.fractal_gain = 0.5

	if noise_seed != 0:
		noise.seed = noise_seed
	elif Engine.is_editor_hint():
		noise.seed = 12345
	else:
		noise.seed = randi()

	var map: Array = []
	for x in range(terrain_width):
		var row: Array = []
		for z in range(terrain_depth):
			# FastNoiseLite returns values in [-1, 1]; remap to [0, max_height]
			var n: float = noise.get_noise_2d(float(x), float(z))
			row.append(pow(((n + 1.0) * 0.5 * max_height), 1.5))
		map.append(row)
	return map


# ---------------------------------------------------------------------------
# A* pathfinding with exponential steepness cost
# ---------------------------------------------------------------------------

## Returns an empty 2D blend map [x][z] initialised to 0.0.
func _make_empty_blend_map() -> Array:
	var blend: Array = []
	for x in range(terrain_width):
		var row: Array = []
		row.resize(terrain_depth)
		row.fill(0.0)
		blend.append(row)
	return blend


## A* pathfinding on the height-map grid from `start` to `goal`.
## Cost function uses exponential steepness: exp(k * |slope|).
## Returns an array of Vector2i grid coordinates (empty if no path found).
func _find_path(start: Vector2i, goal: Vector2i, map: Array) -> Array:
	# Validate bounds
	if not _in_bounds(start) or not _in_bounds(goal):
		push_warning("Road path: start %s or goal %s is out of bounds." % [start, goal])
		return []

	# 8-directional neighbors (dx, dz)
	var neighbors := [
		Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
		Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1),
	]

	# Priority queue: array of [f_score, Vector2i], kept sorted via binary insert
	var open_list: Array = []
	# g_score: Dictionary { Vector2i -> float }
	var g_score: Dictionary = {}
	# came_from: Dictionary { Vector2i -> Vector2i }
	var came_from: Dictionary = {}
	# closed set
	var closed: Dictionary = {}

	g_score[start] = 0.0
	var h_start := _heuristic(start, goal)
	_pq_insert(open_list, h_start, start)

	while open_list.size() > 0:
		var current_entry: Array = open_list.pop_front()
		var current: Vector2i = current_entry[1]

		if current == goal:
			return _reconstruct_path(came_from, current)

		if closed.has(current):
			continue
		closed[current] = true

		var current_g: float = g_score[current]
		var current_h: float = map[current.x][current.y]

		for dir in neighbors:
			var nb: Vector2i = current + dir
			if not _in_bounds(nb) or closed.has(nb):
				continue

			# Horizontal distance (diagonal = sqrt(2), cardinal = 1) in cells
			var horiz_dist: float = cell_size if (dir.x == 0 or dir.y == 0) else cell_size * 1.41421356
			var nb_h: float = map[nb.x][nb.y]
			var slope: float = absf(nb_h - current_h) / horiz_dist

			# Exponential steepness cost: flat terrain ~ exp(0) = 1, steep ~ very high
			var move_cost: float = horiz_dist * exp(steepness_exponent * slope)
			var tentative_g: float = current_g + move_cost

			if not g_score.has(nb) or tentative_g < g_score[nb]:
				g_score[nb] = tentative_g
				came_from[nb] = current
				var f: float = tentative_g + _heuristic(nb, goal)
				_pq_insert(open_list, f, nb)

	push_warning("Road path: no path found from %s to %s." % [start, goal])
	return []


## Euclidean heuristic in grid-cell units, scaled by cell_size.
func _heuristic(a: Vector2i, b: Vector2i) -> float:
	var dx: float = float(a.x - b.x) * cell_size
	var dz: float = float(a.y - b.y) * cell_size
	return sqrt(dx * dx + dz * dz)


## Binary insertion into a sorted priority queue (ascending by f-score).
func _pq_insert(pq: Array, f: float, cell: Vector2i) -> void:
	var entry := [f, cell]
	var lo := 0
	var hi := pq.size()
	while lo < hi:
		var mid := (lo + hi) >> 1
		if pq[mid][0] < f:
			lo = mid + 1
		else:
			hi = mid
	pq.insert(lo, entry)


## Reconstruct the path from the came_from map.
func _reconstruct_path(came_from: Dictionary, current: Vector2i) -> Array:
	var path: Array = [current]
	while came_from.has(current):
		current = came_from[current]
		path.push_front(current)
	return path


func _in_bounds(p: Vector2i) -> bool:
	return p.x >= 0 and p.x < terrain_width and p.y >= 0 and p.y < terrain_depth


# ---------------------------------------------------------------------------
# Road stamping — flatten terrain along paths with Gaussian falloff
# ---------------------------------------------------------------------------

## Stamps all road paths into the height map and populates _road_blend.
## The road follows the terrain's general elevation but is locally smoothed
## and flattened. Gaussian falloff blends road edges into the surrounding terrain.
func _stamp_roads(map: Array, paths: Array) -> void:
	var half_width: float = road_width * 0.5
	# Sigma for Gaussian falloff — controls how quickly the road blends out
	var sigma: float = road_width * 0.35
	var two_sigma_sq: float = 2.0 * sigma * sigma
	# Influence radius — extend a bit beyond half_width for the blend region
	var influence_radius: float = half_width + sigma * 2.0
	var influence_radius_sq: float = influence_radius * influence_radius

	# First pass: for each path, compute smoothed centerline heights.
	# We smooth the path heights with a moving-average window so the road
	# doesn't have abrupt elevation changes.
	var all_path_data: Array = []  # Array of { points: Array[Vector2i], heights: PackedFloat64Array }
	for path in paths:
		var smoothed_heights := _smooth_path_heights(map, path)
		all_path_data.append({ "points": path, "heights": smoothed_heights })

	# Second pass: for every cell in the map, check distance to nearest path
	# segment and apply height blending + road color blend.
	for x in range(terrain_width):
		for z in range(terrain_depth):
			var cell := Vector2(float(x), float(z))
			var best_dist_sq: float = INF
			var best_target_h: float = 0.0

			for pd in all_path_data:
				var pts: Array = pd["points"]
				var heights: PackedFloat64Array = pd["heights"]

				for i in range(pts.size() - 1):
					var a := Vector2(float(pts[i].x), float(pts[i].y))
					var b := Vector2(float(pts[i + 1].x), float(pts[i + 1].y))

					# Quick bounding-box reject
					var min_x: float = minf(a.x, b.x) - influence_radius
					var max_x: float = maxf(a.x, b.x) + influence_radius
					var min_z: float = minf(a.y, b.y) - influence_radius
					var max_z: float = maxf(a.y, b.y) + influence_radius
					if float(x) < min_x or float(x) > max_x or float(z) < min_z or float(z) > max_z:
						continue

					# Project cell onto segment a->b, find closest point & parameter t
					var seg: Vector2 = b - a
					var seg_len_sq: float = seg.length_squared()
					var t: float = 0.0
					if seg_len_sq > 0.0001:
						t = clampf((cell - a).dot(seg) / seg_len_sq, 0.0, 1.0)

					var closest: Vector2 = a + seg * t
					var dist_sq: float = cell.distance_squared_to(closest)

					if dist_sq < best_dist_sq and dist_sq < influence_radius_sq:
						best_dist_sq = dist_sq
						# Interpolate smoothed height along segment
						best_target_h = lerpf(heights[i], heights[i + 1], t)

			if best_dist_sq < influence_radius_sq:
				var dist: float = sqrt(best_dist_sq)
				# Gaussian blend factor: 1.0 at center, fading to 0 at edges
				var blend: float
				if dist <= half_width * 0.5:
					# Core of the road — fully flat
					blend = 1.0
				else:
					# Falloff region
					var falloff_dist: float = dist - half_width * 0.5
					blend = exp(-(falloff_dist * falloff_dist) / two_sigma_sq)

				# Blend height: lerp between original terrain and road target
				var original_h: float = map[x][z]
				map[x][z] = lerpf(original_h, best_target_h, blend)

				# Track blend factor for vertex coloring (take max in case of
				# overlapping roads)
				if blend > _road_blend[x][z]:
					_road_blend[x][z] = blend


## Smooth path heights using a moving-average window.
## Returns a PackedFloat64Array of the same length as the path.
func _smooth_path_heights(map: Array, path: Array) -> PackedFloat64Array:
	var raw := PackedFloat64Array()
	for p in path:
		raw.append(map[p.x][p.y])

	# Multiple passes of smoothing for a nice, gradual road grade
	var smoothed := raw.duplicate()
	var window := mini(7, path.size())
	for _pass in range(3):
		var prev := smoothed.duplicate()
		for i in range(smoothed.size()):
			var lo : int = maxi(0, i - window / 2.0)
			var hi := mini(smoothed.size() - 1, i + window / 2.0)
			var sum := 0.0
			for j in range(lo, hi + 1):
				sum += prev[j]
			smoothed[i] = sum / float(hi - lo + 1)

	return smoothed


# ---------------------------------------------------------------------------
# Flow field — precomputed navigation for enemies
# ---------------------------------------------------------------------------

## Build the flow field and distance field from the computed road paths.
## This is called once during the first _rebuild() and never recomputed.
##
## Algorithm:
##   1. Walk each path from start→goal, recording per-cell flow direction
##      (pointing toward the goal along the path) and distance-to-goal.
##   2. Expand path cells outward by road_width/2 so the entire road surface
##      is marked as "on-road" (path_distance = 0).
##   3. BFS flood-fill from all road cells outward. Every off-road cell gets
##      a direction vector pointing toward its nearest road cell, and a
##      distance value equal to the grid-step distance to that road cell.
##
## The result is two grids:
##   flow_field [x][z] — Vector2 direction to follow
##   path_distance [x][z] — 0.0 on road, >0 off road
func _build_flow_field(paths: Array) -> void:
	# Initialise grids
	flow_field = []
	path_distance = []
	_walkable = []
	for x in range(terrain_width):
		var flow_row: Array = []
		flow_row.resize(terrain_depth)
		var dist_row: Array = []
		dist_row.resize(terrain_depth)
		var walk_row: Array = []
		walk_row.resize(terrain_depth)
		for z in range(terrain_depth):
			flow_row[z] = Vector2.ZERO
			dist_row[z] = INF
			walk_row[z] = true
		flow_field.append(flow_row)
		path_distance.append(dist_row)
		_walkable.append(walk_row)

	if paths.size() == 0:
		print("Flow field: no paths provided, field left empty.")
		return

	# ----- Step 1: Mark path centerline cells with goal-directed flow -----
	# For each path cell, store the direction toward the goal (next cell in path)
	# and the distance-to-goal along the path. When paths overlap, keep the
	# shorter distance-to-goal.
	# We also store the goal-distance separately for the on-road BFS seeding.
	var goal_dist_map: Dictionary = {}  # Vector2i -> float (distance to goal along path)

	for path in paths:
		if path.size() < 2:
			continue

		# Compute cumulative distance from goal backward along the path.
		# path[0] = start, path[-1] = goal
		var cum_dist := PackedFloat64Array()
		cum_dist.resize(path.size())
		cum_dist[path.size() - 1] = 0.0
		for i in range(path.size() - 2, -1, -1):
			var dx: float = float(path[i + 1].x - path[i].x)
			var dz: float = float(path[i + 1].y - path[i].y)
			var seg_len: float = sqrt(dx * dx + dz * dz)
			cum_dist[i] = cum_dist[i + 1] + seg_len

		for i in range(path.size()):
			var cell: Vector2i = path[i]
			var d_to_goal: float = cum_dist[i]

			# Only overwrite if this path offers a shorter route to goal
			if not goal_dist_map.has(cell) or d_to_goal < goal_dist_map[cell]:
				goal_dist_map[cell] = d_to_goal

				# Direction: point toward next cell in path (toward goal)
				var dir := Vector2.ZERO
				if i < path.size() - 1:
					var next: Vector2i = path[i + 1]
					dir = Vector2(float(next.x - cell.x), float(next.y - cell.y)).normalized()
				elif i > 0:
					# Goal cell: continue in the direction we arrived from
					var prev: Vector2i = path[i - 1]
					dir = Vector2(float(cell.x - prev.x), float(cell.y - prev.y)).normalized()

				flow_field[cell.x][cell.y] = dir
				path_distance[cell.x][cell.y] = 0.0

	# ----- Step 2: Expand road surface (half-width around centerline) -----
	# BFS from centerline cells outward up to road_width/2 cells.
	# These cells are "on-road" (path_distance = 0) and inherit the flow
	# direction of their nearest centerline cell.
	var half_w_cells: float = road_width * 0.5
	var road_queue: Array = []  # [Vector2i cell, float dist_from_center, Vector2 flow_dir, float goal_dist]
	for cell in goal_dist_map:
		road_queue.append([cell, 0.0, flow_field[cell.x][cell.y], goal_dist_map[cell]])

	var cardinal_dirs := [
		Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
	]
	var diagonal_dirs := [
		Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1),
	]
	var all_dirs := cardinal_dirs + diagonal_dirs

	# Track which cells have been claimed by road expansion (separate from
	# centerline so we don't overwrite centerline cells with worse data).
	var road_visited: Dictionary = {}
	for cell in goal_dist_map:
		road_visited[cell] = true

	var qi := 0
	while qi < road_queue.size():
		var entry: Array = road_queue[qi]
		qi += 1
		var cell: Vector2i = entry[0]
		var dist_from_center: float = entry[1]
		var inherited_flow: Vector2 = entry[2]
		var inherited_goal_dist: float = entry[3]

		for dir in all_dirs:
			var nb: Vector2i = cell + dir
			if not _in_bounds(nb) or road_visited.has(nb):
				continue

			var step: float = 1.0 if (dir.x == 0 or dir.y == 0) else 1.41421356
			var new_dist: float = dist_from_center + step
			if new_dist > half_w_cells:
				continue

			road_visited[nb] = true
			flow_field[nb.x][nb.y] = inherited_flow
			path_distance[nb.x][nb.y] = 0.0
			road_queue.append([nb, new_dist, inherited_flow, inherited_goal_dist])

	# ----- Step 3: BFS flood-fill for off-road cells -----
	# Seed the BFS with all road cells (path_distance == 0). Every off-road
	# cell gets a flow direction pointing toward its nearest road cell.
	var bfs_queue: Array = []  # [Vector2i cell]
	for x in range(terrain_width):
		for z in range(terrain_depth):
			if path_distance[x][z] == 0.0:
				bfs_queue.append(Vector2i(x, z))

	var bi := 0
	while bi < bfs_queue.size():
		var cell: Vector2i = bfs_queue[bi]
		bi += 1
		var current_dist: float = path_distance[cell.x][cell.y]

		for dir in all_dirs:
			var nb: Vector2i = cell + dir
			if not _in_bounds(nb):
				continue

			var step: float = 1.0 if (dir.x == 0 or dir.y == 0) else 1.41421356
			var new_dist: float = current_dist + step

			if new_dist < path_distance[nb.x][nb.y]:
				path_distance[nb.x][nb.y] = new_dist
				# Direction: point from nb toward cell (i.e., toward the road)
				flow_field[nb.x][nb.y] = Vector2(float(cell.x - nb.x), float(cell.y - nb.y)).normalized()
				bfs_queue.append(nb)

	_flow_field_built = true
	print("Flow field built (%dx%d, %d road cells, %d total cells)." % [
		terrain_width, terrain_depth, road_visited.size(), terrain_width * terrain_depth])


# ---------------------------------------------------------------------------
# Flow field queries — public API for enemies / AI
# ---------------------------------------------------------------------------

## Convert world coordinates to continuous grid coordinates, clamped to bounds.
## Returns Vector2(gx, gz). Shared by all world→grid query helpers.
func _world_to_grid(wx: float, wz: float) -> Vector2:
	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5
	var gx: float = clampf((wx + half_w) / cell_size, 0.0, float(terrain_width - 1))
	var gz: float = clampf((wz + half_d) / cell_size, 0.0, float(terrain_depth - 1))
	return Vector2(gx, gz)


## Returns the flow direction at a world-space (wx, wz) position.
## The returned Vector2 is a normalised direction in grid space (x, z).
## To use as a 3D velocity: Vector3(dir.x, 0, dir.y).normalized() * speed.
## Returns Vector2.ZERO if the flow field has not been built.
func get_flow_direction(wx: float, wz: float) -> Vector2:
	if flow_field.size() == 0:
		return Vector2.ZERO

	var g := _world_to_grid(wx, wz)
	var x0 := mini(int(g.x), terrain_width - 2)
	var z0 := mini(int(g.y), terrain_depth - 2)
	var x1 := x0 + 1
	var z1 := z0 + 1
	var fx: float = g.x - float(x0)
	var fz: float = g.y - float(z0)

	# Bilinear interpolation of the flow vectors
	var f00: Vector2 = flow_field[x0][z0]
	var f10: Vector2 = flow_field[x1][z0]
	var f01: Vector2 = flow_field[x0][z1]
	var f11: Vector2 = flow_field[x1][z1]

	var flow := f00 * (1.0 - fx) * (1.0 - fz) \
			  + f10 * fx * (1.0 - fz) \
			  + f01 * (1.0 - fx) * fz \
			  + f11 * fx * fz

	return flow.normalized() if flow.length_squared() > 0.0001 else Vector2.ZERO


## Returns the interpolated distance to the nearest road at a world-space
## (wx, wz) position. 0.0 means on the road. Units are in grid cells.
## Returns INF if the flow field has not been built.
func get_path_distance(wx: float, wz: float) -> float:
	if path_distance.size() == 0:
		return INF

	var g := _world_to_grid(wx, wz)
	var x0 := mini(int(g.x), terrain_width - 2)
	var z0 := mini(int(g.y), terrain_depth - 2)
	var x1 := x0 + 1
	var z1 := z0 + 1
	var fx: float = g.x - float(x0)
	var fz: float = g.y - float(z0)

	var d00: float = path_distance[x0][z0]
	var d10: float = path_distance[x1][z0]
	var d01: float = path_distance[x0][z1]
	var d11: float = path_distance[x1][z1]

	return d00 * (1.0 - fx) * (1.0 - fz) \
		 + d10 * fx * (1.0 - fz) \
		 + d01 * (1.0 - fx) * fz \
		 + d11 * fx * fz


## Returns true if the world-space (wx, wz) position is on or very near a road.
## Uses a small threshold (0.5 grid cells) to account for interpolation.
func is_on_road(wx: float, wz: float) -> bool:
	return get_path_distance(wx, wz) < 0.5


## Locally patches the flow field around a placed obstacle using proper
## invalidation + re-propagation so the "shadow" behind the obstacle is
## correctly rerouted rather than left pointing into a wall.
func deflect_obstacle(world_x: float, world_z: float, inner_radius: float, _outer_radius: float) -> void:
	if flow_field.size() == 0:
		return

	var all_dirs := [
		Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1),
		Vector2i(-1, -1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(1, 1),
	]

	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5
	var g := _world_to_grid(world_x, world_z)
	var cx := int(round(g.x))
	var cz := int(round(g.y))
	var grid_r := int(ceil(inner_radius / cell_size)) + 1

	# ---- Step 1: Place obstacle, collect immediate dependents ----
	var invalidation_queue: Array[Vector2i] = []
	var in_queue: Dictionary = {}

	for dx in range(-grid_r, grid_r + 1):
		for dz in range(-grid_r, grid_r + 1):
			var gx := cx + dx
			var gz := cz + dz
			if not _in_bounds(Vector2i(gx, gz)):
				continue
			var cell_wx: float = gx * cell_size - half_w
			var cell_wz: float = gz * cell_size - half_d
			var dist: float = Vector2(cell_wx - world_x, cell_wz - world_z).length()
			if dist > inner_radius:
				continue
			# Road cells are immovable anchors — never block them
			if path_distance[gx][gz] == 0.0:
				continue

			_walkable[gx][gz] = false
			flow_field[gx][gz] = Vector2.ZERO
			path_distance[gx][gz] = INF

			# Any walkable neighbour whose flow was pointing INTO this cell
			# now has a broken path — it needs re-evaluation.
			for dir in all_dirs:
				var nb := Vector2i(gx + dir.x, gz + dir.y)
				if not _in_bounds(nb) or not _walkable[nb.x][nb.y]:
					continue
				var expected := Vector2(float(gx - nb.x), float(gz - nb.y)).normalized()
				if flow_field[nb.x][nb.y].dot(expected) > 0.9 and not in_queue.has(nb):
					invalidation_queue.append(nb)
					in_queue[nb] = true

	# ---- Step 2: Ripple invalidation through the shadow ----
	var broken_cells: Array[Vector2i] = []
	var qi := 0
	while qi < invalidation_queue.size():
		var cell: Vector2i = invalidation_queue[qi]
		qi += 1

		# Skip if already invalidated (obstacle cell) or a road anchor
		if not _walkable[cell.x][cell.y] or path_distance[cell.x][cell.y] == 0.0:
			continue

		path_distance[cell.x][cell.y] = INF
		flow_field[cell.x][cell.y] = Vector2.ZERO
		broken_cells.append(cell)

		for dir in all_dirs:
			var nb := Vector2i(cell.x + dir.x, cell.y + dir.y)
			if not _in_bounds(nb) or not _walkable[nb.x][nb.y]:
				continue
			if path_distance[nb.x][nb.y] == 0.0:
				continue  # Road anchor — never invalidate
			var expected := Vector2(float(cell.x - nb.x), float(cell.y - nb.y)).normalized()
			if flow_field[nb.x][nb.y].dot(expected) > 0.9 and not in_queue.has(nb):
				invalidation_queue.append(nb)
				in_queue[nb] = true

	# ---- Step 3: Re-propagate from the valid perimeter ----
	# Use a plain array as a BFS queue (costs are 1 or sqrt(2) — consistent
	# ordering from the perimeter is enough to get correct distances).
	var prop_queue: Array[Vector2i] = []
	var prop_in_queue: Dictionary = {}

	for cell in broken_cells:
		for dir in all_dirs:
			var nb := Vector2i(cell.x + dir.x, cell.y + dir.y)
			if not _in_bounds(nb) or not _walkable[nb.x][nb.y]:
				continue
			if path_distance[nb.x][nb.y] == INF:
				continue  # Still broken — not a valid seed
			if not prop_in_queue.has(nb):
				prop_queue.append(nb)
				prop_in_queue[nb] = true

	var pi := 0
	while pi < prop_queue.size():
		var cell: Vector2i = prop_queue[pi]
		pi += 1
		var current_dist: float = path_distance[cell.x][cell.y]

		for dir in all_dirs:
			var nb := Vector2i(cell.x + dir.x, cell.y + dir.y)
			if not _in_bounds(nb) or not _walkable[nb.x][nb.y]:
				continue
			var step: float = 1.0 if (dir.x == 0 or dir.y == 0) else 1.41421356
			var new_dist: float = current_dist + step
			if new_dist < path_distance[nb.x][nb.y]:
				path_distance[nb.x][nb.y] = new_dist
				flow_field[nb.x][nb.y] = Vector2(float(cell.x - nb.x), float(cell.y - nb.y)).normalized()
				if not prop_in_queue.has(nb):
					prop_queue.append(nb)
					prop_in_queue[nb] = true

	flow_field_changed.emit()


## Returns the world-space position of the road goal (Vector3, Y = terrain height).
func get_goal_world_position() -> Vector3:
	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5
	return _grid_to_world(road_goal, half_w, half_d)


## Returns an array of world-space Vector3 positions for each road start point.
func get_start_world_positions() -> Array:
	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5
	var positions: Array = []
	for start in road_starts:
		if _in_bounds(start):
			positions.append(_grid_to_world(start, half_w, half_d))
	return positions


# ---------------------------------------------------------------------------
# Mesh construction
# ---------------------------------------------------------------------------

## Build an ArrayMesh from the height map.  Each grid cell becomes two
## triangles.  We also compute per-vertex normals so lighting looks correct.
## Per-vertex colors are assigned based on _road_blend.
func _create_terrain_mesh(map: Array) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# Half-extents so the terrain is centred on its local origin
	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5

	# --- Vertices, UVs, Colors ---
	for x in range(terrain_width):
		for z in range(terrain_depth):
			var wx: float = x * cell_size - half_w
			var wz: float = z * cell_size - half_d
			var wy: float = map[x][z]
			vertices.append(Vector3(wx, wy, wz))
			uvs.append(Vector2(float(x) / (terrain_width - 1), float(z) / (terrain_depth - 1)))

			# Vertex color: blend between terrain and road color
			var blend: float = _road_blend[x][z] if _road_blend.size() > x and _road_blend[x].size() > z else 0.0
			colors.append(terrain_color.lerp(road_color, blend))

	# --- Indices (two triangles per cell) ---
	for x in range(terrain_width - 1):
		for z in range(terrain_depth - 1):
			var i00: int = x * terrain_depth + z
			var i10: int = (x + 1) * terrain_depth + z
			var i01: int = x * terrain_depth + (z + 1)
			var i11: int = (x + 1) * terrain_depth + (z + 1)

			# Triangle 1
			indices.append(i00)
			indices.append(i10)
			indices.append(i01)

			# Triangle 2
			indices.append(i10)
			indices.append(i11)
			indices.append(i01)

	# --- Smooth normals (average of adjacent face normals) ---
	normals.resize(vertices.size())
	for i in range(normals.size()):
		normals[i] = Vector3.ZERO

	for i in range(0, indices.size(), 3):
		var a: int = indices[i]
		var b: int = indices[i + 1]
		var c: int = indices[i + 2]
		var face_normal: Vector3 = (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
		normals[a] += face_normal
		normals[b] += face_normal
		normals[c] += face_normal

	for i in range(normals.size()):
		normals[i] = normals[i].normalized()

	# --- Assemble mesh ---
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return array_mesh


## Returns the interpolated terrain height at a world-space (wx, wz) position.
## Performs triangle-aware interpolation matching the mesh triangles.
func get_height_at(wx: float, wz: float) -> float:
	if height_map.size() == 0:
		return 0.0

	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5

	# Convert world coords to continuous grid coords
	var gx: float = (wx + half_w) / cell_size
	var gz: float = (wz + half_d) / cell_size

	# Clamp to valid grid range
	gx = clampf(gx, 0.0, float(terrain_width - 1))
	gz = clampf(gz, 0.0, float(terrain_depth - 1))

	var x0 := mini(int(gx), terrain_width - 2)
	var z0 := mini(int(gz), terrain_depth - 2)
	
	var fx: float = gx - float(x0)
	var fz: float = gz - float(z0)

	var h00: float = height_map[x0][z0]
	var h10: float = height_map[x0 + 1][z0]
	var h01: float = height_map[x0][z0 + 1]
	var h11: float = height_map[x0 + 1][z0 + 1]

	# Barycentric interpolation matching the triangle split in _create_terrain_mesh
	# Triangle 1: (0,0), (1,0), (0,1) -> fx + fz < 1
	# Triangle 2: (1,0), (1,1), (0,1) -> fx + fz >= 1
	if fx + fz < 1.0:
		return h00 + fx * (h10 - h00) + fz * (h01 - h00)
	else:
		return h11 + (1.0 - fx) * (h01 - h11) + (1.0 - fz) * (h10 - h11)


## Returns the interpolated road blend factor at a world-space (wx, wz) position.
func get_road_blend_at(wx: float, wz: float) -> float:
	if _road_blend.size() == 0:
		return 0.0

	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5

	var gx: float = (wx + half_w) / cell_size
	var gz: float = (wz + half_d) / cell_size

	gx = clampf(gx, 0.0, float(terrain_width - 1))
	gz = clampf(gz, 0.0, float(terrain_depth - 1))

	var x0 := mini(int(gx), terrain_width - 2)
	var z0 := mini(int(gz), terrain_depth - 2)
	var x1 := x0 + 1
	var z1 := z0 + 1

	var fx: float = gx - float(x0)
	var fz: float = gz - float(z0)

	var b00: float = _road_blend[x0][z0]
	var b10: float = _road_blend[x1][z0]
	var b01: float = _road_blend[x0][z1]
	var b11: float = _road_blend[x1][z1]

	# Bilinear interpolation is fine for road blend
	return b00 * (1.0 - fx) * (1.0 - fz) \
		 + b10 * fx * (1.0 - fz) \
		 + b01 * (1.0 - fx) * fz \
		 + b11 * fx * fz


func _create_terrain_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	return mat

## Define your models here (path to your .obj, .res, or .mesh files)
var tree_paths = [
	"res://assets/gltf/Pine_1.gltf",
	"res://assets/gltf/Pine_2.gltf",
	"res://assets/gltf/Pine_3.gltf",
	"res://assets/gltf/Pine_4.gltf",
	"res://assets/gltf/Pine_5.gltf"
]

func _setup_foliage_programmatically() -> void:
	foliage_types.clear()
	
	for path in tree_paths:
		# 1. Create a new instance of your custom resource
		var new_type = FoliageType.new()
		
		# 2. Load the mesh from your project folder
		var loaded_mesh = load(path)
		
		if loaded_mesh is Mesh:
			new_type.mesh = loaded_mesh
		elif loaded_mesh is PackedScene:
			# If you pointed to a .glb/.tscn, we need to extract the mesh
			new_type.mesh = _extract_mesh_from_scene(loaded_mesh)
		
		new_type.spawn_weight = 1.0 # Or set logic based on name
		
		# 3. Add it to the array
		foliage_types.append(new_type)
	
	_queue_rebuild()
