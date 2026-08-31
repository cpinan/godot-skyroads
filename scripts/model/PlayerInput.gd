# Steering, throttle and jump, whichever device they came from.
#
# The original offers three input devices (skyroads.cfg's `control` word: 0
# keyboard, 1 joystick, 2 mouse) and the settings screen already let the
# player pick one, but only the keyboard was ever wired here — BUGS #12.
#
# All three collapse to the same three values the simulation takes:
#
#   steer  -1 left, 0, +1 right
#   accel  -1 brake, 0, +1 throttle
#   jump   0 or 1
#
# so the device-specific part is only how those are sampled. The keyboard has
# its own shape because of the original's diagonal keys; joystick and mouse
# are both an analogue pair plus a button and share one threshold, which is
# what `from_axes` is. Everything here is pure — no Input, no nodes — so
# test_input.gd can cover every device without one attached.
class_name PlayerInput
extends RefCounted

## 0-2 are the original's own `control` word and are the only values that are
## ever written to skyroads.cfg. TOUCH is this port's addition for phones: it
## is chosen by the platform, never by the settings screen, and never stored —
## a 3 in the cfg file would not be a SkyRoads save any more.
enum Device { KEYBOARD = 0, JOYSTICK = 1, MOUSE = 2, TOUCH = 3 }

## Past this far from centre an analogue device counts as pushed. Generous,
## because the result is a digital -1/0/+1 and the simulation samples it at
## 36 Hz: a low threshold would make a resting stick chatter between values.
const DEADZONE := 0.45


## Keyboard, including the original's four diagonal keys. Home/PgUp/End/PgDn
## are each a SINGLE key meaning "steer AND throttle", so steering while
## accelerating takes two keys rather than three (gameloop.md §10) — which
## matters on keyboards that cannot report three at once.
static func from_keys(left: bool, right: bool, up: bool, down: bool,
		home: bool, pgup: bool, end_: bool, pgdn: bool, jump: bool) -> Array:
	var l := left or home or end_
	var r := right or pgup or pgdn
	var u := up or home or pgup
	var d := down or end_ or pgdn
	return [int(r) - int(l), int(u) - int(d), 1 if jump else 0]


## Joystick or mouse: an analogue pair plus a button, thresholded.
##
## `y` is screen-style, positive DOWNWARD, because that is what both a
## joystick's vertical axis and a mouse offset report; pushing forward (up)
## means throttle, so the sign flips here rather than at each call site.
static func from_axes(x: float, y: float, jump: bool,
		deadzone := DEADZONE) -> Array:
	var steer := 0
	if x > deadzone:
		steer = 1
	elif x < -deadzone:
		steer = -1
	var accel := 0
	if y < -deadzone:
		accel = 1
	elif y > deadzone:
		accel = -1
	return [steer, accel, 1 if jump else 0]


## Which device to actually read. The config may name one that is not
## plugged in — the original would simply leave the player unable to steer,
## which is not a useful thing to reproduce, so an absent joystick falls back
## to the keyboard.
##
## `touch` wins over everything. On a phone there is no keyboard to fall back
## to and no mouse to find, so whatever the cfg file inherited from a desktop
## save is irrelevant; this is also why the settings screen hides the control
## row there (Menu.touch_ui) rather than offering three dead choices.
static func effective_device(control: int, joypads: int,
		touch := false) -> int:
	if touch:
		return Device.TOUCH
	if control == Device.JOYSTICK and joypads <= 0:
		return Device.KEYBOARD
	if control < Device.KEYBOARD or control > Device.MOUSE:
		return Device.KEYBOARD          # a corrupt config still plays
	return control
