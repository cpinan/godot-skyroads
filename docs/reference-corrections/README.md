# Corrections to the C reference

`skyroads-port/` is the C reference this port was originally written against.
It lives OUTSIDE this repository — a sibling checkout, not a submodule — so
anything changed in it is one `rm -rf` away from being gone. The patches here
are those changes, kept in the repo that depends on them.

They matter because the reference is not a passive copy of the 1993 game. It
is the **measuring instrument**: `tools/replay_frames.c` renders through it,
and every parity percentage in `BUGS.md` §12 is a comparison against frames it
drew. A defect in the reference is a defect in every number measured with it,
and `docs/BUGS.md` §11 records eleven such defects that the port had faithfully
copied — agreement with `skyroads-port/` proves nothing on its own.

## Applying them

```bash
cd <wherever skyroads-port lives>
git apply <this repo>/godot/docs/reference-corrections/*.patch   # or: patch -p1 <...
```

Then rebuild whatever reads it:

```bash
clang -O2 -o /tmp/sr_replay_frames tools/replay_frames.c \
    skyroads-port/src/core/{assets,audio,cfg,game,gfx,hud,lzs,play,render,tables,text}.c \
    skyroads-port/src/thirdparty/opl3.c -lm
```

## What is here

### `0001-compose_tun_high.patch`

`compose_tun_high` was wrong in two directions at once, and the port had copied
both — which is why no test could see it. Full write-up in `docs/BUGS.md`
§12.1; in short, against `SKYROADS.EXE` at `0x2fb0`:

- it drew the six kind-4 arch records, which `0x2fb0` never touches — it does
  not load `[di+8]` at all;
- it omitted the kind-3 pair that splits the cell's lower front around the
  bore.

A tun_high is the full-height block of `0x2f3c` with its plain lower front
replaced by that split pair, plus the bore's interior at colour `0x41`. The
patch makes the reference draw that.

**Verifying it independently of this note:** decode the records the handler
consumes and read the geometry off them directly.

```bash
clang -O2 -o /tmp/sr_dump_bands tools/dump_bands.c \
    skyroads-port/src/core/{assets,audio,cfg,game,gfx,hud,lzs,play,render,tables,text}.c \
    skyroads-port/src/thirdparty/opl3.c -lm
/tmp/sr_dump_bands <retail dir> 0 kindlines 5     # the tier: top, side, front
/tmp/sr_dump_bands <retail dir> 0 kindlines 3     # the front, split by the bore
```

At phase 0 / dr7 / ci1 the kind-3 pair carves an opening 16 px high at the lane
centre and 20 px half-wide at the deck — `RoadMesh.ARCH_BORE_PX` to the pixel —
and the kind-5 group is top `y[51..61]`, side `y[51..81]`, front `y[62..81]`,
continuing into the kind-3 front at `y[82..101]`. One unbroken masonry face
from the tier's top edge down to the road, pierced once.

## Adding to this directory

Keep one patch per defect, named `NNNN-<what>.patch`, and cite the EXE address
that settles it. A correction with no address behind it is a preference, and
this directory is for the other kind.
