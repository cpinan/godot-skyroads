# The shell's state machine, with no scene tree attached.
#
# This is a direct transcription of game.c's tick_mainmenu / tick_gomenu /
# tick_setmenu / tick_help. It owns every navigation decision the shell makes;
# `Menu` is only the view that draws whatever state this holds. Keeping the
# two apart is what lets `test_menu.gd` drive this class with a scripted key
# sequence and diff it row for row against the C engine driven with the SAME
# sequence (tools/menu_trace.c), the way the physics is diffed.
#
# The original applies each pressed key with an INDEPENDENT `if`, not a chain
# of else-ifs, so a tick carrying two keys applies both in the order below.
# `step()` takes a set of keys for that reason: a chain would silently drop
# the second key and no test could tell.
class_name MenuModel
extends RefCounted

enum Screen { MAIN, GO, SETTINGS, HELP }
## Where the shell wants to go next. The view acts on these and clears them.
enum Exit { NONE, PLAY, DEMO, QUIT }

enum Key { UP, DOWN, LEFT, RIGHT, ENTER, JUMP, ESCAPE }

## game.c:200 — ten seconds of no input on the main menu starts the attract
## demo. Ticks, not seconds, because the original counts simulation ticks.
const ATTRACT_IDLE_TICKS := 36 * 10
const MAIN_ITEMS := 3
const ROAD_COUNT := 30
## The road-select grid is two columns of fifteen; left/right jumps a column.
const GO_COLUMN_STRIDE := 15
const SETTINGS_ITEMS := 5
## Items 0-2 pick the control device, 3-4 turn sound on/off (game.c:246-248).
const SETTINGS_SOUND_FIRST := 3

var screen: int = Screen.MAIN
var main_sel := 0
var go_sel := 0
var set_sel := 0
var help_page := 0
var help_pages := 3
var idle_ticks := 0

## Set by step(); the view consumes it and calls clear_exit().
var exit: int = Exit.NONE
## Road to start when exit == Exit.PLAY. 1-based: entry 0 is the attract demo.
var road_entry := 0
## Raised when the settings screen commits a change and the view must persist
## it. The model does not touch the filesystem.
var settings_dirty := false
var control := 0
var sound_off := false


func clear_exit() -> void:
	exit = Exit.NONE


## One shell tick with `keys` (an Array of Key) pressed on it. Returns true if
## anything observable changed, so a view can skip redrawing on idle ticks.
func step(keys: Array = []) -> bool:
	var before := _fingerprint()
	if keys.is_empty():
		idle_ticks += 1
	else:
		idle_ticks = 0
	match screen:
		Screen.MAIN: _step_main(keys)
		Screen.GO: _step_go(keys)
		Screen.SETTINGS: _step_settings(keys)
		Screen.HELP: _step_help(keys)
	return _fingerprint() != before


## Advance `n` idle ticks, for the view's real-time clock. Only the main menu
## counts them: game.c increments idle_ticks inside tick_mainmenu alone.
func advance(n: int) -> bool:
	var changed := false
	for _i in n:
		changed = step() or changed
		if exit != Exit.NONE:
			break
	return changed


func _fingerprint() -> Array:
	return [screen, main_sel, go_sel, set_sel, help_page, exit, road_entry]


func _step_main(keys: Array) -> void:
	if idle_ticks > ATTRACT_IDLE_TICKS:
		idle_ticks = 0
		exit = Exit.DEMO
		return
	if Key.DOWN in keys and main_sel < MAIN_ITEMS - 1:
		main_sel += 1
	if Key.UP in keys and main_sel > 0:
		main_sel -= 1
	if Key.ESCAPE in keys:
		exit = Exit.QUIT
	if _confirm(keys):
		# help always reopens on its first page (game.c:210-212 reaches the
		# help screen with help_page already reset by its own exit paths)
		help_page = 0
		screen = [Screen.GO, Screen.SETTINGS, Screen.HELP][main_sel]


func _step_go(keys: Array) -> void:
	if Key.DOWN in keys and go_sel < ROAD_COUNT - 1:
		go_sel += 1
	if Key.UP in keys and go_sel > 0:
		go_sel -= 1
	if Key.RIGHT in keys and go_sel < GO_COLUMN_STRIDE:
		go_sel += GO_COLUMN_STRIDE
	if Key.LEFT in keys and go_sel >= GO_COLUMN_STRIDE:
		go_sel -= GO_COLUMN_STRIDE
	if Key.ESCAPE in keys:
		screen = Screen.MAIN
	if _confirm(keys):
		road_entry = go_sel + 1        # entry 0 is the attract demo road
		exit = Exit.PLAY


func _step_settings(keys: Array) -> void:
	if Key.LEFT in keys and set_sel > 0:
		set_sel -= 1
	if Key.RIGHT in keys and set_sel < SETTINGS_ITEMS - 1:
		set_sel += 1
	if Key.UP in keys:
		# the two rows are not the same length, so the hop is a lookup, not
		# an offset (game.c:241-244)
		if set_sel == 3:
			set_sel = 0
		elif set_sel == 4:
			set_sel = 1
	if Key.DOWN in keys:
		if set_sel == 0:
			set_sel = 3
		elif set_sel < SETTINGS_SOUND_FIRST:
			set_sel = 4
	if _confirm(keys):
		if set_sel < SETTINGS_SOUND_FIRST:
			control = set_sel
		else:
			sound_off = set_sel == 4
		settings_dirty = true
	if Key.ESCAPE in keys:
		screen = Screen.MAIN


func _step_help(keys: Array) -> void:
	if _confirm(keys):
		help_page += 1
		if help_page >= help_pages:
			help_page = 0
			screen = Screen.MAIN
	if Key.ESCAPE in keys:
		help_page = 0
		screen = Screen.MAIN


## Enter and the jump key both confirm, everywhere (game.c: every tick_*
## tests SR_KEY_ENTER || SR_KEY_JUMP).
static func _confirm(keys: Array) -> bool:
	return Key.ENTER in keys or Key.JUMP in keys


## Godot keycode -> shell key, or -1 for a key the shell ignores.
static func key_from_event(keycode: int) -> int:
	match keycode:
		KEY_UP: return Key.UP
		KEY_DOWN: return Key.DOWN
		KEY_LEFT: return Key.LEFT
		KEY_RIGHT: return Key.RIGHT
		KEY_ENTER, KEY_KP_ENTER: return Key.ENTER
		KEY_SPACE: return Key.JUMP
		KEY_ESCAPE: return Key.ESCAPE
	return -1


## The letters tools/menu_trace.c scripts use, so a fixture recorded from the
## C engine can be replayed here unchanged.
static func key_from_letter(c: String) -> int:
	match c:
		"U": return Key.UP
		"D": return Key.DOWN
		"L": return Key.LEFT
		"R": return Key.RIGHT
		"E": return Key.ENTER
		"J": return Key.JUMP
		"X": return Key.ESCAPE
	return -1
