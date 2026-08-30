# What the dashboard READS, with no drawing attached.
#
# Every number the dashboard shows is derived from the simulation by a rule in
# hud.c (sr_hud_draw). Those rules live here so they can be checked against the
# C engine directly — `test_hud.gd` asserts them at their boundaries, where an
# off-by-one is invisible on screen but wrong. `Dashboard` is then only the
# view: it asks this class for counts and stamps the art.
class_name HudModel
extends RefCounted

## hud.c:70 — one speedometer segment per 0x141 units of speed, 34 of them.
const SPEEDO_SEGMENTS := 34
const SPEEDO_UNITS_PER_SEG := 0x141
## hud.c:78 — oxygen and fuel are ceil(qty / 0xBB8), ten segments each.
const GAUGE_SEGMENTS := 10
const GAUGE_UNITS_PER_SEG := 0xBB8
## hud.c:92 — thirty progress columns spanning the road from the spawn row.
const PROGRESS_STEPS := 30
const Z_START_ROW := 3
## hud.c:120 — the readout is (gravity - 3) * 100, four digits.
const GRAVITY_DIGITS := 4
const GRAVITY_BASE := 3
const GRAVITY_SCALE := 100
## The empty-tank lamp blinks with a 9-tick period, lit on the last four.
const WARN_PERIOD := 9
const WARN_LIT_FROM := 5


## Lit speedometer segments. The autopilot's correction is SUBTRACTED before
## the division: the assist is meant to be invisible, and showing the true
## speed would give it away (hud.c:68-69).
static func speed_segments(speed: int, ap_delta: int) -> int:
	var shown := maxi(speed - ap_delta, 0)
	return mini(shown / SPEEDO_UNITS_PER_SEG, SPEEDO_SEGMENTS)


## Lit segments of an oxygen or fuel gauge. Rounded UP, so a tank with one
## unit left still shows one bar rather than reading empty (hud.c:78-79).
static func gauge_segments(qty: int) -> int:
	if qty <= 0:
		return 0
	return mini((qty + GAUGE_UNITS_PER_SEG - 1) / GAUGE_UNITS_PER_SEG,
		GAUGE_SEGMENTS)


## Filled progress columns. The bar measures from the spawn row to the last
## row, so a road shorter than the spawn offset has no progress at all
## (hud.c:92-97).
static func progress_steps(z: int, rows: int) -> int:
	if rows <= Z_START_ROW:
		return 0
	var denom: int = ((rows - Z_START_ROW) << 16) / PROGRESS_STEPS
	if denom <= 0:
		return 0
	var steps: int = (z - (Z_START_ROW << 16)) / denom
	return clampi(steps, 0, PROGRESS_STEPS - 1)


## The GRAV-O-METER's four-digit value.
static func gravity_value(gravity: int) -> int:
	return maxi((gravity - GRAVITY_BASE) * GRAVITY_SCALE, 0)


## The digits of `value`, least significant first, with leading zeros
## suppressed the way hud.c:123-129 does: it stops as soon as the remaining
## quotient is zero, so 0 still prints a single "0".
static func gravity_digits(value: int) -> Array[int]:
	var out: Array[int] = []
	var div := 1
	for _i in GRAVITY_DIGITS:
		out.append((value / div) % 10)
		if value / div / 10 == 0:
			break
		div *= 10
	return out


## Whether an empty-tank warning lamp is lit on this tick.
static func warn_lit(tick: int) -> bool:
	return (tick % WARN_PERIOD) >= WARN_LIT_FROM
