class_name Button3D
extends XRToolsInteractableArea

## Reusable world-space 3D button that handles both VR pointer events and mouse picking.
##
## Build pattern: instantiate, set properties (text, size, colors, etc.), add_child.
## The button auto-builds its CollisionShape3D + Label3D in _ready and emits `clicked`
## on either VR trigger press while hovering or left mouse button click.
##
## Hover state is mirrored across both input paths so the visual highlight cannot diverge
## from which button the player is actually about to activate.

## Emitted on a confirmed click (VR trigger press while hovering, or left mouse button click).
signal clicked

## Layer the pointer raycasts against — bit 20 is in XR Tools' default pointer mask (0x500000)
## and is off the ground/enemy layers so placement raycasts ignore the button.
const _UI_LAYER_BIT := 1 << 20

## Default colors — match the previous wave/upgrade buttons so visuals don't change.
const DEFAULT_BASE_COLOR := Color(0.25, 1.0, 0.4)  # green resting state
const DEFAULT_HOVER_COLOR := Color(1.0, 0.95, 0.2)  # yellow hover affordance

@export var text: String = "BUTTON"  # initial label text; runtime updates use set_text()
@export var size: Vector3 = Vector3(10.0, 4.0, 4.0)  # BoxShape3D dimensions for the click region
@export var base_color: Color = DEFAULT_BASE_COLOR  # label color when not hovered
@export var hover_color: Color = DEFAULT_HOVER_COLOR  # label color while hovered
@export var pixel_size: float = 0.05  # Label3D pixel_size — controls font world size
@export var font_size: int = 96  # Label3D font_size in pt
@export var outline_size: int = 16  # Label3D outline_size — keeps text readable over varied backdrops
@export var billboard: bool = false  # if true, label always faces the camera

var _label: Label3D = null  # built in _ready; mutate via set_text()/set_modulate-equivalents
var _is_hovered: bool = false  # tracks current hover state across mouse + VR paths

func _ready() -> void:
	# Configure Area3D for both XR pointer (raycast on layer 21) and mouse picking.
	collision_layer = _UI_LAYER_BIT
	collision_mask = 0
	input_ray_pickable = true

	_build_collision()
	_build_label()
	_wire_input_signals()
	_wire_visibility()

func _build_collision() -> void:
	# BoxShape3D click region — generous size for both mouse and ray accuracy in VR.
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	col.shape = shape
	add_child(col)

func _build_label() -> void:
	# Centered Label3D with no_depth_test so the text always renders on top.
	_label = Label3D.new()
	_label.text = text
	_label.pixel_size = pixel_size
	_label.font_size = font_size
	_label.outline_size = outline_size
	_label.modulate = base_color
	_label.no_depth_test = true
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if billboard:
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(_label)

func _wire_input_signals() -> void:
	# VR path — XRToolsInteractableArea emits pointer_event from XRToolsPointerEvent.report().
	pointer_event.connect(_on_pointer_event)
	# Mouse path — Area3D mouse_entered/exited/input_event fire from Camera3D physics picking.
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	input_event.connect(_on_mouse_input_event)

func _wire_visibility() -> void:
	# Disable monitoring when hidden so a stale hover can't fire a click on a hidden button,
	# and force-clear the hover highlight if the button vanishes mid-hover.
	visibility_changed.connect(_on_visibility_changed)
	_on_visibility_changed()  # apply initial state

## Update the visible label text — safe to call before or after _ready.
func set_text(new_text: String) -> void:
	text = new_text
	if _label != null:
		_label.text = new_text

## Override the resting label color and apply immediately if not currently hovered.
func set_base_color(color: Color) -> void:
	base_color = color
	if _label != null and not _is_hovered:
		_label.modulate = color

func _on_pointer_event(event) -> void:
	# Single VR event handler — translate XRToolsPointerEvent types into hover + click signals.
	if not (event is XRToolsPointerEvent):
		return
	match event.event_type:
		XRToolsPointerEvent.Type.ENTERED:
			_set_hovered(true)
		XRToolsPointerEvent.Type.EXITED:
			_set_hovered(false)
		XRToolsPointerEvent.Type.PRESSED:
			# Only emit if hovered to filter out edge cases where a stale press lands here.
			if _is_hovered and visible:
				clicked.emit()

func _on_mouse_entered() -> void:
	_set_hovered(true)

func _on_mouse_exited() -> void:
	_set_hovered(false)

func _on_mouse_input_event(_camera: Node, event: InputEvent, _pos: Vector3, _norm: Vector3, _shape_idx: int) -> void:
	# Only react to a left-mouse-button press so trigger pulls in VR don't double-fire here.
	if not (event is InputEventMouseButton):
		return
	if not (event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	if not visible:
		return
	clicked.emit()
	get_viewport().set_input_as_handled()

func _set_hovered(hovered: bool) -> void:
	# Mutate the visible color in lockstep with the hover bool so highlight and click commit agree.
	if _is_hovered == hovered:
		return
	_is_hovered = hovered
	if _label != null:
		_label.modulate = hover_color if hovered else base_color

func _on_visibility_changed() -> void:
	# Pause physics-side input when hidden; the area can't accept ENTERED/PRESSED while invisible.
	monitoring = visible
	monitorable = visible
	if not visible and _is_hovered:
		_set_hovered(false)
