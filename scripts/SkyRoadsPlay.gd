# The gameplay simulation — a direct port of SKYROADS.EXE fn_1f2c by way of
# skyroads-port/src/core/play.c.
#
# This is THE simulation. Rendering, the HUD, an AI, a replay checker: they all
# drive this one class. Two copies of gameplay always drift, and the drift
# shows up as "the game feels wrong" rather than as a bug.
#
# Three rules that must survive any refactor:
#
#  1. It steps at a FIXED 36.0036 Hz and never reads `delta`. Every constant
#     below is per-tick. Scaling anything by frame time changes the jump arcs,
#     the bounce and the landing assist.
#  2. Everything is integer, in the original's units. X and Y are 16-bit and
#     wrap; Z is 32-bit. The helpers below do that masking and nothing here may
#     skip them.
#  3. GDScript integer division truncates toward zero, exactly like the C it
#     came from (verified: -7/2 == -3 in both). So plain `/` is correct here —
#     do not "fix" it to floor division or floats.
class_name SkyRoadsPlay
extends RefCounted

const RUNNING := -1
const COMPLETE := 0
const WALL := 1
const BURNED := 2
const FELL := 3
const NO_FUEL := 4
const NO_OXYGEN := 5
const QUIT := 7

var road: RoadData

# ship state, in the original's units
var x := SkyRoads.X_START
var y := SkyRoads.Y_DECK
var z := SkyRoads.Z_START_ROW << 16
var speed := 0
var yvel := 0
var xvel := 0
var side_push := 0
var last_new_y := SkyRoads.Y_DECK
var fuel := SkyRoads.TANK_FULL
var oxy := SkyRoads.TANK_FULL

# input for the current tick
var steer := 0
var accel := 0
var jumpkey := 0

# flags and counters
var end_state := 0
var expl_ctr := 0
var end_frames := 0
var jumping := 0
var jump_start_y := 0
var on_ground := 0
var on_ice := 0
var on_sticky := 0
var over_hole := 0
var tile_code := 0
var edge_dist := 0
var ap_done := 0
var ap_delta := 0
var ap_light := 0
var autopilot_on := 1
var tick := 0
var fly_ticks := 0
var pending_sfx := 0
var sfx_tick := 0
var grav_accel := 0


func _init(road_data: RoadData) -> void:
	road = road_data
	grav_accel = -((road.gravity * SkyRoads.GRAV_MUL) / SkyRoads.GRAV_DIV)


# --- 16/32-bit wrapping, because the original's variables are that wide ----
static func u16(v: int) -> int:
	return v & 0xFFFF


static func u32(v: int) -> int:
	return v & 0xFFFFFFFF


static func s16(v: int) -> int:
	v &= 0xFFFF
	return v - 0x10000 if v & 0x8000 else v


static func s32(v: int) -> int:
	v &= 0xFFFFFFFF
	return v - 0x100000000 if v & 0x80000000 else v


# --- queries (fn_04c0 / fn_1584 / fn_1685 / fn_0533) -----------------------
func tile_at(zz: int, xx: int) -> int:
	var col := u16(xx / 0x80 - 0x5F)
	if col >= 0x142:
		return 0
	var row := (zz >> 16) & 0xFFFF
	if row >= SkyRoads.MAX_ROWS or row >= road.rows:
		return 0
	return road.cells[row * 7 + col / 0x2E]


static func solid_block(tile: int, t: int, yy: int) -> bool:
	if u16(t) > 0x25:
		return false
	# EXE 0x159b: the profile row index is UNSIGNED, so a y below 0x2200 wraps
	# to a huge index rather than going negative. That is load-bearing.
	var di := u16(yy + 0xDE00) / 0x80
	match tile & 0xF00:
		0x100:
			return di >= SkyRoads.TUN_INNER[t] and di < SkyRoads.TUN_OUTER[t]
		0x200:
			return yy < SkyRoads.Y_HALF
		0x300:
			return yy < SkyRoads.Y_HALF and di >= SkyRoads.TUN_INNER[t]
		0x400:
			return yy < SkyRoads.Y_FULL
		0x500:
			return yy < SkyRoads.Y_FULL and di >= SkyRoads.TUN_INNER[t]
	return false


func solid(zz: int, xx: int, yy: int) -> bool:
	var right := tile_at(zz, u16(xx + SkyRoads.SHIP_HALF_W))
	var left := tile_at(zz, u16(xx - SkyRoads.SHIP_HALF_W))
	if (right | left) & 0xF:
		if yy < SkyRoads.Y_DECK and u16(yy + 0x600) > 0x2480:
			return true
	if u16(yy + 0x680) <= SkyRoads.Y_DECK:
		return false
	if not (left & 0xF00) and not (right & 0xF00):
		return false
	var center := tile_at(zz, xx)
	var t := s16(0x17 - ((xx / 0x80 - 0x31) % 0x2E))
	var xoff := -0x1700
	if t <= 0:
		t = 1 - t
		xoff = 0x1700
	if solid_block(center, t, yy):
		return true
	return solid_block(tile_at(zz, u16(xx + xoff)), 0x2F - t, yy)


func in_tunnel(zz: int, xx: int, yy: int) -> bool:
	var tile := tile_at(zz, xx)
	var bt := tile & 0xF00
	if bt != 0x100 and bt != 0x300 and bt != 0x500:
		return false
	var t := s16(0x17 - ((xx / 0x80 - 0x31) % 0x2E))
	if t <= 0:
		t = 1 - t
	if t > 0x25:
		return false
	var di := u16(yy + 0xDE00) / 0x80
	return di < (SkyRoads.TUN_OUTER[t] + SkyRoads.TUN_INNER[t]) / 2


# --- swept move (fn_17be) --------------------------------------------------
func _swept_move(nz: int, nx: int, ny: int) -> void:
	if nz == z and nx == x and ny == y:
		return
	var dz := s32(nz - z)
	var dx := s16(nx - x)
	var dy := s16(ny - y)

	var si := 1
	while si <= 5:
		var tz := u32(z + dz * si / 5)
		var tx := u16(x + dx * si / 5)
		var ty := u16(y + dy * si / 5)
		if solid(tz, tx, ty):
			break
		si += 1
	var safe := si - 1
	z = u32(z + dz * safe / 5)
	x = u16(x + dx * safe / 5)
	y = u16(y + dy * safe / 5)
	if si > 5:
		return

	var step := 0x1000                       # z refine, /16 down to 1
	while step > 0:
		while true:
			var remaining := s32(nz - z)
			if (remaining < step) if dz >= 0 else (remaining > -step):
				break
			var tz := u32(z + (step if dz >= 0 else -step))
			if solid(tz, x, y):
				break
			z = tz
		step /= 0x10

	step = 0x7D                              # x refine, /5
	while step > 0:
		while true:
			var remaining := s16(nx - x)
			if (remaining < step) if dx >= 0 else (remaining > -step):
				break
			var tx := u16(x + (step if dx >= 0 else -step))
			if solid(z, tx, y):
				break
			x = tx
		step /= 5

	step = 0x7D                              # y refine, /5
	while step > 0:
		while true:
			var remaining := s16(ny - y)
			if (remaining < step) if dy >= 0 else (remaining > -step):
				break
			var ty := u16(y + (step if dy >= 0 else -step))
			if solid(z, x, ty):
				break
			y = ty
		step /= 5


# --- landing autopilot (fn_1bb5 / fn_1c20 / fn_1d4d) ----------------------
# Invisible and load-bearing: fires once per jump, nudges steering then speed
# until the arc lands somewhere survivable, and the speed change is reverted on
# touchdown so the player never sees it. Remove it and the game feels broken.
func _ap_bad_cell(zz: int, xx: int) -> bool:
	var code := tile_at(zz, xx)
	var kind := code & 0xF00
	if kind == 0x100:
		return false                          # a tunnel roof is a fine landing
	if kind:
		code >>= 4                            # judge the block's top face
	var surf := code & 0xF
	if surf == 0:
		return kind == 0                      # empty only when there is no block
	return surf == 0xC                        # burning


func _ap_lands(sp: int, xv: int) -> bool:
	var zz := z
	var xx := x
	var yy := y
	var yv := yvel
	var prev_z := zz
	var prev_x := xx
	var guard := 0
	while yy > SkyRoads.Y_DECK and guard < 4096:
		guard += 1
		prev_z = zz
		prev_x = xx
		yv = s16(yv + grav_accel)
		zz = u32(zz + sp)
		xx += side_push + xv * (sp + SkyRoads.LATERAL_BONUS) / SkyRoads.LATERAL_DIV
		if xx < SkyRoads.X_MIN or xx > SkyRoads.X_MAX:
			return false
		yy += yv
		sp += accel * SkyRoads.SPEED_ACCEL
		sp = clampi(sp, 0, SkyRoads.SPEED_MAX)
	return not _ap_bad_cell(zz, u16(xx)) and not _ap_bad_cell(prev_z, u16(prev_x))


func _autopilot() -> void:
	if _ap_lands(speed, xvel):
		ap_delta = 0
		return
	var speed0 := speed
	var fixed := false
	for di in range(1, SkyRoads.AP_STRENGTHS + 1):
		var xv := s16(xvel + xvel * di / 10)
		if _ap_lands(speed, xv):
			xvel = xv
			fixed = true
			break
		xv = s16(xvel - xvel * di / 10)
		if _ap_lands(speed, xv):
			xvel = xv
			fixed = true
			break
		var sp := speed + speed * di / 10
		if sp < SkyRoads.SPEED_MAX and _ap_lands(sp, xvel):
			speed = sp
			fixed = true
			break
		sp = speed - speed * di / 10
		if _ap_lands(sp, xvel):
			speed = sp
			fixed = true
			break
	if not fixed:
		speed = speed0
		ap_delta = 0
		return
	ap_delta = speed - speed0
	ap_light = 1


# --- sound effects surfaced to the shell (fn_03c2) ------------------------
func _sfx(n: int) -> void:
	pending_sfx = n + 1                       # 0 means none
	# sfx_tick is what _sfx_busy() reads. Dropping it leaves the gate
	# permanently open, so the bounce thud fires on every hard landing instead
	# of at most once per 8 ticks. It changes no physics, which is exactly why
	# a trace that compares only position and velocity cannot see it.
	sfx_tick = tick


func _sfx_busy() -> bool:
	return tick < sfx_tick + SkyRoads.SFX_BUSY_TICKS


# --- surface effects (fn_1a9c) -------------------------------------------
func _surface_effects(code: int) -> void:
	match code & 0xF:
		0x2:
			if expl_ctr == 0:
				speed -= SkyRoads.SPEED_STICKY
		0x9:
			if end_state == 0:
				if fuel < SkyRoads.SUPPLY_SFX_THRESH or oxy < SkyRoads.SUPPLY_SFX_THRESH:
					_sfx(4)
				fuel = SkyRoads.TANK_FULL
				oxy = SkyRoads.TANK_FULL
		0xA:
			if expl_ctr == 0:
				speed += SkyRoads.SPEED_BOOST
		0xC:
			if end_state == 0:
				end_state = 2
			if expl_ctr == 0:
				expl_ctr = 1
				_sfx(0)
	speed = clampi(speed, 0, SkyRoads.SPEED_MAX)


func set_input(st: int, ac: int, jp: int) -> void:
	steer = st
	accel = ac
	jumpkey = jp


# --- one 36 Hz tick (fn_1f2c 0x22a3..0x2add) ------------------------------
#
# This is a transcription, so its shape is the binary's and not a design: it
# runs straight through eleven phases in a fixed order, and reordering any two
# of them changes the game. The markers below name them; they are the only
# thing in this function that is not the original.
#
#   1  bookkeeping, and the fly-away that ends a finished road
#   2  the death holds — an end state does not stop the tick, it counts frames
#   3  the tile under the ship, and the surface effects it applies
#   4  the finish gate
#   5  landing aftermath: the bounce
#   6  the player's input — throttle, steering, jump
#   7  the landing assist
#   8  gravity, or the explosion's own vertical motion
#   9  the swept move, and what it ran into: corner, wall, scrape
#  10  what a landing does: the edge probe and the side push
#  11  the tanks, and the tests that end the road
#
# Do not restructure it into sub-functions without a failing three-way trace
# to justify the change. It is proven bit-exact against the C engine and the
# Python model over 60,964 ticks, and that proof is the reason the port can
# claim what it claims.
func step() -> int:
	# 1 --- bookkeeping, and the fly-away -----------------------------------
	var rows := road.rows
	tick += 1
	pending_sfx = 0

	if fly_ticks > 0:                         # completion fly-away (fn_0e58)
		z = u32(z + speed)
		fly_ticks -= 1
		return COMPLETE if fly_ticks == 0 else RUNNING

	# 2 --- the death holds -------------------------------------------------
	if not (expl_ctr != 0 and expl_ctr <= SkyRoads.EXPL_FRAMES):
		if end_state == 1:
			return WALL
		if end_state == 2:
			return BURNED
		if end_state == 3 and expl_ctr != 0:
			return FELL
		if end_frames >= SkyRoads.DEATH_HOLD:
			return end_state

	# 3 --- the tile underneath, and what it does to the ship ---------------
	tile_code = tile_at(z, x)
	over_hole = 1 if tile_code == 0 else 0

	if on_ground:
		var code := tile_code
		if y > SkyRoads.Y_DECK:
			var bt := (code >> 8) & 0xF
			code = code >> 4 if (bt < 6 and y == SkyRoads.BLOCK_TOP[bt]) else 0
		_surface_effects(code)
		on_ice = 1 if (code & 0xF) == 8 else 0
		on_sticky = 1 if (code & 0xF) == 2 else 0
	else:
		on_sticky = 0                         # ice persists while airborne

	# 4 --- the finish gate -------------------------------------------------
	# the finish line is literally a tunnel on the last row, and the ship has
	# to fly low enough to be inside its mouth — jumping the gate does nothing
	if z >= (((rows - 1) << 16) + 0x8000) and in_tunnel(z, x, y) and end_state == 0:
		y = 0
		fly_ticks = SkyRoads.FLY_AWAY
		return RUNNING

	# 5 --- landing aftermath: the bounce -----------------------------------
	if y != last_new_y:                       # landing aftermath / bounce
		if side_push != 0 and edge_dist < 2:
			yvel = 0
		else:
			var thresh := (SkyRoads.BOUNCE_THRESH_NUM * road.gravity) / SkyRoads.BOUNCE_THRESH_DEN
			if absi(yvel) >= thresh and expl_ctr == 0:
				if end_state == 0 and yvel < 0 and not _sfx_busy():
					_sfx(1)
				yvel = s16(-(yvel * SkyRoads.BOUNCE_NUM) / SkyRoads.BOUNCE_DEN)
			else:
				yvel = 0

	# 6 --- the player's input ----------------------------------------------
	if end_state == 0:
		speed += accel * SkyRoads.SPEED_ACCEL
		speed = clampi(speed, 0, SkyRoads.SPEED_MAX)

		if not on_ice:
			if not jumping and not over_hole:
				xvel = s16(steer * SkyRoads.STEER_VEL)
			elif xvel == 0 and yvel > 0 and u16(y - jump_start_y) < SkyRoads.AIR_STEER_WINDOW:
				xvel = s16(steer * SkyRoads.STEER_VEL)

		if not jumping and not over_hole and jumpkey and road.gravity < SkyRoads.JUMP_MAX_GRAVITY:
			yvel = SkyRoads.JUMP_VEL
			jumping = 1
			jump_start_y = y

	# 7 --- the landing assist ----------------------------------------------
	if autopilot_on and jumping and not ap_done and y >= SkyRoads.AP_TRIGGER_Y:
		_autopilot()
		ap_done = 1

	# 8 --- gravity, or the explosion's own vertical motion -----------------
	if expl_ctr == 0:
		if y >= SkyRoads.Y_DECK:
			yvel = s16(yvel + grav_accel)
		elif yvel > SkyRoads.VOID_FALL_VEL:
			yvel = SkyRoads.VOID_FALL_VEL
	else:
		if yvel < 0:
			yvel = 0
		yvel = s16(yvel + SkyRoads.EXPL_YVEL_STEP) if yvel < SkyRoads.EXPL_YVEL_CAP else SkyRoads.EXPL_YVEL_CAP

	# 9 --- the swept move, and what it ran into ----------------------------
	var new_z := u32(z + speed)
	# sticky floors LOSE the lateral bonus (EXE 0x2634) — they are not friction,
	# they are a near-stop, and they take your steering authority with them
	var eff := speed + (0 if on_sticky else SkyRoads.LATERAL_BONUS)
	var new_x := u16(x + s16(xvel * eff / SkyRoads.LATERAL_DIV) + side_push)
	if (x < SkyRoads.X_MIN and new_x > SkyRoads.X_MAX) or (x > SkyRoads.X_MAX and new_x < SkyRoads.X_MIN):
		new_x = x
	var new_y := u16(y + yvel)

	_swept_move(new_z, new_x, new_y)
	last_new_y = new_y

	if z != new_z and x == new_x:             # corner nudge
		if solid(new_z, x, y):
			if not solid(new_z, u16(x - SkyRoads.CORNER_NUDGE), y):
				x = u16(x - SkyRoads.CORNER_NUDGE)
				new_z = z
				_sfx(2)
			elif not solid(new_z, u16(x + SkyRoads.CORNER_NUDGE), y):
				x = u16(x + SkyRoads.CORNER_NUDGE)
				new_z = z
				_sfx(2)

	if z != new_z:                            # wall hit
		if speed >= SkyRoads.SPEED_KILL:
			if expl_ctr == 0:
				expl_ctr = 1
				_sfx(0)
				if end_state == 0:
					end_state = 1
		elif z > u32(new_z - speed):
			_sfx(2)
		speed = 0

	if x != new_x:                            # scraped a wall
		xvel = 0
		if (side_push > 0 and new_x > x) or (side_push < 0 and new_x < x):
			side_push = 0
		speed = clampi(speed - SkyRoads.SPEED_SCRAPE, 0, SkyRoads.SPEED_MAX)

	# 10 --- what a landing does --------------------------------------------
	on_ground = 0
	if y != new_y and yvel < 0:               # landed
		ap_light = 0
		ap_done = 0
		jumping = 0
		on_ground = 1
		speed = clampi(speed - ap_delta, 0, SkyRoads.SPEED_MAX)
		ap_delta = 0

		var balance := 0
		edge_dist = 0x7FFF
		for i in range(1, SkyRoads.EDGE_PROBE_MAX + 1):
			if not solid(z, u16(x + i * SkyRoads.EDGE_PROBE_STEP), u16(y - 1)):
				balance += 1
				edge_dist = i
				break
		for i in range(1, SkyRoads.EDGE_PROBE_MAX + 1):
			if not solid(z, u16(x - i * SkyRoads.EDGE_PROBE_STEP), u16(y - 1)):
				balance -= 1
				edge_dist = i
				break
		side_push = s16(side_push + balance * SkyRoads.EDGE_PUSH) if balance else 0

	if y > 0x7FFF:
		y = 0

	# 11 --- the tanks, and the tests that end the road ---------------------
	if end_state == 0:
		var oxy_div := u16(SkyRoads.OXY_TICK_DIV * road.oxygen_secs)
		if oxy_div:
			oxy = maxi(0, oxy - SkyRoads.TANK_FULL / oxy_div)
		if road.fuel_rows:
			var q := SkyRoads.TANK_FULL / road.fuel_rows
			fuel = maxi(0, fuel - s16((q * speed) >> 16))
		if y < SkyRoads.Y_DECK:
			end_state = 3
		if fuel == 0:
			end_state = 4
		if oxy == 0:
			end_state = 5
	else:
		end_frames += 1
	if expl_ctr != 0:
		expl_ctr += 1

	return RUNNING
