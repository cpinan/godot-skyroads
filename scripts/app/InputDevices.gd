# gd-audit: ignore GDBP-101 — every script in scripts/ is PascalCase; a lone
# snake_case file would be a third convention, not a fix. See docs/PERF.md.
# Reads the hardware. Nothing here decides anything.
#
# The MAPPING — which axis position becomes which of the simulation's three
# integers — lives in PlayerInput, which is pure and covered by
# tests/test_input.gd. This file only samples whichever device skyroads.cfg
# selects (0 keyboard, 1 joystick, 2 mouse) and hands the numbers over, so a
# gamepad tweak cannot change what the simulation does with a given input,
# only which input a gesture produces.
#
# No `class_name`: see scripts/PauseMenu.gd for why.
extends RefCounted

## Godot reports a resting stick as a small non-zero number, and a worn one as
## a larger one. This is the gate BELOW which an axis is not moving at all; the
## threshold that decides -1 / 0 / +1 is PlayerInput.DEADZONE and is deliberately
## not duplicated here.
const PAD_NOISE_FLOOR := 0.12


## The three integers the simulation takes: steer, accel, jump — in that order,
## as Vector3i rather than a bare Array, because `inp[0]` at the call site said
## nothing about which of the three it was.
static func sample(control: int, touch_ui: bool, touch: TouchControls,
		viewport: Viewport) -> Vector3i:
	var pads := Input.get_connected_joypads()
	match PlayerInput.effective_device(control, pads.size(), touch_ui):
		PlayerInput.Device.TOUCH:
			# the on-screen stick has already done the thresholding, in
			# PlayerInput.from_axes, exactly as the joystick does
			return _triple(touch.sample() if touch != null else [0, 0, 0])
		PlayerInput.Device.JOYSTICK:
			return _joystick(pads[0])
		PlayerInput.Device.MOUSE:
			return _mouse(viewport)
		_:
			return _keyboard()


static func _triple(a: Array) -> Vector3i:
	return Vector3i(a[0], a[1], a[2])


## Stick or d-pad, whichever the player uses, and either face button to jump.
##
## The left stick is read through a noise floor because a resting pad still
## reports a few hundredths on both axes and the simulation only ever sees
## -1 / 0 / +1: without the floor a worn stick steers slowly and for ever.
## The d-pad OVERRIDES the stick rather than being summed with it, so resting a
## thumb on the stick cannot cancel a deliberate d-pad press.
##
## Both triggers and both shoulders jump as well. The original's joystick had
## two buttons and either of them jumped (`control` word 1, fn_0a4e); a modern
## pad has eight, and a player who presses the wrong one and does not jump
## reads it as the pad not working.
static func _joystick(pad: int) -> Vector3i:
	var jx := Input.get_joy_axis(pad, JOY_AXIS_LEFT_X)
	var jy := Input.get_joy_axis(pad, JOY_AXIS_LEFT_Y)
	if absf(jx) < PAD_NOISE_FLOOR:
		jx = 0.0
	if absf(jy) < PAD_NOISE_FLOOR:
		jy = 0.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_LEFT):
		jx = -1.0
	elif Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_RIGHT):
		jx = 1.0
	if Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_UP):
		jy = -1.0
	elif Input.is_joy_button_pressed(pad, JOY_BUTTON_DPAD_DOWN):
		jy = 1.0
	var jb := _jump_pressed(pad)
	return _triple(PlayerInput.from_axes(jx, jy, jb))


## Any of the pad's obvious "do it" controls.
static func _jump_pressed(pad: int) -> bool:
	for b in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y,
			JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		if Input.is_joy_button_pressed(pad, b):
			return true
	# the analogue triggers are axes, not buttons, and rest at -1 on some pads
	for ax in [JOY_AXIS_TRIGGER_LEFT, JOY_AXIS_TRIGGER_RIGHT]:
		if Input.get_joy_axis(pad, ax) > 0.5:
			return true
	return false


## Offset from the centre of the view, normalised — the DOS driver read an
## absolute position in a calibrated box, and this is the same idea without a
## sensitivity constant to invent: the ship goes where the pointer is relative
## to the middle of the screen.
static func _mouse(viewport: Viewport) -> Vector3i:
	var vp := viewport.get_visible_rect().size
	var half := vp * 0.5
	var off := viewport.get_mouse_position() - half
	var mb := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	return _triple(PlayerInput.from_axes(
		off.x / maxf(half.x, 1.0), off.y / maxf(half.y, 1.0), mb))


static func _keyboard() -> Vector3i:
	return _triple(PlayerInput.from_keys(
		Input.is_action_pressed("sr_left"),
		Input.is_action_pressed("sr_right"),
		Input.is_action_pressed("sr_up"),
		Input.is_action_pressed("sr_down"),
		Input.is_action_pressed("sr_home"),
		Input.is_action_pressed("sr_pgup"),
		Input.is_action_pressed("sr_end"),
		Input.is_action_pressed("sr_pgdn"),
		Input.is_action_pressed("sr_jump")))
