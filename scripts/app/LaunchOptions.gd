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
}

var mode: int = Mode.MENU
var road_index := 1

## Frame capture.
var shot_dir := ""
var shot_ticks: Array[int] = []
var shot_every := 0
var roadend_shot := false
var force_final := false
var menu_shot := ""

## Replay input.
var route_path := ""          ## an explicit file, absolute or res://
var route_suffix := ""        ## a named variant: --route crash -> _crash

## Debug overlays and capture-time behaviour.
var want_overlay := false
var want_labels := false
var autodump := false

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
			"--record":
				o.autodump = true
			"--collision-overlay":
				o.want_overlay = true
			"--labels":
				o.want_labels = true
			"--magenta-backdrop":
				pass                  # read directly by Backdrop
			_:
				if arg.begins_with("--"):
					o.unknown.append(arg)
		i += 2 if consumed else 1
	return o


## Where this run's replay input comes from. An explicit --route-file wins;
## otherwise it is the road's own recorded route, plus any --route variant.
func route_for(index: int) -> String:
	if not route_path.is_empty():
		return route_path
	return "res://data/routes/road_%02d%s.bin" % [index, route_suffix]


## True when the run is automated and must not fade, wait, or play the intro.
func is_automated() -> bool:
	return mode != Mode.MENU
