# gd-audit: ignore GDBP-101 — every script in this repo is PascalCase
# Surface identities, shared with the C reference's `sr_surface_ids`.
#
# BUGS §12.14 ended with a method, not a fix: every claim of the form "the port
# draws the wrong SURFACE here" had been made by classifying pixels to the
# nearest palette entry, and that cannot work — road 21's palette holds exact
# duplicates ([61]==[68], [62]==[66], gap 0), so a block face and an arch band
# are byte-identical and no colour comparison can tell them apart.
#
# The fix is to stop asking the colour. Both engines know which surface they
# are painting at the moment they paint it, so both write that identity into a
# second buffer and the two buffers are compared directly:
#
#   * the reference does it in `fill_record` (render.h SR_SID_*, one id per
#     span record: composer, directory kind, ordinal within the composer);
#   * the port does it here, one id per emitted quad, carried in UV2.x and
#     resolved by the road shader when sid_mode is on.
#
# The numbers are STRUCTURAL — composer, kind, ordinal — and deliberately carry
# no semantics. render.c's own comments name several of these surfaces the
# other way round (BUGS #24), so a name here would smuggle in the very
# assumption the buffer exists to test.
#
# The port's id for a quad is therefore a CLAIM: "this quad is what the
# reference paints with that record". Where the claim is wrong, the comparison
# says so — which is the entire point. Where the port has no quad for a record
# at all (a full block's lower band, kind 3 record 0 and kind 2 record 1), the
# comparison shows the reference's id against whatever the port put there.
extends RefCounted

const NONE := 0

const FLOOR_K0_0 := 1        ## compose_floor, kind 0, record 0
const FLOOR_K0_1 := 2        ## record 1, drawn when the inner neighbour is 0
const FLOOR_K0_2 := 3        ## record 2, drawn when the nearer neighbour is 0

const LOWBLOCK_K3_0 := 16    ## compose_lowblock (shape 2)
const LOWBLOCK_K2_0 := 17
const LOWBLOCK_K2_1 := 18

const TUNLOW_K1_0 := 32      ## compose_tun_low (shape 3)
const TUNLOW_K2_0 := 33
const TUNLOW_K2_1 := 34
const TUNLOW_K3_1 := 35
const TUNLOW_K3_2 := 36

const HIBLOCK_K3_0 := 48     ## compose_highblock (shape 4)
const HIBLOCK_K2_1 := 49
const HIBLOCK_K5_0 := 50
const HIBLOCK_K5_1 := 51
const HIBLOCK_K5_2 := 52

const TUNNEL_K1_0 := 64      ## compose_tunnel (shape 1)
const TUNNEL_K4_0 := 65      ## the six kind-4 records, in paint order
const TUNNEL_K4_6 := 71      ## the two rim records, mouth only
const TUNNEL_K4_7 := 72

const TUNHIGH_K1_0 := 80     ## compose_tun_high (shape 5)
const TUNHIGH_K2_1 := 81
const TUNHIGH_K3_1 := 82
const TUNHIGH_K3_2 := 83
const TUNHIGH_K5_0 := 84
const TUNHIGH_K5_1 := 85
const TUNHIGH_K5_2 := 86

const SHIP := 240
const SHADOW := 241

## Ids travel to the comparison as PIXELS, so they are encoded with room to
## spare rather than written raw: 3 bits in red, 3 in green, 2 in blue, each
## bucket 32 (64 for blue) apart and centred. Anything the display pipeline
## does to a colour short of destroying it lands inside the right bucket, so
## the decode is exact without depending on the framebuffer being untouched.
static func encode(sid: int) -> Color:
	return Color8(
		(sid & 7) * 32 + 16,
		((sid >> 3) & 7) * 32 + 16,
		((sid >> 6) & 3) * 64 + 32)


## Inverse of encode() for an 8-bit RGB triple, used by tools/sid_compare.py's
## GDScript-side equivalent and by the tests.
static func decode(r: int, g: int, b: int) -> int:
	var rb := clampi(int(round((r - 16) / 32.0)), 0, 7)
	var gb := clampi(int(round((g - 16) / 32.0)), 0, 7)
	var bb := clampi(int(round((b - 32) / 64.0)), 0, 3)
	return rb | (gb << 3) | (bb << 6)


## Human-readable name, for reports only. Never used to decide anything.
static func name_of(sid: int) -> String:
	match sid:
		NONE: return "none"
		FLOOR_K0_0: return "floor.k0.0"
		FLOOR_K0_1: return "floor.k0.1"
		FLOOR_K0_2: return "floor.k0.2"
		LOWBLOCK_K3_0: return "lowblock.k3.0"
		LOWBLOCK_K2_0: return "lowblock.k2.0"
		LOWBLOCK_K2_1: return "lowblock.k2.1"
		TUNLOW_K1_0: return "tunlow.k1.0"
		TUNLOW_K2_0: return "tunlow.k2.0"
		TUNLOW_K2_1: return "tunlow.k2.1"
		TUNLOW_K3_1: return "tunlow.k3.1"
		TUNLOW_K3_2: return "tunlow.k3.2"
		HIBLOCK_K3_0: return "hiblock.k3.0"
		HIBLOCK_K2_1: return "hiblock.k2.1"
		HIBLOCK_K5_0: return "hiblock.k5.0"
		HIBLOCK_K5_1: return "hiblock.k5.1"
		HIBLOCK_K5_2: return "hiblock.k5.2"
		TUNNEL_K1_0: return "tunnel.k1.0"
		TUNNEL_K4_6: return "tunnel.k4.6"
		TUNNEL_K4_7: return "tunnel.k4.7"
		SHIP: return "ship"
		SHADOW: return "shadow"
	if sid >= TUNNEL_K4_0 and sid < TUNNEL_K4_6:
		return "tunnel.k4.%d" % (sid - TUNNEL_K4_0)
	return "sid%d" % sid
