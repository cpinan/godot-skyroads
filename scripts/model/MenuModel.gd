# The shell's state machine, with no scene tree attached.
#
# Originally a transcription of game.c's tick_mainmenu / tick_gomenu /
# tick_setmenu / tick_help. Four of its rules were WRONG because game.c was
# wrong — see BUGS §11.8-11.11 — and those now follow SKYROADS.EXE instead,
# each with the address it came from. It owns every navigation decision the
# shell makes;
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
##
## There is no DEMO exit. The attract demo is not reachable from any menu in
## the retail binary — the menus block on `int 21h ah=7` (fn_5fad) and cannot
## time out. It is reached by letting the INTRO finish untouched; see
## BUGS §11.11 and Main._end_intro.
enum Exit { NONE, PLAY, QUIT }

enum Key { UP, DOWN, LEFT, RIGHT, ENTER, JUMP, ESCAPE }

const MAIN_ITEMS := 3
const ROAD_COUNT := 30
## The road-select grid is two columns of fifteen; left/right jumps a column.
const GO_COLUMN_STRIDE := 15
const SETTINGS_ITEMS := 5
## Help screens the original actually displays — see `help_pages`.
const HELP_PAGES := 2
## Items 0-2 pick the control device, 3-4 turn sound on/off (game.c:246-248).
const SETTINGS_SOUND_FIRST := 3

var screen: int = Screen.MAIN
var main_sel := 0
var go_sel := 0
var set_sel := 0
var help_page := 0
## Two, not three. fn_4e12 @0x4e21 calls the one-page routine fn_4dac, and
## calls it a second time only when the key was not ESC — then returns. The
## retail HELPMENU.LZS holds three full screens; the third is never shown.
## `Menu` still takes the smaller of this and the pict count, so a data file
## with fewer pages cannot page off the end.
var help_pages := HELP_PAGES

## Set by step(); the view consumes it and calls clear_exit().
var exit: int = Exit.NONE
## Road to start when exit == Exit.PLAY. 1-based: entry 0 is the attract demo.
var road_entry := 0
## Raised when the settings screen commits a change and the view must persist
## it. The model does not touch the filesystem.
var settings_dirty := false
var control := 0
var sound_off := false
## On a phone the control device is decided by the hardware, so the settings
## screen's first three items — keyboard, joystick, mouse — would be three
## ways of choosing something that cannot take effect. With this set the
## cursor cannot reach them and the view greys them out; the sound row is
## unchanged. Off everywhere else, so test_menu.gd still diffs this class
## against the C engine's traces unmodified.
var touch_ui := false


func clear_exit() -> void:
	exit = Exit.NONE


## Lowest settings item the cursor may land on. The whole of `touch_ui`'s
## effect on navigation is this one number; the view asks the same question
## to decide what to grey out, so the two can never disagree.
func settings_first_item() -> int:
	return SETTINGS_SOUND_FIRST if touch_ui else 0


## One shell tick with `keys` (an Array of Key) pressed on it. Returns true if
## anything observable changed, so a view can skip redrawing on idle ticks.
func step(keys: Array = []) -> bool:
	var before := _fingerprint()
	match screen:
		Screen.MAIN: _step_main(keys)
		Screen.GO: _step_go(keys)
		Screen.SETTINGS: _step_settings(keys)
		Screen.HELP: _step_help(keys)
	return _fingerprint() != before


func _fingerprint() -> Array:
	return [screen, main_sel, go_sel, set_sel, help_page, exit, road_entry]


func _step_main(keys: Array) -> void:
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


## fn_5164 @0x52cb-0x5305, with the clamp at the top of its loop (@0x527f
## `if sel >= 30: sel = 29`). Left and right are NOT the guarded moves the C
## reference makes them: the original slides you to the end of the list rather
## than refusing (BUGS §11.8, §11.9).
func _step_go(keys: Array) -> void:
	if Key.DOWN in keys:
		go_sel += 1                                    # @0x5300
	if Key.UP in keys and go_sel > 0:
		go_sel -= 1                                    # @0x52ee
	if Key.RIGHT in keys:
		go_sel += GO_COLUMN_STRIDE                     # @0x52e6
	if Key.LEFT in keys:
		# @0x52cb: a whole column back, or to the very first road
		go_sel = go_sel - GO_COLUMN_STRIDE if go_sel >= GO_COLUMN_STRIDE else 0
	if go_sel >= ROAD_COUNT:
		go_sel = ROAD_COUNT - 1                        # @0x527f
	if Key.ESCAPE in keys:
		screen = Screen.MAIN
	if _confirm(keys):
		road_entry = go_sel + 1        # entry 0 is the attract demo road
		exit = Exit.PLAY


func _step_settings(keys: Array) -> void:
	var first := settings_first_item()
	if set_sel < first:
		# entered from a save made on a desktop; start on the item that
		# reflects the setting the player can still change
		set_sel = 4 if sound_off else 3
	if Key.LEFT in keys and set_sel > first:
		set_sel -= 1
	if Key.RIGHT in keys and set_sel < SETTINGS_ITEMS - 1:
		set_sel += 1
	if not touch_ui:
		if Key.UP in keys:
			# the two rows are not the same length, so the hop is a lookup,
			# not an offset (game.c:241-244)
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


## The help screen is a blocking getkey and a test for ESC (fn_4dac @0x4de8,
## `if si == 0x1b` @0x4dfa), so ANY other key turns the page — not just Enter.
func _step_help(keys: Array) -> void:
	if Key.ESCAPE in keys:
		help_page = 0
		screen = Screen.MAIN
		return
	if not keys.is_empty():
		help_page += 1
		if help_page >= help_pages:
			help_page = 0
			screen = Screen.MAIN


## Enter, and only Enter. Every menu in the retail binary dispatches on the
## BIOS scancode word and tests 0x0D and 0x1B and the four arrows and nothing
## else — main menu @0x5037, road select @0x531b, settings @0x4d6c. Space does
## not confirm anywhere; the C reference's `SR_KEY_ENTER || SR_KEY_JUMP` is an
## addition (BUGS §11.10). The help screen is the exception and has its own
## rule, in _step_help.
static func _confirm(keys: Array) -> bool:
	return Key.ENTER in keys


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
