extends Area3D

## Damage dealt on hit.
var damage: float = 25.0
## Arrow travel speed in world units per second — used to derive flight duration from distance.
var speed: float = 100.0
## Target enemy — read once in setup() to snapshot destination.
var target: Node3D = null
## Total flight time in seconds — derived from distance / speed in setup().
var _duration: float = 0.6
## Elapsed time along the Bézier curve.
var _elapsed: float = 0.0

## Cubic Bézier control points, calculated once at spawn.
var _p0: Vector3
var _p1: Vector3
var _p2: Vector3
var _p3: Vector3


func _ready() -> void:
	collision_layer = 0
	collision_mask = 0  # no collision detection needed
	_build_mesh()


func _build_mesh() -> void:
	# Thin cylinder oriented along Z to represent an arrow shaft.
	var mesh_instance := MeshInstance3D.new()
	var cylinder_mesh := CylinderMesh.new()
	cylinder_mesh.height = 0.5
	cylinder_mesh.top_radius = 0.05
	cylinder_mesh.bottom_radius = 0.05
	mesh_instance.mesh = cylinder_mesh
	mesh_instance.rotation.x = PI / 2.0
	add_child(mesh_instance)


## Call after add_child + global_position are set — snapshots target and calculates the flight curve.
func setup() -> void:
	assert(target != null, "Arrow must have a target set before setup()")
	_p0 = global_position
	_p3 = target.global_position
	_duration = _p0.distance_to(_p3) / speed

	var arc_height := _p0.distance_to(_p3) * 0.3
	_p1 = _p0 + Vector3(0.0, arc_height, 0.0) + (_p3 - _p0) * 0.25
	_p2 = _p3 + Vector3(0.0, arc_height * 0.5, 0.0) - (_p3 - _p0) * 0.15


func _physics_process(delta: float) -> void:
	_elapsed += delta
	var t := clampf(_elapsed / _duration, 0.0, 1.0)

	var next_pos := _bezier(t, _p0, _p1, _p2, _p3)

	# Orient along direction of travel.
	var travel_dir := next_pos - global_position
	if travel_dir.length() > 0.001:
		global_transform.basis = Basis.looking_at(-travel_dir.normalized(), Vector3.UP)

	global_position = next_pos

	if t >= 1.0:
		# Apply damage only if the target is still alive.
		if is_instance_valid(target) and target.has_method("apply_dmg"):
			target.apply_dmg(damage)
		queue_free()


func _bezier(t: float, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> Vector3:
	# Standard cubic Bézier evaluation.
	var u := 1.0 - t
	return u*u*u * p0 + 3.0*u*u*t * p1 + 3.0*u*t*t * p2 + t*t*t * p3
