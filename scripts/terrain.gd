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

var height_map: Array = [] # 2D array [x][z] of floats
var _is_ready := false
# Per-vertex road blend factor [x][z] in [0, 1]. 1 = full road, 0 = terrain.
var _road_blend: Array = []
var _rebuild_queued := false


func _ready() -> void:
	_is_ready = true
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

	print("Terrain built (%dx%d, cell %.1f, max height %.1f)." % [terrain_width, terrain_depth, cell_size, max_height])


# ---------------------------------------------------------------------------
# Start / goal indicators
# ---------------------------------------------------------------------------

## Remove old indicators and spawn fresh spheres for each start and the goal.
func _spawn_indicators() -> void:
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
			var lo := maxi(0, i - window / 2)
			var hi := mini(smoothed.size() - 1, i + window / 2)
			var sum := 0.0
			for j in range(lo, hi + 1):
				sum += prev[j]
			smoothed[i] = sum / float(hi - lo + 1)

	return smoothed


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
## Performs bilinear interpolation between the four nearest grid vertices.
## Returns 0.0 if the height map is empty or the position is out of bounds.
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
	var x1 := x0 + 1
	var z1 := z0 + 1

	var fx: float = gx - float(x0)
	var fz: float = gz - float(z0)

	# Bilinear interpolation
	var h00: float = height_map[x0][z0]
	var h10: float = height_map[x1][z0]
	var h01: float = height_map[x0][z1]
	var h11: float = height_map[x1][z1]

	var h: float = h00 * (1.0 - fx) * (1.0 - fz) \
				 + h10 * fx * (1.0 - fz) \
				 + h01 * (1.0 - fx) * fz \
				 + h11 * fx * fz
	return h


func _create_terrain_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	return mat
