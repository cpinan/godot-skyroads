# The on-screen controls for a phone: a thumbstick on the left, jump on the
# right.
#
# The original has no touch device — skyroads.cfg's `control` word only knows
# keyboard, joystick and mouse — so this is new, not recovered. What is NOT
# new is what it produces: like every other device it collapses to the three
# values the simulation takes (steer, accel, jump) through `PlayerInput`, so
# the physics never learns that a finger was involved and the three-way
# differential against the C engine still holds.
#
# Layout decisions, in case they need changing:
#
#   * The hit areas are the whole left and right halves of the screen, not
#     the drawn circles. A thumb on a phone lands where it lands; a control
#     you have to hit is a control you fight. The drawings are a hint at
#     where the thumbs belong, nothing more.
#   * The stick's origin follows the touch that started it (a "floating"
#     stick). Anchoring it to the drawn circle means the first few pixels of
#     every drag are spent travelling to the anchor.
#   * Both sit over the dashboard band rather than the road: rows 129..199 of
#     the original screen are static art, so covering part of it costs the
#     player nothing they were reading at 36 Hz.
#
# Everything is placed in the original's 320x240 display space, the same
# coordinates the menus and the dashboard use, so the layout scales with the
# rest of the game instead of drifting on a different DPI.
class_name TouchControls
extends CanvasLayer

## Canvas-space geometry. y is display space (200-line space x 1.2).
const STICK_CENTRE := Vector2(40, 196)
const STICK_BASE_R := 27.0
const STICK_KNOB_R := 12.0
const JUMP_CENTRE := Vector2(280, 196)
const JUMP_R := 27.0
## Drag distance, in canvas pixels, that counts as a full stick deflection.
## PlayerInput.DEADZONE (0.45) then bites at about 12 px, which is roughly a
## thumb's width of travel — far enough not to trigger on a resting thumb,
## near enough that steering does not feel like a lever.
const STICK_RANGE := 27.0
## Pause / back, top right. Small and out of the way: it is the one control
## that must never fire by accident mid-jump.
const PAUSE_RECT := Rect2(292, 4, 24, 20)

## Set by Main; called with no arguments when the pause box is tapped.
var on_pause: Callable

var _stick_touch := -1                ## touch index driving the stick, or -1
var _jump_touches := {}               ## touch index -> true
var _stick_origin := STICK_CENTRE
var _stick_pos := STICK_CENTRE
## Accept mouse events as well as touches, so `--touch` can drive this on a
## desktop without turning on Godot's global mouse-to-touch emulation (which
## would also reach the mouse control device and the menus).
var mouse_fallback := false

var _draw_node: Control


func _ready() -> void:
	layer = 50                     # over the HUD, under the fade (layer 100)
	_draw_node = Control.new()
	_draw_node.position = Vector2.ZERO
	_draw_node.size = Vector2(SkyRoads.SCREEN_W, SkyRoads.SQUARE_H)
	# The controls are read from _input, not from Godot's focus system: a
	# Control that ate events would also eat the taps the menus need.
	_draw_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_draw_node.draw.connect(_draw_controls)
	add_child(_draw_node)


## What the simulation should see this frame: [steer, accel, jump].
func sample() -> Array:
	var off := _stick_pos - _stick_origin
	return PlayerInput.from_axes(off.x / STICK_RANGE, off.y / STICK_RANGE,
		not _jump_touches.is_empty())


## True while a finger is on the jump half — Main uses it for menu screens,
## where jump is the confirm key.
func jump_held() -> bool:
	return not _jump_touches.is_empty()


func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventScreenTouch:
		var t := ev as InputEventScreenTouch
		_touch(t.index, t.position, t.pressed)
	elif ev is InputEventScreenDrag:
		var d := ev as InputEventScreenDrag
		_drag(d.index, d.position)
	elif mouse_fallback and ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_touch(0, mb.position, mb.pressed)
	elif mouse_fallback and ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			_drag(0, mm.position)


## Screen coordinates arrive in window pixels; everything here is in the
## original's 320x240 space, which is what the canvas transform maps.
func _to_canvas(p: Vector2) -> Vector2:
	return _draw_node.get_global_transform().affine_inverse() * p


func _touch(index: int, screen_pos: Vector2, pressed: bool) -> void:
	var p := _to_canvas(screen_pos)
	if not pressed:
		if index == _stick_touch:
			_stick_touch = -1
			_stick_origin = STICK_CENTRE
			_stick_pos = STICK_CENTRE
			_draw_node.queue_redraw()
		if _jump_touches.erase(index):
			_draw_node.queue_redraw()
		return
	if PAUSE_RECT.has_point(p):
		# swallowed, or the same tap would also read as "any key resumes"
		get_viewport().set_input_as_handled()
		if on_pause.is_valid():
			on_pause.call()
		return
	if p.x < SkyRoads.SCREEN_W * 0.5:
		if _stick_touch < 0:
			_stick_touch = index
			_stick_origin = p
			_stick_pos = p
			_draw_node.queue_redraw()
	else:
		_jump_touches[index] = true
		_draw_node.queue_redraw()


func _drag(index: int, screen_pos: Vector2) -> void:
	if index != _stick_touch:
		return
	_stick_pos = _to_canvas(screen_pos)
	_draw_node.queue_redraw()


## Where the knob is drawn: the live offset, clamped to the base circle so
## the stick cannot be dragged off its own art.
func _knob_pos() -> Vector2:
	if _stick_touch < 0:
		return STICK_CENTRE
	var off := _stick_pos - _stick_origin
	if off.length() > STICK_BASE_R - STICK_KNOB_R:
		off = off.normalized() * (STICK_BASE_R - STICK_KNOB_R)
	return _stick_origin + off


func _draw_controls() -> void:
	var idle := Color(1.0, 0.78, 0.35, 0.30)     # the HUD's amber, faint
	var live := Color(1.0, 0.86, 0.50, 0.62)
	var base := _stick_origin if _stick_touch >= 0 else STICK_CENTRE
	_draw_node.draw_arc(base, STICK_BASE_R, 0.0, TAU, 40,
		live if _stick_touch >= 0 else idle, 1.5)
	_draw_node.draw_circle(_knob_pos(), STICK_KNOB_R,
		live if _stick_touch >= 0 else idle)

	var jc := live if jump_held() else idle
	_draw_node.draw_arc(JUMP_CENTRE, JUMP_R, 0.0, TAU, 40, jc, 1.5)
	# an up-chevron, because the button is jump and nothing else
	var a := JUMP_CENTRE + Vector2(-11, 5)
	var b := JUMP_CENTRE + Vector2(0, -8)
	var c := JUMP_CENTRE + Vector2(11, 5)
	_draw_node.draw_polyline(PackedVector2Array([a, b, c]), jc, 3.0)

	# pause: two bars, the universal glyph, drawn where the box is tapped
	_draw_node.draw_rect(PAUSE_RECT, idle, false, 1.0)
	var pc := PAUSE_RECT.position + Vector2(7, 5)
	_draw_node.draw_rect(Rect2(pc, Vector2(3, 10)), idle, true)
	_draw_node.draw_rect(Rect2(pc + Vector2(7, 0), Vector2(3, 10)), idle, true)
