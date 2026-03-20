extends RigidBody3D

enum State { NORMAL, STUNNED, RECOVERING }

## Reference to the terrain node (set by the spawner).
var terrain: StaticBody3D

## Movement speed in world units per second.
var move_speed: float = 5.0
## How strongly the enemy is pulled toward the terrain surface height.
var height_correction_strength: float = 10.0
## Half-size of the axis-aligned rectangle around the goal used for arrival
## detection (in world units).
var goal_reach_half_size: float = 2.0

## Health
var max_health: float = 100.0
var health: float = 100.0
var damage_threshold: float = 5.0
var stun_threshold: float = 20.0
var damage_per_impulse: float = 2.0

## Stun / recover timing
var stun_max_duration: float = 3.0
var stun_exit_speed: float = 2.0
var recover_duration: float = 0.3

## Internal state
var _state: State = State.NORMAL
var _stun_timer: float = 0.0
var _recover_timer: float = 0.0
var _prev_linear_velocity: Vector3 = Vector3.ZERO
var _pending_stun: bool = false

## Cached goal position (world space, XZ only).
var _goal_pos := Vector3.ZERO
## Cached start positions (world space).
var _start_positions: Array = []
## RNG for picking a random start on respawn.
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_set_axis_locks(true)
	if terrain:
		_goal_pos = terrain.get_goal_world_position()
		_start_positions = terrain.get_start_world_positions()


func _physics_process(delta: float) -> void:
	if not terrain:
		return

	if _pending_stun:
		_pending_stun = false
		_enter_stunned()

	match _state:
		State.NORMAL:
			_tick_normal(delta)
		State.STUNNED:
			_tick_stunned(delta)
		State.RECOVERING:
			_tick_recovering(delta)

	_prev_linear_velocity = linear_velocity


func _tick_normal(delta: float) -> void:
	var pos := global_position

	# --- Flow field movement ---
	var flow: Vector2 = terrain.get_flow_direction(pos.x, pos.z)
	if flow != Vector2.ZERO:
		var desired_vel := Vector3(flow.x, 0.0, flow.y).normalized() * move_speed
		var current_vel := linear_velocity
		var corrected := Vector3(
			lerpf(current_vel.x, desired_vel.x, clampf(delta * 5.0, 0.0, 1.0)),
			current_vel.y,
			lerpf(current_vel.z, desired_vel.z, clampf(delta * 5.0, 0.0, 1.0)),
		)
		linear_velocity = corrected

	# --- Height correction ---
	var target_y: float = terrain.get_height_at(pos.x, pos.z) + 1.0
	var y_error: float = target_y - pos.y
	if absf(y_error) < 5.0:
		linear_velocity.y += y_error * height_correction_strength * delta

	# --- Goal arrival check ---
	if absf(pos.x - _goal_pos.x) < goal_reach_half_size \
		and absf(pos.z - _goal_pos.z) < goal_reach_half_size:
		_respawn_at_start()


func _tick_stunned(delta: float) -> void:
	_stun_timer += delta
	if linear_velocity.length() < stun_exit_speed or _stun_timer >= stun_max_duration:
		_enter_recovering()


func _tick_recovering(delta: float) -> void:
	_recover_timer += delta
	if _recover_timer >= recover_duration:
		_enter_normal()


# -- State transitions --------------------------------------------------

func _enter_stunned() -> void:
	_state = State.STUNNED
	_stun_timer = 0.0
	_set_axis_locks(false)


func _enter_recovering() -> void:
	_state = State.RECOVERING
	_recover_timer = 0.0
	rotation = Vector3(0.0, rotation.y, 0.0)
	angular_velocity = Vector3.ZERO
	_set_axis_locks(true)


func _enter_normal() -> void:
	_state = State.NORMAL


func _set_axis_locks(locked: bool) -> void:
	axis_lock_angular_x = locked
	axis_lock_angular_z = locked


# -- Damage via physics impulse ------------------------------------------

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var gravity_contribution := state.total_gravity * state.step
	var delta_v := state.linear_velocity - _prev_linear_velocity - gravity_contribution
	var impulse_magnitude := delta_v.length()

	if impulse_magnitude >= damage_threshold:
		health -= (impulse_magnitude - damage_threshold) * damage_per_impulse
		if health <= 0.0:
			health = max_health
			call_deferred("_respawn_at_start")
			return
		if impulse_magnitude >= stun_threshold and _state == State.NORMAL:
			_pending_stun = true


## Teleport the enemy back to a random road start position.
func _respawn_at_start() -> void:
	if _start_positions.size() == 0:
		return

	var start_pos: Vector3 = _start_positions[_rng.randi_range(0, _start_positions.size() - 1)]
	global_position = start_pos + Vector3(0.0, 2.0, 0.0)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	health = max_health
	_state = State.NORMAL
	_stun_timer = 0.0
	_recover_timer = 0.0
	_prev_linear_velocity = Vector3.ZERO
	rotation = Vector3(0.0, rotation.y, 0.0)
	_set_axis_locks(true)
