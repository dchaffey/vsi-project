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
## Noise frequency â€” lower values produce smoother, broader hills
@export var noise_frequency: float = 0.02:
	set(v):
		noise_frequency = v
		_queue_rebuild()
## Noise seed (0 = random each game run, but fixed in-editor for stable preview)
@export var noise_seed: int = 0:
	set(v):
		noise_seed = v
		_queue_rebuild()
## Distance from center where terrain starts to fade to 0 (0.0 to 1.0)
@export var edge_falloff_start: float = 0.6:
	set(v):
		edge_falloff_start = v
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
## Steepness cost exponent â€” higher values penalise slopes more aggressively
@export var steepness_exponent: float = 10.0:
	set(v):
		steepness_exponent = v
		_queue_rebuild()
## Color for road surfaces
@export var road_color: Color = Color(0.3, 0.2, 0.1):
	set(v):
		road_color = v
		_queue_rebuild()
## Color for non-road terrain
@export var terrain_color: Color = Color(0.15, 0.3, 0.1):
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

var height_map: Array = [] # 2D array [x][z] of floats
var _is_ready := false
# Per-vertex road blend factor [x][z] in [0, 1]. 1 = full road, 0 = terrain.
var _road_blend: Array = []
var _rebuild_queued := false

## World-space waypoint arrays for each road path, populated during _rebuild().
## Used by enemies for waypoint-following navigation.
var _road_paths_world: Array = []  # Array of Array[Vector3]

var foliage_types: Array[FoliageType] = []
var _foliage_prob_ranges: Array = []  # Array of [start, end] ranges for each foliage type


func _ready() -> void:
	_is_ready = true
	input_ray_pickable = false  # terrain does not handle mouse events; buildings only
	_setup_foliage_programmatically()
	_rebuild()


func _process(_delta: float) -> void:
	if _rebuild_queued:
		_rebuild_queued = false
		_rebuild()


## Queue a rebuild for the next frame. Coalesces multiple property changes
## that happen during scene load / inspector edits into a single rebuild.
func _queue_rebuild() -> void:
	if not _is_ready and not Engine.is_editor_hint():
		return
	_rebuild_queued = true


## Regenerates the height map, mesh, and collision shape.
## Updates the existing MeshInstance3D and CollisionShape3D children that live
## in the .tscn â€” no add_child() needed, so the editor viewport sees the mesh.
func _rebuild() -> void:
	if not _is_ready and not Engine.is_editor_hint():
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

	# --- Store paths as world-space waypoints for enemy navigation ---
	_road_paths_world = []
	var _half_w: float = (terrain_width - 1) * cell_size * 0.5
	var _half_d: float = (terrain_depth - 1) * cell_size * 0.5
	for path in paths:
		var world_path: Array = []
		for grid_pt: Vector2i in path:
			world_path.append(_grid_to_world(grid_pt, _half_w, _half_d))
		_road_paths_world.append(world_path)

	var array_mesh := _create_terrain_mesh(height_map)
	if not array_mesh:
		print("Terrain: Mesh generation failed.")
		return

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
	# Clean up all MultiMeshInstance3D children â€” catches both runtime-created
	# nodes (in _terrain_foliage group) and stale baked nodes from the scene file.
	for child in get_children():
		if child is MultiMeshInstance3D:
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

	# Compute actual min/max heights from the height map for proper normalization
	var actual_min_h := INF
	var actual_max_h := -INF
	for row in height_map:
		for h in row:
			if h < actual_min_h:
				actual_min_h = h
			if h > actual_max_h:
				actual_max_h = h
	var actual_range := actual_max_h - actual_min_h

	# Generate random positions
	var total_cells = (terrain_width - 1) * (terrain_depth - 1)
	var max_attempts = int(total_cells * foliage_density * 0.4)

	# Margin in grid cells â€” keeps foliage inside the walls
	var margin = 2.0
	# Path exclusion radius in grid cells â€” keeps foliage off enemy walkways
	var path_clearance: float = 1.5

	for attempt in range(max_attempts):
		var x = rng.randf_range(margin, float(terrain_width - 1) - margin)
		var z = rng.randf_range(margin, float(terrain_depth - 1) - margin)

		var wx = x * cell_size - half_w
		var wz = z * cell_size - half_d

		# Skip if on or near a road (blend) or enemy path (waypoints)
		if get_road_blend_at(wx, wz) > 0.05:
			continue
		if _is_near_path(wx, wz, path_clearance * cell_size):
			continue
		
		var height = get_height_at(wx, wz)
		
		# Check rockiness
		var rockiness = get_rockiness_at(wx, wz)
		var is_rocky_position = rockiness < 0.3

		# Bell curve centered at 1/4 max height: peak density at foothills, sparse at peaks
		var normalized_height = (height - actual_min_h) / actual_range
		var distance_from_peak = abs(normalized_height - 0.25)
		var elevation_prob = pow(1.0 - distance_from_peak, 4.0)
		elevation_prob = clampf(elevation_prob, 0.0, 1.0)

		if rng.randf() > elevation_prob:
			continue

		# Choose foliage type by checking which probability range the roll falls into
		var roll = rng.randf()
		var chosen_type_idx = 0
		var is_rock_type = false
		
		for i in range(_foliage_prob_ranges.size()):
			var range_pair = _foliage_prob_ranges[i]
			if roll >= range_pair[0] and roll < range_pair[1]:
				chosen_type_idx = i
				# Check if this is a rock type (indices 9, 10, 11)
				is_rock_type = (i >= 9 and i <= 11)
				break
		
		# If position is rocky and chosen type is not a rock, skip this position
		if is_rocky_position and not is_rock_type:
			#print("Skipping tree on rocky terrain: rockiness = ", rockiness)
			continue

		# Build basis (rotation + scale) separately, then set origin
		var tree_scale = rng.randf_range(tree_scale_min, tree_scale_max)
		var rotation_basis = Basis(Vector3.UP, rng.randf_range(0, TAU))
		rotation_basis = rotation_basis.scaled(Vector3(tree_scale, tree_scale, tree_scale))
		var t = Transform3D(rotation_basis, Vector3(wx, height, wz))

		instances_per_type[chosen_type_idx].append(t)

	# Create MultiMeshInstances
	for i in range(foliage_types.size()):
		var type = foliage_types[i]
		var transforms = instances_per_type[i]

		if transforms.size() == 0 or type.mesh == null:
			continue

		var multimesh = MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = type.mesh
		multimesh.instance_count = transforms.size()

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
	
	# Use a local fallback for the edge falloff start to prevent Nil errors during tool initialization
	var falloff_start: float = edge_falloff_start if typeof(edge_falloff_start) == TYPE_FLOAT else 0.6
	
	for x in range(terrain_width):
		var row: Array = []
		for z in range(terrain_depth):
			# FastNoiseLite returns values in [-1, 1]; remap to [0, max_height]
			var n: float = noise.get_noise_2d(float(x), float(z))
			var h: float = pow(((n + 1.0) * 0.5 * max_height), 1.5)
			
			# Edge Falloff Map:
			# Calculate normalized coordinates in range [-1.0, 1.0] where (0,0) is center
			# Safety: avoid division by zero if width/depth is 1
			var den_x = float(terrain_width - 1) if terrain_width > 1 else 1.0
			var den_z = float(terrain_depth - 1) if terrain_depth > 1 else 1.0
			var nx = (x / den_x) * 2.0 - 1.0
			var nz = (z / den_z) * 2.0 - 1.0
			
			# Rounded rectangle falloff distance to prevent sharp diagonal ridges
			# Normalize the distance in the falloff zone to [0.0, 1.0]
			var fade_width = max(1.0 - falloff_start, 0.001)
			var dx = max(abs(nx) - falloff_start, 0.0) / fade_width
			var dz = max(abs(nz) - falloff_start, 0.0) / fade_width
			
			# Euclidean distance in the corner zones gives a rounded shape
			var d = sqrt(dx * dx + dz * dz)
			
			# Falloff: 1.0 at center, smoothly fades to 0.0 across the fade zone
			var falloff = 1.0 - smoothstep(0.0, 1.0, d)
			h *= falloff
			
			row.append(h)
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
		
	if map.size() < terrain_width or map[0].size() < terrain_depth:
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
# Road stamping â€” flatten terrain along paths with Gaussian falloff
# ---------------------------------------------------------------------------

## Stamps all road paths into the height map and populates _road_blend.
## The road follows the terrain's general elevation but is locally smoothed
## and flattened. Gaussian falloff blends road edges into the surrounding terrain.
func _stamp_roads(map: Array, paths: Array) -> void:
	var half_width: float = road_width * 0.5
	# Sigma for Gaussian falloff â€” controls how quickly the road blends out
	var sigma: float = road_width * 0.35
	var two_sigma_sq: float = 2.0 * sigma * sigma
	# Influence radius â€” extend a bit beyond half_width for the blend region
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
					# Core of the road â€” fully flat
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
			var lo : int = maxi(0, int(i - window / 2.0))
			var hi := mini(smoothed.size() - 1, int(i + window / 2.0))
			var sum := 0.0
			for j in range(lo, hi + 1):
				sum += prev[j]
			smoothed[i] = sum / float(hi - lo + 1)

	return smoothed

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


## Returns the world-space waypoint arrays for all computed road paths.
## Each element is an Array[Vector3]. Used by enemy_spawn to assign paths to enemies.
func get_road_paths_world() -> Array:
	return _road_paths_world


## Runs A* from `from_world` back to the nearest point on path `path_idx`.
## Returns a world-space Array[Vector3] for the enemy to follow as a rejoin path.
func find_rejoin_path(from_world: Vector3, path_idx: int) -> Array:
	if path_idx < 0 or path_idx >= _road_paths_world.size():
		return []
	if _road_paths_world[path_idx].size() == 0:
		return []

	var half_w := (terrain_width - 1) * cell_size * 0.5
	var half_d := (terrain_depth - 1) * cell_size * 0.5

	# Convert from_world to the nearest grid cell
	var gx := clampi(int(round((from_world.x + half_w) / cell_size)), 0, terrain_width - 1)
	var gz := clampi(int(round((from_world.z + half_d) / cell_size)), 0, terrain_depth - 1)
	var start_grid := Vector2i(gx, gz)

	# Find the nearest waypoint on the assigned path (absolute nearest in world space)
	var best_dist_sq := INF
	var best_goal := road_goal
	for wp: Vector3 in _road_paths_world[path_idx]:
		var dx := wp.x - from_world.x
		var dz := wp.z - from_world.z
		var dsq := dx * dx + dz * dz
		if dsq < best_dist_sq:
			best_dist_sq = dsq
			var wgx := clampi(int(round((wp.x + half_w) / cell_size)), 0, terrain_width - 1)
			var wgz := clampi(int(round((wp.z + half_d) / cell_size)), 0, terrain_depth - 1)
			best_goal = Vector2i(wgx, wgz)

	var grid_path := _find_path(start_grid, best_goal, height_map)
	var world_path: Array = []
	for gpt: Vector2i in grid_path:
		world_path.append(_grid_to_world(gpt, half_w, half_d))
	return world_path


## Public helper for tower placement — returns true if (wx, wz) is within
## `clearance_world` world units of any enemy path waypoint.
func is_near_enemy_path(wx: float, wz: float, clearance_world: float) -> bool:
	return _is_near_path(wx, wz, clearance_world)


func _is_near_path(wx: float, wz: float, clearance_world: float) -> bool:
	var csq := clearance_world * clearance_world
	for path in _road_paths_world:
		for pt: Vector3 in path:
			var dx := wx - pt.x
			var dz := wz - pt.z
			if dx * dx + dz * dz < csq:
				return true
	return false


# ---------------------------------------------------------------------------
# Mesh construction
# ---------------------------------------------------------------------------

## Build an ArrayMesh from the height map. This implementation uses "un-welded" vertices,
## meaning every triangle gets its own 3 unique vertices. This allows us to bake
## faceted normals and static vertex colors for a perfect, performant low-poly look.
func _create_terrain_mesh(map: Array) -> ArrayMesh:
	if map.size() < terrain_width or map[0].size() < terrain_depth:
		return null
		
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var indices := PackedInt32Array()

	# Half-extents so the terrain is centred on its local origin
	var half_w: float = (terrain_width - 1) * cell_size * 0.5
	var half_d: float = (terrain_depth - 1) * cell_size * 0.5

	# Aesthetic Palette (Linked to exported properties)
	var color_sand  := Color(0.35, 0.3, 0.15)
	var color_grass := terrain_color
	var color_rock  := Color(0.25, 0.25, 0.25)
	var color_road  := road_color

	# --- First pass: collect triangle data and calculate steepness ---
	var triangle_data := []  # Array of dictionaries with triangle info
	var max_steepness: float = 0.0
	
	for x in range(terrain_width - 1):
		for z in range(terrain_depth - 1):
			# Get the 4 grid world positions for this cell
			var p00 := Vector3(x * cell_size - half_w, map[x][z], z * cell_size - half_d)
			var p10 := Vector3((x + 1) * cell_size - half_w, map[x + 1][z], z * cell_size - half_d)
			var p01 := Vector3(x * cell_size - half_w, map[x][z + 1], (z + 1) * cell_size - half_d)
			var p11 := Vector3((x + 1) * cell_size - half_w, map[x + 1][z + 1], (z + 1) * cell_size - half_d)
			
			# Get road blend factors
			var b00: float = _road_blend[x][z]
			var b10: float = _road_blend[x + 1][z]
			var b01: float = _road_blend[x][z + 1]
			var b11: float = _road_blend[x + 1][z + 1]
			
			# Normalize UVs [0.0, 1.0]
			var uv00 := Vector2(float(x) / (terrain_width - 1), float(z) / (terrain_depth - 1))
			var uv10 := Vector2(float(x + 1) / (terrain_width - 1), float(z) / (terrain_depth - 1))
			var uv01 := Vector2(float(x) / (terrain_width - 1), float(z + 1) / (terrain_depth - 1))
			var uv11 := Vector2(float(x + 1) / (terrain_width - 1), float(z + 1) / (terrain_depth - 1))

			# Triangle 1: (00, 10, 01)
			var tri1_normal: Vector3 = (p01 - p00).cross(p10 - p00).normalized()
			# Ensure normal points upward for terrain
			if tri1_normal.y < 0:
				tri1_normal = -tri1_normal
			var tri1_steepness: float = 1.0 - tri1_normal.y  # 0=flat, 1=vertical
			max_steepness = max(max_steepness, tri1_steepness)
			
			triangle_data.append({
				"points": [p00, p10, p01],
				"blends": [b00, b10, b01],
				"uvs": [uv00, uv10, uv01],
				"normal": tri1_normal,
				"steepness": tri1_steepness,
				"avg_height": (p00.y + p10.y + p01.y) / 3.0
			})
				
			# Triangle 2: (10, 11, 01)
			var tri2_normal: Vector3 = (p01 - p10).cross(p11 - p10).normalized()
			# Ensure normal points upward for terrain
			if tri2_normal.y < 0:
				tri2_normal = -tri2_normal
			var tri2_steepness: float = 1.0 - tri2_normal.y  # 0=flat, 1=vertical
			max_steepness = max(max_steepness, tri2_steepness)
			
			triangle_data.append({
				"points": [p10, p11, p01],
				"blends": [b10, b11, b01],
				"uvs": [uv10, uv11, uv01],
				"normal": tri2_normal,
				"steepness": tri2_steepness,
				"avg_height": (p10.y + p11.y + p01.y) / 3.0
			})
	
	# --- Second pass: generate vertices with relative steepness coloring ---
	for i in range(triangle_data.size()):
		var tri = triangle_data[i]
		_add_faceted_triangle_with_steepness(vertices, normals, uvs, colors, indices,
			tri["points"], tri["blends"], tri["uvs"], tri["normal"], tri["steepness"], tri["avg_height"],
			color_sand, color_grass, color_rock, color_road, max_steepness)

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


## Helper to add a single triangle with baked faceted normals and colors.
func _add_faceted_triangle(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idxs: PackedInt32Array, pts: Array, blends: Array, uv_pts: Array, c_sand: Color, c_grass: Color, c_rock: Color, c_road: Color) -> void:
	var p0: Vector3 = pts[0]
	var p1: Vector3 = pts[1]
	var p2: Vector3 = pts[2]
	
	# 1. Calculate Face Normal - Corrected winding order to ensure normals point UP
	# (p2 - p0) cross (p1 - p0) gives an upward normal for CCW winding
	var normal: Vector3 = (pts[2] - p0).cross(pts[1] - p0).normalized()
	
	# 2. Average attributes for the entire face to ensure solid coloring
	var avg_h: float = (p0.y + p1.y + p2.y) / 3.0
	var avg_b: float = (float(blends[0]) + float(blends[1]) + float(blends[2])) / 3.0
	
	# 3. Altitude Mapping (Sand -> Grass transition)
	# Use max_height to ensure the transition scales with the terrain size
	var h_limit: float = max(max_height, 1.0)
	var h_factor: float = clamp(avg_h / h_limit, 0.0, 1.0)
	# Transition from sand to grass in the bottom 20% of the height range
	var base_col: Color = c_sand.lerp(c_grass, smoothstep(0.05, 0.2, h_factor))
	
	# 4. Slope Rockiness (Dynamic Threshold)
	# Peaks become rocky even on shallower slopes.
	var rock_threshold: float = lerp(0.7, 0.85, h_factor)
	var rock_mask: float = smoothstep(rock_threshold - 0.05, rock_threshold + 0.05, normal.y)
	var final_col: Color = c_rock.lerp(base_col, rock_mask)
	
	# 5. Bake Road/Path blend
	final_col = final_col.lerp(c_road, avg_b)
	
	# 6. Slope-Based Darkening (Final Pass)
	# normal.y is 1.0 for flat, 0.0 for vertical.
	var steepness_factor: float = clamp(normal.y, 0.0, 1.0)
	
	# We use a high power (6.0) so that even slight deviations from "flat"
	# cause visible darkening. This is key for the low-poly look on smooth noise.
	var darken_amount: float = pow(steepness_factor, 20.0)
	
	# Remap the darkening so it doesn't go all the way to black (stays in 0.3 to 1.0 range)
	var final_darken: float = lerp(0.3, 1.0, darken_amount)
	
	# Apply shading to the final color
	final_col = final_col * final_darken
	
	# 7. Add 3 unique vertices
	var start_idx := verts.size()
	for i in range(3):
		verts.append(pts[i])
		norms.append(normal)
		uvs.append(uv_pts[i])
		cols.append(final_col)
		idxs.append(start_idx + i)


## Helper to add a single triangle with relative steepness-based coloring.
## steepness: 0=flat, 1=vertical (calculated as 1 - normal.y)
## max_steepness: maximum steepness value across all triangles
func _add_faceted_triangle_with_steepness(verts: PackedVector3Array, norms: PackedVector3Array, uvs: PackedVector2Array, cols: PackedColorArray, idxs: PackedInt32Array, pts: Array, blends: Array, uv_pts: Array, normal: Vector3, steepness: float, avg_h: float, c_sand: Color, c_grass: Color, c_rock: Color, c_road: Color, max_steepness: float) -> void:
	# Ensure normal points upward (should already be done, but double-check)
	if normal.y < 0:
		normal = -normal
	
	# 1. Calculate relative steepness (0 to 1, where 1 is the steepest triangle)
	var relative_steepness: float = steepness / max_steepness if max_steepness > 0.0 else 0.0
	
	# 2. Altitude Mapping (Sand -> Grass transition)
	var h_limit: float = max(max_height, 1.0)
	var h_factor: float = clamp(avg_h / h_limit, 0.0, 1.0)
	# Transition from sand to grass in the bottom 20% of the height range
	var base_col: Color = c_sand.lerp(c_grass, smoothstep(0.05, 0.2, h_factor))
	
	# 3. Slope Rockiness (Dynamic Threshold)
	var rock_threshold: float = lerp(0.7, 0.85, h_factor)
	var rock_mask: float = smoothstep(rock_threshold - 0.05, rock_threshold + 0.05, normal.y)
	var final_col: Color = c_rock.lerp(base_col, rock_mask)
	
	# 4. Bake Road/Path blend (matches original order)
	var avg_b: float = (float(blends[0]) + float(blends[1]) + float(blends[2])) / 3.0
	final_col = final_col.lerp(c_road, avg_b)
	
	# 5. Apply steepness-based coloring (AFTER road blend, matches original)
	# For rocky terrain (rock_mask close to 0): darken based on steepness
	# For grassy terrain (rock_mask close to 1): lighten based on steepness
	# Note: rock_mask = 0.0 means fully rocky, rock_mask = 1.0 means fully grassy
	
	if rock_mask < 0.5:  # More rocky than grassy
		# Rocky terrain: steep parts darker
		# Start with original rocky color (c_rock = Color(0.25, 0.25, 0.25))
		# Darken it based on steepness: multiply by (1.0 - relative_steepness)
		var rocky_darken_factor: float = 1.0 - relative_steepness  # 1.0 for flat, 0.0 for steepest
		# Ensure minimum brightness so it doesn't go completely black (except for steepest)
		rocky_darken_factor = max(rocky_darken_factor, 0.3)  # Keep at least 30% brightness
		final_col = final_col * rocky_darken_factor
	else:  # More grassy than rocky
		# Grassy terrain: steep parts lighter
		var grassy_steepness_factor: float = 0.3 + 0.7 * relative_steepness  # 0.3 for flat, 1.0 for steepest
		final_col = final_col * grassy_steepness_factor
	
	# 6. Add 3 unique vertices
	var start_idx := verts.size()
	for i in range(3):
		verts.append(pts[i])
		norms.append(normal)
		uvs.append(uv_pts[i])
		cols.append(final_col)
		idxs.append(start_idx + i)


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


## Returns the rockiness factor at a world-space (wx, wz) position.
## Returns 0.0 for full rock, 1.0 for full grass, matching the visual coloring.
func get_rockiness_at(wx: float, wz: float) -> float:
	if height_map.size() == 0:
		return 1.0  # Default to grass if no terrain

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

	# Get heights for the 4 grid corners
	var h00: float = height_map[x0][z0]
	var h10: float = height_map[x0 + 1][z0]
	var h01: float = height_map[x0][z0 + 1]
	var h11: float = height_map[x0 + 1][z0 + 1]

	# Determine which triangle we're in (same logic as get_height_at)
	if fx + fz < 1.0:
		# Triangle 1: (00, 10, 01)
		var p00 := Vector3(0.0, h00, 0.0)
		var p10 := Vector3(cell_size, h10, 0.0)
		var p01 := Vector3(0.0, h01, cell_size)
		
		# Calculate face normal (corrected winding order for CCW)
		var normal: Vector3 = (p01 - p00).cross(p10 - p00).normalized()
		
		# Average height for the triangle
		var avg_h: float = (h00 + h10 + h01) / 3.0
		
		# Apply rockiness formula (same as _add_faceted_triangle)
		var h_limit: float = max(max_height, 1.0)
		var h_factor: float = clamp(avg_h / h_limit, 0.0, 1.0)
		var rock_threshold: float = lerp(0.7, 0.85, h_factor)
		var rock_mask: float = smoothstep(rock_threshold - 0.05, rock_threshold + 0.05, normal.y)
		
		return rock_mask
	else:
		# Triangle 2: (10, 11, 01)
		var p10 := Vector3(cell_size, h10, 0.0)
		var p11 := Vector3(cell_size, h11, cell_size)
		var p01 := Vector3(0.0, h01, cell_size)
		
		# Calculate face normal (corrected winding order for CCW)
		var normal: Vector3 = (p01 - p10).cross(p11 - p10).normalized()
		
		# Average height for the triangle
		var avg_h: float = (h10 + h11 + h01) / 3.0
		
		# Apply rockiness formula (same as _add_faceted_triangle)
		var h_limit: float = max(max_height, 1.0)
		var h_factor: float = clamp(avg_h / h_limit, 0.0, 1.0)
		var rock_threshold: float = lerp(0.7, 0.85, h_factor)
		var rock_mask: float = smoothstep(rock_threshold - 0.05, rock_threshold + 0.05, normal.y)
		
		return rock_mask


func _create_terrain_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.specular_mode = StandardMaterial3D.SPECULAR_DISABLED
	return mat
## Define your models and their spawn weights here
## Higher weight = more common spawning
var tree_paths = {
	"res://assets/gltf/Pine_1.gltf": 0.5,
	"res://assets/gltf/Pine_2.gltf": 0.5,
	"res://assets/gltf/Pine_3.gltf": 0.5,
	"res://assets/gltf/Pine_4.gltf": 0.5,
	"res://assets/gltf/Pine_5.gltf": 0.5,
	"res://assets/gltf/TwistedTree_1.gltf": 0.005,
	"res://assets/gltf/TwistedTree_2.gltf": 0.005,
	"res://assets/gltf/TwistedTree_3.gltf": 0.005,
	"res://assets/gltf/TwistedTree_4.gltf": 0.005,
	"res://assets/gltf/Rock_Medium_1.gltf": 0.1,
	"res://assets/gltf/Rock_Medium_2.gltf": 0.1,
	"res://assets/gltf/Rock_Medium_3.gltf": 0.1,
}

func _setup_foliage_programmatically() -> void:
	foliage_types.clear()
	_foliage_prob_ranges.clear()

	# Calculate sum of all weights for normalization
	var total_weight = 0.0
	for weight in tree_paths.values():
		total_weight += weight

	var cumulative = 0.0
	for path in tree_paths.keys():
		# 1. Create a new instance of your custom resource
		var new_type = FoliageType.new()

		# 2. Load the mesh from your project folder
		var loaded_mesh = load(path)

		if loaded_mesh is Mesh:
			new_type.mesh = loaded_mesh
		elif loaded_mesh is PackedScene:
			# If you pointed to a .glb/.tscn, we need to extract the mesh
			new_type.mesh = _extract_mesh_from_scene(loaded_mesh)

		# 3. Normalize weight to sum of all probabilities
		new_type.spawn_weight = tree_paths[path] / total_weight

		# 4. Store probability range [start, end]
		var range_end = cumulative + new_type.spawn_weight
		_foliage_prob_ranges.append([cumulative, range_end])
		cumulative = range_end

		# 5. Add it to the array
		foliage_types.append(new_type)
		if new_type.mesh == null:
			print("WARNING: Failed to load mesh from " + path)

	_queue_rebuild()
