# The key mapping must be the original's, not an approximation.
#
# gameloop.md §10 / play.c sr_play_input:
#   steer = (right | pgup | pgdn) - (left | home | end)
#   accel = (up    | home | pgup) - (down | end  | pgdn)
#   jump  = space
#
# Home/PgUp/End/PgDn are each a single key meaning a diagonal. Dropping them
# forces three simultaneous keys for steer+throttle+jump, which plenty of
# keyboards silently refuse — and that reads as "I cannot jump while steering".
extends SceneTree

var _failures := 0
var _checks := 0


func check(cond: bool, label: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		print("FAIL  %s" % label)


func _init() -> void:
	Controls.install()
	for a in ["sr_up", "sr_down", "sr_left", "sr_right", "sr_home",
			"sr_pgup", "sr_end", "sr_pgdn", "sr_jump"]:
		check(InputMap.has_action(a), "action %s exists" % a)
		# has_action() is NOT enough: an action can exist with no events at
		# all, which is exactly how the game shipped with no controls while
		# this suite stayed green.
		var keys := 0
		for e in InputMap.action_get_events(a):
			if e is InputEventKey:
				keys += 1
		check(keys > 0, "action %s has at least one key bound (%d)" % [a, keys])

	# the combination itself, against the original's truth table
	var cases := [
		{"keys": ["sr_right"], "steer": 1, "accel": 0},
		{"keys": ["sr_left"], "steer": -1, "accel": 0},
		{"keys": ["sr_up"], "steer": 0, "accel": 1},
		{"keys": ["sr_down"], "steer": 0, "accel": -1},
		# the diagonals: one key, two effects
		{"keys": ["sr_home"], "steer": -1, "accel": 1},
		{"keys": ["sr_pgup"], "steer": 1, "accel": 1},
		{"keys": ["sr_end"], "steer": -1, "accel": -1},
		{"keys": ["sr_pgdn"], "steer": 1, "accel": -1},
		# opposites cancel, as the original's subtraction does
		{"keys": ["sr_left", "sr_right"], "steer": 0, "accel": 0},
		{"keys": ["sr_up", "sr_down"], "steer": 0, "accel": 0},
		# steering does not suppress the throttle
		{"keys": ["sr_right", "sr_up"], "steer": 1, "accel": 1},
	]
	for c in cases:
		var held: Dictionary = {}
		for k in c["keys"]:
			held[k] = true
		var right: bool = held.has("sr_right") or held.has("sr_pgup") or held.has("sr_pgdn")
		var left: bool = held.has("sr_left") or held.has("sr_home") or held.has("sr_end")
		var up: bool = held.has("sr_up") or held.has("sr_home") or held.has("sr_pgup")
		var down: bool = held.has("sr_down") or held.has("sr_end") or held.has("sr_pgdn")
		var steer: int = int(right) - int(left)
		var accel: int = int(up) - int(down)
		check(steer == c["steer"] and accel == c["accel"],
			"%s -> steer %d accel %d (got %d, %d)"
			% [c["keys"], c["steer"], c["accel"], steer, accel])

	# and jumping must be independent of steering in the simulation
	var road := RoadData.load_json("res://data/levels/road_01.json")
	if road != null:
		for steer2 in [-1, 0, 1]:
			var play := SkyRoadsPlay.new(road)
			var jumped := false
			for t in 40:
				play.set_input(steer2, 1, 1)
				play.step()
				if play.jumping:
					jumped = true
					break
			check(jumped, "the ship jumps with steer %d held" % steer2)

	_devices()

	print("Result: %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


## BUGS #12: the original offers keyboard, joystick and mouse, and the port
## wired only the keyboard. These cover the mapping for all three without a
## device attached, because PlayerInput is pure.
func _devices() -> void:
	# the keyboard's diagonals: ONE key means steer AND throttle
	var k := PlayerInput.from_keys(false, false, false, false,
		true, false, false, false, false)
	check(k == [-1, 1, 0], "Home steers left and throttles (got %s)" % [k])
	k = PlayerInput.from_keys(false, false, false, false,
		false, false, false, true, false)
	check(k == [1, -1, 0], "PgDn steers right and brakes (got %s)" % [k])
	k = PlayerInput.from_keys(true, true, true, true, false, false, false,
		false, true)
	check(k == [0, 0, 1], "opposite keys cancel, jump still registers")
	k = PlayerInput.from_keys(false, true, false, false, false, false,
		false, false, false)
	check(k == [1, 0, 0], "plain right steers without throttling")

	# analogue devices: joystick and mouse share one threshold
	var a := PlayerInput.from_axes(0.0, 0.0, false)
	check(a == [0, 0, 0], "a centred stick is neutral (got %s)" % [a])
	a = PlayerInput.from_axes(0.2, -0.2, false)
	check(a == [0, 0, 0], "small offsets stay inside the deadzone")
	a = PlayerInput.from_axes(1.0, -1.0, false)
	check(a == [1, 1, 0], "full up-right is steer right + throttle")
	a = PlayerInput.from_axes(-1.0, 1.0, true)
	check(a == [-1, -1, 1], "full down-left is steer left + brake, with jump")
	# pushing FORWARD must accelerate: both a stick's Y and a mouse offset are
	# positive downward, and getting that sign wrong inverts the throttle
	check(PlayerInput.from_axes(0.0, -1.0, false)[1] == 1,
		"forward on the stick accelerates, it does not brake")

	# device selection, including the ways a config can be wrong
	check(PlayerInput.effective_device(PlayerInput.Device.KEYBOARD, 0)
		== PlayerInput.Device.KEYBOARD, "keyboard is selected as keyboard")
	check(PlayerInput.effective_device(PlayerInput.Device.JOYSTICK, 1)
		== PlayerInput.Device.JOYSTICK, "a connected joystick is used")
	check(PlayerInput.effective_device(PlayerInput.Device.JOYSTICK, 0)
		== PlayerInput.Device.KEYBOARD,
		"an absent joystick falls back to the keyboard rather than to nothing")
	check(PlayerInput.effective_device(PlayerInput.Device.MOUSE, 0)
		== PlayerInput.Device.MOUSE, "the mouse needs nothing plugged in")
	check(PlayerInput.effective_device(99, 0) == PlayerInput.Device.KEYBOARD,
		"a corrupt control word still leaves the game playable")
