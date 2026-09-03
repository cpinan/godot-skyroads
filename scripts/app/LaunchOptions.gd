# The command line, parsed once into a value object.
#
# Main used to hold seventeen loose fields and a match statement that both
# read the arguments AND decided what to do about them, so "what can this
# binary be asked to do?" could only be answered by reading the whole shell.
# Parsing is separated here because it is pure: it takes strings and returns
# a struct, which is what lets test_launch_options.gd cover every flag —
# including the malformed ones, where a flag at the end of the line has no
# value after it.
class_name LaunchOptions
extends RefCounted

## What the process was started to do.
enum Mode {
	MENU,        ## normal boot: intro, then the menu
	PLAY,        ## --road N: straight into a road
	REPLAY,      ## --replay N: drive a road from a recorded route
	MENU_SHOT,   ## --menu-shot: capture menu screens and exit
	EDITOR,      ## --editor: the road editor, which is not on any menu
}

## The interpolation fraction a parity capture is taken at: 0.0 is the state
## exactly on the tick, which is what the reference draws a frame FOR. Set
## from the sweep in BUGS §12.3; negative restores the old behaviour, which
## was "whatever fraction the frame that noticed the tick happened to be at".
const SHOT_ALPHA_DEFAULT := 0.0

var mode: int = Mode.MENU
var road_index := 1

## Frame capture.
var shot_dir := ""
var shot_ticks: Array[int] = []
var shot_every := 0
## Where inside the tick the capture is taken, 0.0 = on the tick, 1.0 = a
## whole tick later. Negative means "wherever the frame happened to land",
## which is what every capture did before it was measured — see BUGS #29b.
var shot_alpha := SHOT_ALPHA_DEFAULT
var roadend_shot := false
var force_final := false
var menu_shot := ""

## The road editor. Not reachable from a menu — see scripts/RoadEditor.gd for
## why — so the flag is the whole of its front door.
var editor_name := "custom"
## Play a road from an arbitrary JSON instead of `data/levels/road_NN.json`.
## What the editor's play-test uses, and what makes a user:// road drivable
## without pretending to be one of the shipped thirty.
var level_path := ""

## Replay input.
var route_path := ""          ## an explicit file, absolute or res://
var route_suffix := ""        ## a named variant: --route crash -> _crash

## Debug overlays and capture-time behaviour.
var want_overlay := false
var want_labels := false
var autodump := false
## Reproduce the original's own defects even where the port normally works
## around them. Implied by every capture mode; see is_parity_capture().
var authentic := false
## Force the on-screen touch controls on a desktop build, so the mobile HUD
## can be driven and screenshotted without a phone.
var force_touch := false
## Anchor the thumbstick to its drawn circle instead of letting it follow the
## thumb that starts the touch. A flag rather than a setting because which one
## is better has not been decided on hardware yet (docs/PLAN.md item 1), and a
## flag can be A/B'd in one session without changing the cfg format.
var fixed_stick := false
## Capture a surface-ID map beside every frame: which RECORD painted each
## pixel, in the reference's own numbering. The only way to ask which surface
## is wrong, since a road's palette can hold exact duplicates (BUGS §12.14).
var surface_ids := false

## Arguments that were not understood, for the caller to report.
var unknown: Array[String] = []


static func parse(args: PackedStringArray) -> LaunchOptions:
	var o := LaunchOptions.new()
	var i := 0
	while i < args.size():
		var arg := args[i]
		# A flag needing a value that has none is ignored rather than
		# crashing: an automated run should say what it did not understand,
		# not die on a truncated command line. The NEXT FLAG is not a value —
		# without that test, `--shot-ticks --labels` parsed "--labels" as a
		# tick list of one zero and then never enabled the labels.
		var value := ""
		if i + 1 < args.size() and not args[i + 1].begins_with("--"):
			value = args[i + 1]
		var consumed := false
		match arg:
			"--road", "--replay":
				if not value.is_empty():
					o.road_index = int(value)
					o.mode = Mode.REPLAY if arg == "--replay" else Mode.PLAY
					consumed = true
			"--shots":
				if not value.is_empty():
					o.shot_dir = value
					consumed = true
			"--shot-ticks":
				if not value.is_empty():
					for s in value.split(",", false):
						o.shot_ticks.append(int(s))
					consumed = true
			"--shot-every":
				if not value.is_empty():
					o.shot_every = int(value)
					consumed = true
			"--route-file":
				if not value.is_empty():
					o.route_path = value
					consumed = true
			"--route":
				if not value.is_empty():
					o.route_suffix = "_" + value
					consumed = true
			"--menu-shot":
				if not value.is_empty():
					o.menu_shot = value
					o.mode = Mode.MENU_SHOT
					consumed = true
			"--roadend-shot":
				o.roadend_shot = true
			"--final-shot":
				o.roadend_shot = true
				o.force_final = true
			"--shot-alpha":
				if not value.is_empty():
					o.shot_alpha = value.to_float()
					consumed = true
			"--record":
				o.autodump = true
			"--collision-overlay":
				o.want_overlay = true
			"--labels":
				o.want_labels = true
			"--authentic":
				o.authentic = true
			"--touch":
				o.force_touch = true
			"--fixed-stick":
				o.fixed_stick = true
			"--surface-ids":
				o.surface_ids = true
			"--editor":
				o.mode = Mode.EDITOR
				if not value.is_empty():
					o.editor_name = value
					consumed = true
			"--level-file":
				if not value.is_empty():
					o.level_path = value
					consumed = true
			"--magenta-backdrop":
				pass                  # read directly by Backdrop
			_:
				if arg.begins_with("--"):
					o.unknown.append(arg)
		i += 2 if consumed else 1
	return o


## Which file holds the road for `index`. An explicit --level-file wins, which
## is how a road in user:// is played; otherwise it is the shipped one.
func level_for(index: int) -> String:
	if not level_path.is_empty():
		return level_path
	return "res://data/levels/road_%02d.json" % index


## Where this run's replay input comes from. An explicit --route-file wins;
## otherwise it is the road's own recorded route, plus any --route variant.
func route_for(index: int) -> String:
	if not route_path.is_empty():
		return route_path
	return "res://data/routes/road_%02d%s.bin" % [index, route_suffix]


## True when the run is automated and must not fade, wait, or play the intro.
## The editor is not automated in that sense — a person is driving it — but it
## does replace the intro, so it is listed here rather than left to fall
## through to "boot normally".
func is_automated() -> bool:
	return mode != Mode.MENU


## True when this run's frames are being compared against the C reference.
## Every deliberate deviation from the original — there is exactly one, the
## readable GRAV-O-METER of BUGS #41 — must be switched off here, or the
## pixel suites measure the deviation instead of the renderer. `--authentic`
## forces the same thing for a run a human is watching.
func is_parity_capture() -> bool:
	return authentic or not shot_dir.is_empty() or not menu_shot.is_empty()
