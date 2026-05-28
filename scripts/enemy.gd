extends CharacterBody3D

## Enemy that walks along pre-computed A* waypoints and ragdolls when hit hard.
## Uses kinematic movement (move_and_slide) so it cannot tunnel into terrain.

enum State { PATHING, RAGDOLL, RECOVERING, DEAD }

## Emitted when the enemy dies — wave manager / spawner listens for rewards.
signal died(max_hp: float)

## Terrain reference — provides height queries and rejoin-path A*. Set by spawner.
var terrain: StaticBody3D
## Defence objective — enemies die/respawn when they reach it. Set by spawner.
var defence_objective: Area3D

## Horizontal movement speed in world units per second.
var move_speed: float = 17.0
## Vertical jump kick used when pathing gets stuck against small ledges.
var jump_strength: float = 10.0

## Current and maximum hit points.
var hp: float = 50.0
var max_hp: float = 100.0

## Cached road-start positions for respawn teleportation.
var _start_positions: Array = []
## Per-enemy RNG — randomizes wander, giant variant, respawn choice, ragdoll spin.
var _rng := RandomNumberGenerator.new()

## If true, reaching the goal teleports the enemy back to start instead of killing it.
var should_respawn: bool = false

## Active state in the pathing/ragdoll/recovering/dead machine.
var _state: State = State.PATHING
## Seconds the body has been considered "settled" while in RAGDOLL — gates transition to RECOVERING.
var _settle_timer: float = 0.0
## Seconds since entering DEAD — gates queue_free / respawn.
var _dead_timer: float = 0.0
## Seconds spent in RAGDOLL state — forces recovery after timeout to prevent infinite drifting.
var _ragdoll_timer: float = 0.0
## Seconds spent in RECOVERING state — forces PATHING after timeout to prevent infinite standing up.
var _recovering_timer: float = 0.0

## Mesh material — used by spawner to tint on HP change / damage flash. Assigned externally.
var material: StandardMaterial3D
## Seconds remaining on damage flash — while > 0, the material stays red.
var _flash_timer: float = 0.0
## True while a VR controller raycast is pointing at this enemy — shows cyan highlight.
var _is_targeted: bool = false

## Overlay colors for the damage tint gradient — alpha 0 at full HP (invisible), opaque red at death.
const _COLOR_FULL_HP  := Color(1.0, 0.0, 0.0, 0.0)
const _COLOR_LOW_HP   := Color(1.0, 0.2, 0.0, 0.7)
const _COLOR_TARGETED := Color(0.0, 1.0, 1.0, 0.6)

## Global gravity magnitude — read from ProjectSettings to match world.gd's setting.
var GRAVITY: float = ProjectSettings.get_setting("physics/3d/default_gravity")
## Maximum seconds an enemy can remain in RAGDOLL state before forced recovery — prevents infinite drifting.
const MAX_RAGDOLL_TIME := 4.0
## Maximum seconds an enemy can remain in RECOVERING state before forced PATHING — prevents infinite standing up.
const MAX_RECOVERING_TIME := 3.0

## Impulse magnitude (from apply_impulse) that tips the enemy into RAGDOLL.
var _impulse_ragdoll_threshold: float = 20.0
## Accumulated-velocity threshold that tips RAGDOLL from apply_force or from fast external velocity changes.
var _velocity_ragdoll_threshold: float = 40.0
## HP removed per unit of impulse magnitude when deal_damage is true on apply_impulse.
const IMPULSE_DAMAGE_SCALE := 1.0

## Manually-integrated angular velocity driving visual tumble while ragdolled.
var _angular_velocity: Vector3 = Vector3.ZERO

## Wander: slowly-drifting yaw offset applied to the movement direction so the crowd isn't in a straight line.
var _wander_angle: float = 0.0
var _wander_target: float = 0.0
var _wander_timer: float = 0.0

## Stuck detection: seconds spent with near-zero horizontal speed while pathing on ground.
var _stuck_timer: float = 0.0
## Cooldown after a jump to prevent rapid re-jumping.
var _jump_cooldown: float = 0.0

# ---------------------------------------------------------------------------
# Waypoint navigation
# ---------------------------------------------------------------------------

## Index into terrain.get_road_paths_world() identifying which path this enemy follows.
var _path_idx: int = 0
## Laterally-offset world-space waypoints assigned at spawn.
var _waypoints: Array = []  # Array[Vector3]
## Index of the next waypoint to steer toward.
var _waypoint_idx: int = 0

## XZ distance at which we consider a waypoint reached and advance to the next.
const _WAYPOINT_REACH_DIST: float = 1.8

## Rejoin path — short A* path computed after ragdoll to return the enemy to its main path.
var _rejoin_waypoints: Array = []  # Array[Vector3]
var _rejoin_idx: int = 0
## Countdown after ragdoll ends before A* is triggered (absorbs rapid re-hits).
var _rejoin_delay: float = 0.0
const _REJOIN_DELAY: float = 0.8


## Called by enemy_spawn after creating this enemy.
func assign_path(waypoints: Array, path_idx: int) -> void:
	_waypoints = waypoints
	_path_idx = path_idx
	_waypoint_idx = 0


## Wire up terrain queries and the defence-objective signal. Called once on add_child.
func _ready() -> void:
	_rng.randomize()
	add_to_group("enemies")
	assert(terrain != null, "enemy.terrain must be set before add_child")
	assert(defence_objective != null, "enemy.defence_objective must be set before add_child")
	_start_positions = terrain.get_start_world_positions()
	defence_objective.enemy_entered.connect(_on_defence_objective_entered)

	GRAVITY = ProjectSettings.get_setting("physics/3d/default_gravity")

	# 10% chance to spawn as a giant variant — double size, double HP.
	if _rng.randf() < 0.1:
		scale *= 2.0
		max_hp *= 2.0
		hp = max_hp


## One-shot velocity kick. Used by explosions, projectile impacts, per-frame wind/suck calls.
func apply_impulse(direction: Vector3, magnitude: float, deal_damage: bool = false) -> void:
	if _state == State.DEAD:
		return
	velocity += direction.normalized() * magnitude
	if magnitude >= _impulse_ragdoll_threshold and _state == State.PATHING:
		_enter_ragdoll()
	if deal_damage:
		hp -= magnitude * IMPULSE_DAMAGE_SCALE
		if hp <= 0.0:
			_enter_dead()
		else:
			_flash_red()


## Frame-rate-independent continuous force.
func apply_force(direction: Vector3, magnitude: float, delta: float) -> void:
	if _state == State.DEAD:
		return
	velocity += direction.normalized() * magnitude * delta
	if velocity.length() > _velocity_ragdoll_threshold and _state == State.PATHING:
		_enter_ragdoll()


## Direct HP damage — called by spikes, arrow projectile, etc.
func apply_dmg(amount: float) -> void:
	if _state == State.DEAD:
		_flash_red()
		return
	hp -= amount
	if hp <= 0.0:
		_enter_dead()
	else:
		_flash_red()


## Main physics tick — dispatches to the current state handler then commits movement.
func _physics_process(delta: float) -> void:
	assert(terrain != null)

	if global_position.y < -30.0:
		_enter_dead()
		queue_free()
		return

	match _state:
		State.PATHING:
			_process_pathing(delta)
		State.RAGDOLL:
			_process_ragdoll(delta)
		State.RECOVERING:
			_process_recovering(delta)
		State.DEAD:
			_process_dead(delta)

	move_and_slide()

	if _flash_timer > 0.0:
		_flash_timer -= delta
		if _flash_timer <= 0.0:
			_update_color()


## PATHING: waypoint following + gravity + stuck-detection jump.
func _process_pathing(delta: float) -> void:
	velocity.y -= GRAVITY * delta

	# Wander drift — randomized yaw offset lerped toward a new target.
	_wander_timer -= delta
	if _wander_timer <= 0.0:
		_wander_target = _rng.randf_range(-0.3, 0.3)
		_wander_timer = _rng.randf_range(0.8, 2.0)
	_wander_angle = lerpf(_wander_angle, _wander_target, clampf(delta * 3.0, 0.0, 1.0))

	# Rejoin delay countdown — triggered when recovering from ragdoll.
	if _rejoin_delay > 0.0:
		_rejoin_delay -= delta
		if _rejoin_delay <= 0.0:
			_start_rejoin()

	# Determine active waypoint list and index.
	var active_wps: Array  = _rejoin_waypoints if _rejoin_waypoints.size() > 0 else _waypoints
	var active_idx: int    = _rejoin_idx        if _rejoin_waypoints.size() > 0 else _waypoint_idx

	if active_wps.size() > 0 and active_idx < active_wps.size():
		var target: Vector3 = active_wps[active_idx]
		var to_target := Vector2(target.x - global_position.x, target.z - global_position.z)
		var dist_xz := to_target.length()

		if dist_xz < _WAYPOINT_REACH_DIST:
			# Reached — advance index.
			if _rejoin_waypoints.size() > 0:
				_rejoin_idx += 1
				if _rejoin_idx >= _rejoin_waypoints.size():
					# Done rejoining: snap back to nearest main-path waypoint.
					_waypoint_idx = _nearest_waypoint_idx()
					_rejoin_waypoints = []
					_rejoin_idx = 0
			else:
				_waypoint_idx = mini(_waypoint_idx + 1, _waypoints.size() - 1)
		else:
			# Steer toward waypoint with wander offset.
			var flow := to_target.normalized().rotated(_wander_angle)
			var desired := Vector3(flow.x, 0.0, flow.y) * move_speed
			velocity.x = lerpf(velocity.x, desired.x, clampf(delta * 5.0, 0.0, 1.0))
			velocity.z = lerpf(velocity.z, desired.z, clampf(delta * 5.0, 0.0, 1.0))

	# Stuck detection — hop if blocked on the ground for long enough.
	_jump_cooldown -= delta
	var horiz: float = Vector2(velocity.x, velocity.z).length()
	if horiz < move_speed * 0.2 and is_on_floor():
		_stuck_timer += delta
		if _stuck_timer > 0.5 and _jump_cooldown <= 0.0:
			velocity.y = jump_strength
			_stuck_timer = 0.0
			_jump_cooldown = 1.0
	else:
		_stuck_timer = 0.0

	# Face the horizontal movement direction.
	if horiz > 1.0:
		var target_yaw: float = atan2(-velocity.x, -velocity.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(delta * 8.0, 0.0, 1.0))


## RAGDOLL: gravity + horizontal damping + manual angular integration for visual tumble.
func _process_ragdoll(delta: float) -> void:
	velocity.y -= GRAVITY * delta

	velocity.x = lerpf(velocity.x, 0.0, clampf(delta * 1.0, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, 0.0, clampf(delta * 1.0, 0.0, 1.0))

	if _angular_velocity.length_squared() > 0.0001:
		var axis := _angular_velocity.normalized()
		var angle := _angular_velocity.length() * delta
		rotate(axis, angle)
		_angular_velocity = _angular_velocity.lerp(Vector3.ZERO, clampf(delta * 1.5, 0.0, 1.0))

	_ragdoll_timer += delta
	if _ragdoll_timer >= MAX_RAGDOLL_TIME:
		_state = State.RECOVERING
		_angular_velocity = Vector3.ZERO
		_recovering_timer = 0.0
		_rejoin_delay = _REJOIN_DELAY
		return

	var settled: bool = is_on_floor() \
			and velocity.length() < 2.0 \
			and _angular_velocity.length() < 0.5
	if settled:
		_settle_timer += delta
		if _settle_timer >= 0.3:
			_state = State.RECOVERING
			_recovering_timer = 0.0
			_rejoin_delay = _REJOIN_DELAY
	else:
		_settle_timer = 0.0


## RECOVERING: slerp quaternion back to upright, then resume PATHING.
func _process_recovering(delta: float) -> void:
	velocity.y -= GRAVITY * delta

	velocity.x = lerpf(velocity.x, 0.0, clampf(delta * 2.0, 0.0, 1.0))
	velocity.z = lerpf(velocity.z, 0.0, clampf(delta * 2.0, 0.0, 1.0))

	_recovering_timer += delta
	if _recovering_timer >= MAX_RECOVERING_TIME:
		_state = State.PATHING
		_angular_velocity = Vector3.ZERO
		_ragdoll_timer = 0.0
		_rejoin_delay = _REJOIN_DELAY
		if has_meta("recovering_target_quat"):
			remove_meta("recovering_target_quat")
		return

	if not has_meta("recovering_target_quat"):
		var current_euler := quaternion.get_euler()
		var target_quat := Quaternion.from_euler(Vector3(0.0, current_euler.y, 0.0))
		set_meta("recovering_target_quat", target_quat)

	var target_quat: Quaternion = get_meta("recovering_target_quat")
	quaternion = quaternion.slerp(target_quat, clampf(delta * 5.0, 0.0, 1.0))

	if quaternion.dot(target_quat) > 0.99:
		_state = State.PATHING
		_angular_velocity = Vector3.ZERO
		_ragdoll_timer = 0.0
		_recovering_timer = 0.0
		_rejoin_delay = _REJOIN_DELAY
		remove_meta("recovering_target_quat")


## DEAD: let gravity pull the corpse down, then despawn/respawn after 1s.
func _process_dead(delta: float) -> void:
	velocity.y -= GRAVITY * delta
	_dead_timer += delta
	if _dead_timer >= 1.0:
		if should_respawn:
			_respawn_at_start()
		else:
			queue_free()


## Transition into RAGDOLL — seeds a random tumble proportional to current speed.
func _enter_ragdoll() -> void:
	if _state == State.DEAD or _state == State.RAGDOLL:
		return
	_state = State.RAGDOLL
	_settle_timer = 0.0
	_ragdoll_timer = 0.0

	if has_meta("recovering_target_quat"):
		remove_meta("recovering_target_quat")

	var spin_mag: float = clampf(velocity.length() * 0.2, 2.0, 8.0)
	_angular_velocity = Vector3(
		_rng.randf_range(-1.0, 1.0),
		_rng.randf_range(-1.0, 1.0),
		_rng.randf_range(-1.0, 1.0),
	).normalized() * spin_mag


## Transition into DEAD — paints the material red, fires the `died` signal.
func _enter_dead() -> void:
	if _state == State.DEAD:
		return
	_is_targeted = false
	hp = 0.0
	_dead_timer = 0.0
	_state = State.DEAD
	if material:
		material.albedo_color = Color(1.0, 0.0, 0.0, 1.0)
	died.emit(max_hp)


## Briefly tint red to signal damage.
func _flash_red() -> void:
	_flash_timer = 0.12
	if material:
		material.albedo_color = Color(1.0, 0.0, 0.0)


## Called by VR targeting system to show/hide the cyan target highlight.
func set_targeted(targeted: bool) -> void:
	if _is_targeted == targeted:
		return
	_is_targeted = targeted
	if _flash_timer <= 0.0:
		_update_color()


## Repaint the material based on current HP or targeting state.
func _update_color() -> void:
	if not material:
		return
	if _is_targeted:
		material.albedo_color = _COLOR_TARGETED
	else:
		var t := clampf(1.0 - hp / max_hp, 0.0, 1.0)
		material.albedo_color = _COLOR_FULL_HP.lerp(_COLOR_LOW_HP, t)


## Signal callback from the defence objective — kill or respawn when this enemy touches it.
func _on_defence_objective_entered(body: Node3D) -> void:
	if body != self or _state == State.DEAD:
		return
	if should_respawn:
		_respawn_at_start()
	else:
		_enter_dead()


## Teleport the enemy back to a random road start and reset all state.
func _respawn_at_start() -> void:
	if _start_positions.size() == 0:
		return

	var start_pos: Vector3 = _start_positions[_rng.randi_range(0, _start_positions.size() - 1)]
	global_position = start_pos + Vector3(0.0, 2.0, 0.0)

	if has_method("reset_physics_interpolation"):
		reset_physics_interpolation()

	velocity = Vector3.ZERO
	_angular_velocity = Vector3.ZERO
	hp = max_hp
	_flash_timer = 0.0
	_update_color()
	_state = State.PATHING
	_settle_timer = 0.0
	_ragdoll_timer = 0.0
	_recovering_timer = 0.0
	_wander_angle = 0.0
	_wander_target = 0.0
	_wander_timer = 0.0
	_stuck_timer = 0.0
	_jump_cooldown = 0.0
	quaternion = Quaternion.IDENTITY
	_waypoint_idx = 0
	_rejoin_waypoints = []
	_rejoin_idx = 0
	_rejoin_delay = 0.0

	if has_meta("recovering_target_quat"):
		remove_meta("recovering_target_quat")


# ---------------------------------------------------------------------------
# Waypoint helpers
# ---------------------------------------------------------------------------

## Returns the index of the waypoint in _waypoints closest to current position.
func _nearest_waypoint_idx() -> int:
	var best_dsq := INF
	var best_i := _waypoint_idx
	for i in range(_waypoints.size()):
		var wp: Vector3 = _waypoints[i]
		var dx := wp.x - global_position.x
		var dz := wp.z - global_position.z
		var dsq := dx * dx + dz * dz
		if dsq < best_dsq:
			best_dsq = dsq
			best_i = i
	return best_i


## Ask the terrain for a short A* path back to the main route, then follow it.
func _start_rejoin() -> void:
	if terrain == null or _waypoints.size() == 0:
		return
	var world_path: Array = terrain.find_rejoin_path(global_position, _path_idx)
	if world_path.size() > 0:
		_rejoin_waypoints = world_path
		_rejoin_idx = 0
