extends RigidBody3D

## Physically-simulated boulder thrown by the player (F key).
## Rolls across terrain under gravity and delivers impulse to any enemy it contacts.
## Collision layer 4 (bit 8) lets Jolt resolve two-way interactions with enemies naturally.

## Sphere radius — shared by mesh and collision shape.
const RADIUS := 1.0
## Seconds before auto-despawn — prevents orphaned boulders persisting forever.
const LIFETIME := 15.0
## Fraction of (velocity × mass) converted to enemy knockback impulse on contact.
const IMPACT_SCALE := 0.1

## Enemies already struck this flight — prevents re-applying impulse on sustained contact.
var _hit_enemies: Array = []


func _ready() -> void:
	collision_layer = 8    # Layer 4 (bit 2^3=8) — detected by enemies so Jolt resolves two-way collisions
	collision_mask = 1 | 2 # collide with ground (1) and enemies (2)
	contact_monitor = true
	max_contacts_reported = 8
	_build_mesh()
	_build_collision()
	body_entered.connect(_on_body_entered)
	get_tree().create_timer(LIFETIME).timeout.connect(queue_free)


## Build a sphere mesh tinted to look like a rough rock.
func _build_mesh() -> void:
	var mi := MeshInstance3D.new()       # container for the sphere visual
	var sm := SphereMesh.new()           # sphere primitive matching RADIUS
	sm.radius = RADIUS
	sm.height = RADIUS * 2.0
	mi.mesh = sm
	var mat := StandardMaterial3D.new()  # rock-brown surface tint
	mat.albedo_color = Color(0.35, 0.28, 0.22)
	mi.material_override = mat
	add_child(mi)


## Build the SphereShape3D collision volume matching the mesh.
func _build_collision() -> void:
	var col := CollisionShape3D.new()  # wrapper node required by Godot
	var shape := SphereShape3D.new()   # sphere matching RADIUS for ground and enemy contact
	shape.radius = RADIUS
	col.shape = shape
	add_child(col)


## On contact: deliver a single impulse scaled by momentum, then ignore further contact with that body.
func _on_body_entered(body: Node3D) -> void:
	if not body.is_in_group("enemies"):
		return  # ground contacts need no impulse
	if body in _hit_enemies:
		return
	assert(body.has_method("apply_impulse"), "all layer-2 bodies must be enemies with apply_impulse")
	_hit_enemies.append(body)
	var impact_dir := linear_velocity.normalized()                # boulder travel direction at moment of contact
	var magnitude := linear_velocity.length() * mass * IMPACT_SCALE  # momentum-scaled knockback strength
	body.apply_impulse(impact_dir, magnitude, true)
