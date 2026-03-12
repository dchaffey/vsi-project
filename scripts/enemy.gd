extends RigidBody3D

## Reference to the terrain node (set by the spawner).
var terrain: StaticBody3D

## Movement speed in world units per second.
var move_speed: float = 5.0
## How strongly the enemy is pulled toward the terrain surface height.
## Higher = snappier correction, lower = floatier.
var height_correction_strength: float = 10.0
## Half-size of the axis-aligned rectangle around the goal used for arrival
## detection (in world units). Cheaper than a distance check.
var goal_reach_half_size: float = 2.0

## Cached goal position (world space, XZ only).
var _goal_pos := Vector3.ZERO
## Cached start positions (world space).
var _start_positions: Array = []
## RNG for picking a random start on respawn.
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	if terrain:
		_goal_pos = terrain.get_goal_world_position()
		_start_positions = terrain.get_start_world_positions()


func _physics_process(delta: float) -> void:
	if not terrain:
		return

	var pos := global_position

	# --- Flow field movement ---
	var flow: Vector2 = terrain.get_flow_direction(pos.x, pos.z)
	if flow != Vector2.ZERO:
		var desired_vel := Vector3(flow.x, 0.0, flow.y).normalized() * move_speed
		# Blend toward desired velocity on XZ, preserving Y physics (gravity, knockback)
		var current_vel := linear_velocity
		var corrected := Vector3(
			lerpf(current_vel.x, desired_vel.x, clampf(delta * 5.0, 0.0, 1.0)),
			current_vel.y,
			lerpf(current_vel.z, desired_vel.z, clampf(delta * 5.0, 0.0, 1.0)),
		)
		linear_velocity = corrected

	# --- Height correction ---
	# Gently push Y velocity toward terrain surface so enemies don't fly off
	# or sink through after knockback.
	var target_y: float = terrain.get_height_at(pos.x, pos.z) + 1.0  # capsule half-height offset
	var y_error: float = target_y - pos.y
	# Only correct downward drift or when close to surface; let big upward
	# knockback play out naturally before correcting.
	if absf(y_error) < 5.0:
		linear_velocity.y += y_error * height_correction_strength * delta

	# --- Goal arrival check (axis-aligned rectangle on XZ plane) ---
	if absf(pos.x - _goal_pos.x) < goal_reach_half_size \
		and absf(pos.z - _goal_pos.z) < goal_reach_half_size:
		_respawn_at_start()


## Teleport the enemy back to a random road start position.
func _respawn_at_start() -> void:
	if _start_positions.size() == 0:
		return

	var start_pos: Vector3 = _start_positions[_rng.randi_range(0, _start_positions.size() - 1)]
	# Place above the surface so the enemy doesn't clip into terrain
	global_position = start_pos + Vector3(0.0, 2.0, 0.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
