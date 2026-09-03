# The on-screen stick and buttons, driven by their own event handlers.
#
# `test_input.gd` covers the mapping from an axis pair to the simulation's
# three values, and `touch_shell.gd` covers whether a tap reaches the shell at
# all. What is left in between — and what this covers — is the geometry:
# which half of the screen a touch belongs to, where the stick's origin ends
# up, what a release does, and whether two thumbs work at once.
#
# The failures it is here for are the ones a phone would find and a desktop
# never would: a stick that keeps steering after the thumb lifts, a jump that
# cancels steering because both thumbs share one touch slot, and a pause box
# that a hard turn drags across.
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	var tc := TouchControls.new()
	get_root().add_child(tc)
	await process_frame

	check(tc.sample() == [0, 0, 0],
		"a stick nobody is touching produces nothing at all")

	# a press is not a deflection: the origin is where the thumb LANDS, so
	# the ship must not lurch toward wherever the art happens to be drawn
	_touch(tc, Vector2(60, 200), true)
	check(tc.sample() == [0, 0, 0], "a press alone does not steer")

	# 20 px of drag is past PlayerInput.DEADZONE at STICK_RANGE = 27
	_drag(tc, Vector2(80, 180))
	check(tc.sample() == [1, 1, 0],
		"dragging up and right steers right and throttles (%s)" % [tc.sample()])
	_drag(tc, Vector2(40, 220))
	check(tc.sample() == [-1, -1, 0],
		"dragging down and left steers left and brakes (%s)" % [tc.sample()])

	# release anywhere: the stick must recentre even though the release
	# position is nowhere near where the drag was
	_touch(tc, Vector2(40, 220), false)
	check(tc.sample() == [0, 0, 0], "releasing recentres the stick")

	# jump is the whole right half, not a button you have to find
	_touch(tc, Vector2(300, 40), true, 1)
	check(tc.jump_held() and tc.sample()[2] == 1,
		"a touch anywhere in the right half jumps")
	_touch(tc, Vector2(300, 40), false, 1)
	check(not tc.jump_held(), "and releasing it stops jumping")

	# two thumbs. A shared touch slot would show up exactly here: the jump
	# would arrive and the steer would vanish.
	_touch(tc, Vector2(60, 200), true, 0)
	_drag(tc, Vector2(90, 200), 0)
	_touch(tc, Vector2(280, 200), true, 1)
	check(tc.sample() == [1, 0, 1],
		"steering and jumping at the same time (%s)" % [tc.sample()])

	# a second touch in the left half must not steal the stick from the
	# thumb already holding it
	_touch(tc, Vector2(20, 60), true, 2)
	check(tc.sample()[0] == 1,
		"a stray second touch on the left does not hijack the stick")
	_touch(tc, Vector2(20, 60), false, 2)
	_touch(tc, Vector2(90, 200), false, 0)
	_touch(tc, Vector2(280, 200), false, 1)
	check(tc.sample() == [0, 0, 0], "everything released, everything zero")

	# the pause box: fires its callback, and is NOT the stick
	var paused := [0]
	tc.on_pause = func() -> void: paused[0] += 1
	_touch(tc, TouchControls.PAUSE_RECT.get_center(), true, 0)
	check(paused[0] == 1, "the pause box fires its callback")
	check(tc.sample() == [0, 0, 0],
		"and does not also register as a stick touch")

	tc.queue_free()
	await process_frame
	await _fixed_origin_stick()
	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## --fixed-stick: the origin is the drawn circle, not the thumb.
##
## The two modes have to differ on the SAME gesture or the flag does nothing,
## so this presses in exactly the place the floating stick treats as neutral
## (60, 200) and requires a deflection out of it. STICK_CENTRE is (40, 196),
## so that press is 20 px right of the anchor — past PlayerInput.DEADZONE at
## STICK_RANGE 27, and the ship should already be turning.
func _fixed_origin_stick() -> void:
	var tc := TouchControls.new()
	tc.fixed_origin = true
	get_root().add_child(tc)
	await process_frame

	_touch(tc, Vector2(60, 200), true)
	check(tc.sample()[0] == 1,
		"a fixed stick steers from where the thumb lands (%s)" % [tc.sample()])
	_touch(tc, Vector2(60, 200), false)
	check(tc.sample() == [0, 0, 0], "and still recentres on release")

	# and the flag must not leak: the same gesture on a floating stick is
	# neutral, which is the check at the top of _init and is asserted again
	# here so the two live side by side
	var floating := TouchControls.new()
	get_root().add_child(floating)
	await process_frame
	_touch(floating, Vector2(60, 200), true)
	check(floating.sample() == [0, 0, 0],
		"a floating stick treats the same press as neutral")
	_touch(floating, Vector2(60, 200), false)

	tc.queue_free()
	floating.queue_free()
	await process_frame


## The handlers take window coordinates, the same as a real event; the tests
## think in the game's 320x240 canvas space.
func _touch(tc: TouchControls, p: Vector2, pressed: bool, idx := 0) -> void:
	tc._touch(idx, tc._draw_node.get_global_transform() * p, pressed)


func _drag(tc: TouchControls, p: Vector2, idx := 0) -> void:
	tc._drag(idx, tc._draw_node.get_global_transform() * p)
