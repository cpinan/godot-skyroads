# The original's key map, defined in code.
#
# gameloop.md §10 (scancode cells at ds:0xba2) lists eleven keys:
#
#   up down left right   home pgup end pgdn   ESC space P
#
# Home/PgUp/End/PgDn are each a SINGLE key meaning a diagonal, so steering
# while accelerating and jumping takes two keys rather than three. That
# matters: many keyboards cannot report three simultaneous presses, and Mac
# laptops have no Home/End/PgUp/PgDn at all — hence the QEZX aliases.
#
# This is built at runtime rather than stored in project.godot because an
# edit to that file was silently dropped on import, leaving every action
# defined but bound to nothing: the game had no controls and the test that
# was supposed to catch it only asserted the actions existed.
class_name Controls
extends RefCounted

## action -> the keys that trigger it
const MAP := {
	"sr_up":    [KEY_UP],
	"sr_down":  [KEY_DOWN],
	"sr_left":  [KEY_LEFT],
	"sr_right": [KEY_RIGHT],
	"sr_home":  [KEY_HOME, KEY_Q],      # left + accelerate
	"sr_pgup":  [KEY_PAGEUP, KEY_E],    # right + accelerate
	"sr_end":   [KEY_END, KEY_Z],       # left + brake
	"sr_pgdn":  [KEY_PAGEDOWN, KEY_X],  # right + brake
	"sr_jump":  [KEY_SPACE],
	"sr_pause": [KEY_P],
}


static func install() -> void:
	for action in MAP:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for key in MAP[action]:
			var already := false
			for e in InputMap.action_get_events(action):
				if e is InputEventKey and (e as InputEventKey).keycode == key:
					already = true
			if already:
				continue
			var ev := InputEventKey.new()
			ev.keycode = key
			InputMap.action_add_event(action, ev)


## Human-readable list, for a controls screen or a bug report.
static func describe() -> Array:
	var out: Array = []
	for action in MAP:
		var names: Array = []
		for key in MAP[action]:
			names.append(OS.get_keycode_string(key))
		out.append([action, names])
	return out
