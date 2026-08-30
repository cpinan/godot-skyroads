# Drives SkyRoadsPlay at the original's fixed rate and nothing else.
#
# The original reprograms PIT channel 0 to 180.018 Hz and advances the game on
# 2 of every 10 interrupts, giving exactly 1193182 / (6628*5) = 36.0036 Hz.
# That rate is not a detail: jump arcs, the bounce, the edge slide and the
# landing assist are all tuned to a tick of that length.
#
# So the simulation runs from a rational accumulator, never from `delta`, and
# rendering interpolates between ticks instead of stepping with the frame.
class_name GameLoop
extends Node

signal ticked(play: SkyRoadsPlay, result: int)
signal finished(result: int)

## The original catches up unbounded (gameloop.md §3, 0x2ae1). 36 ticks — a
## full second of simulation per rendered frame — covers any real hitch while
## still bounding a debugger pause.
const MAX_CATCHUP_TICKS := 36

var play: SkyRoadsPlay
var running := false
var last_result := SkyRoadsPlay.RUNNING

## Frozen by the shell for the pause screen and during fade-outs. The
## accumulator stops too, so no tick debt builds up while frozen.
var paused := false

## The ship state as it was before the most recent tick. Presentation
## interpolates between this and the current state so motion is smooth at any
## refresh rate — the SIMULATION never reads these back, or the fixed step
## would stop being fixed.
var prev_z := 0
var prev_x := 0
var prev_y := 0

## Every input the player has given, one entry per tick. Lets a session be
## dumped and replayed exactly, which turns "it felt wrong there" into a test.
var recording: PackedByteArray

# accumulator in units of TICK_DEN, so the rate stays exact with no float drift
var _acc := 0
var _alpha := 0.0

# input latched by the shell each frame
var steer := 0
var accel := 0
var jump := 0


func start(road: RoadData) -> void:
	play = SkyRoadsPlay.new(road)
	prev_z = play.z
	prev_x = play.x
	prev_y = play.y
	recording = PackedByteArray()
	_acc = 0
	_alpha = 0.0
	running = true
	last_result = SkyRoadsPlay.RUNNING


## Fraction of the way to the next tick, for interpolating the visuals.
func interpolation() -> float:
	return _alpha


## Position for rendering: the state the simulation is actually IN, carried
## forward by however far through the NEXT tick real time has already got.
##
## Interpolating between the previous tick and the current one instead —
## which is what this did — presents a state a whole tick old whenever the
## accumulator has just fired, and the original has no such delay: render.c
## draws p->z / p->x / p->y as they stand. Measured against the C engine on
## the user's road-2 recording, the lag put the road's near edge 11 screen
## rows too high and doubled the strip of backdrop showing under it.
##
## Carrying forward is safe precisely where overshoot would matter: a ship
## that has hit something has prev == play for that axis, so the term is
## zero and nothing is predicted past the impact.
func view_row() -> float:
	var a := _alpha
	return (float(play.z) + (float(play.z) - float(prev_z)) * a) / 65536.0


func view_x() -> int:
	return int(round(float(play.x) + (float(play.x) - float(prev_x)) * _alpha))


func view_y() -> int:
	return int(round(float(play.y) + (float(play.y) - float(prev_y)) * _alpha))


## Present the simulated state exactly, with no carry-forward. Used by the
## capture path so a screenshot corresponds to one tick rather than to a
## moment between two.
func _process(delta: float) -> void:
	if not running or paused:
		return
	# delta is used ONLY to decide how many fixed ticks are due — never to
	# scale anything the simulation reads
	_acc += int(round(delta * SkyRoads.TICK_NUM))
	var budget := MAX_CATCHUP_TICKS
	var per_tick := SkyRoads.TICK_DEN
	while _acc >= per_tick and budget > 0:
		_acc -= per_tick
		budget -= 1
		prev_z = play.z
		prev_x = play.x
		prev_y = play.y
		recording.append(steer + 1)
		recording.append(accel + 1)
		recording.append(jump)
		play.set_input(steer, accel, jump)
		last_result = play.step()
		ticked.emit(play, last_result)
		if last_result != SkyRoadsPlay.RUNNING:
			running = false
			finished.emit(last_result)
			return
	if _acc > per_tick:
		# leftover debt beyond the budget is dropped, so _alpha stays in
		# [0,1] and presentation never extrapolates past the simulated state
		_acc = per_tick
	_alpha = float(_acc) / float(per_tick)
