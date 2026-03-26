extends RigidBody3D

enum State { PATHING, RAGDOLL, RECOVERING, DEAD }

## Reference to the terrain node (set by the spawner).
var terrain: StaticBody3D
## Reference to the defence objective (set by the spawner).
var defence_objective: Area3D

## Movement speed in world units per second.
var move_speed: float = 10.0
## How strongly the enemy is pulled toward the terrain surface height.
var height_correction_strength: float = 10.0

## HP and impact damage.
var hp: float = 100.0
var max_hp: float = 100.0
var impact_damage_threshold: float = 15.0
var impact_damage_scale: float = 2.0

## Cached start positions (world space).
var _start_positions: Array = []
## RNG for picking a random start on respawn.
var _rng := RandomNumberGenerator.new()

var _state: State = State.PATHING
var _settle_timer: float = 0.0
var _dead_timer: float = 0.0
var _prev_velocity := Vector3.ZERO
var _material: StandardMaterial3D

const _COLOR_FULL_HP := Color(0.85, 0.85, 0.85)
const _COLOR_LOW_HP := Color(1.0, 0.4, 0.0)
## Wander: a slowly-drifting angular offset applied to the flow direction.
var _wander_angle: float = 0.0
var _wander_target: float = 0.0
var _wander_timer: float = 0.0


func _ready() -> void:
	_rng.randomize()
	_lock_angular_axes()
	assert(terrain != null)
	assert(defence_objective != null)
	_start_positions = terrain.get_start_world_positions()
	defence_objective.enemy_entered.connect(_on_defence_objective_entered)


func _physics_process(delta: float) -> void:
	assert(terrain != null)

	var pos := global_position

	match _state:
		State.PATHING:
			_process_pathing(delta, pos)
		State.RAGDOLL:
			_process_ragdoll(delta)
		State.RECOVERING:
			_process_recovering(delta)
		State.DEAD:
			_process_dead(delta)
			_prev_velocity = linear_velocity
			return

	# --- Impact damage detection ---
	var velocity_delta := (linear_velocity - _prev_velocity).length()
	if velocity_delta > impact_damage_threshold:
		var damage := (velocity_delta - impact_damage_threshold) * impact_damage_scale
		hp -= damage
		if hp <= 0.0:
			_enter_dead()
		else:
			_update_color()
	_prev_velocity = linear_velocity

func _process_pathing(delta: float, pos: Vector3) -> void:
	# --- Wander: smoothly drift a random angular offset ---
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_target = _rng.randf_range(-0.4, 0.4)  # ~±23 degrees max
		_wander_timer = _rng.randf_range(0.8, 2.0)
	_wander_angle = lerpf(_wander_angle, _wander_target, clampf(delta * 3.0, 0.0, 1.0))

	# --- Flow field movement ---
	var flow: Vector2 = terrain.get_flow_direction(pos.x, pos.z)
	if flow != Vector2.ZERO:
		var rotated_flow := flow.rotated(_wander_angle)
		var desired_vel := Vector3(rotated_flow.x, 0.0, rotated_flow.y).normalized() * move_speed
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

	# --- Transition to RAGDOLL on strong impulse ---
	if linear_velocity.length() > move_speed * 2.0:
		_state = State.RAGDOLL
		_settle_timer = 0.0
		_unlock_angular_axes()


func _process_ragdoll(delta: float) -> void:
	# Pure physics — no steering or height correction.
	# Transition to RECOVERING once the body has settled.
	if linear_velocity.length() < 2.0 and angular_velocity.length() < 1.0:
		_settle_timer += delta
		if _settle_timer >= 0.3:
			_state = State.RECOVERING
			_lock_angular_axes()
	else:
		_settle_timer = 0.0


func _process_recovering(delta: float) -> void:
	# Slerp toward upright, preserving Y rotation.
	var current_quat := quaternion
	var current_euler := current_quat.get_euler()
	var target_quat := Quaternion.from_euler(Vector3(0.0, current_euler.y, 0.0))
	quaternion = current_quat.slerp(target_quat, clampf(delta * 5.0, 0.0, 1.0))

	# Transition to PATHING when close enough to upright.
	if current_quat.dot(target_quat) > 0.99:
		_state = State.PATHING

	# Re-enter ragdoll if hit again during recovery.
	if linear_velocity.length() > move_speed * 2.0:
		_state = State.RAGDOLL
		_settle_timer = 0.0
		_unlock_angular_axes()


func _lock_angular_axes() -> void:
	axis_lock_angular_x = true
	axis_lock_angular_z = true


func _unlock_angular_axes() -> void:
	axis_lock_angular_x = false
	axis_lock_angular_z = false


func _enter_dead() -> void:
	hp = 0.0
	_dead_timer = 0.0
	_state = State.DEAD
	_unlock_angular_axes()
	_update_color()


func _process_dead(delta: float) -> void:
	_dead_timer += delta
	if _dead_timer >= 3.0:
		_respawn_at_start()


func _update_color() -> void:
	if _material:
		var t := clampf(1.0 - hp / max_hp, 0.0, 1.0)
		_material.albedo_color = _COLOR_FULL_HP.lerp(_COLOR_LOW_HP, t)

func _on_defence_objective_entered(body: Node3D) -> void:
	if body == self:
		_respawn_at_start()


## Teleport the enemy back to a random road start position.
func _respawn_at_start() -> void:
	if _start_positions.size() == 0:
		return

	var start_pos: Vector3 = _start_positions[_rng.randi_range(0, _start_positions.size() - 1)]
	var new_pos := start_pos + Vector3(0.0, 2.0, 0.0)

	# Set position directly. In Godot 4, this is the standard way to teleport 
	# a RigidBody3D from within _physics_process.
	global_position = new_pos

	# Stop the visual "zipping" effect caused by physics interpolation.
	if has_method("reset_physics_interpolation"):
		reset_physics_interpolation()

	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	hp = max_hp
	_prev_velocity = Vector3.ZERO
	_update_color()
	_state = State.PATHING
	_settle_timer = 0.0
	_wander_angle = 0.0
	_wander_target = 0.0
	_wander_timer = 0.0
	_lock_angular_axes()
	quaternion = Quaternion.IDENTITY

