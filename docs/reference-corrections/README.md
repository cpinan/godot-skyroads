# Corrections to the trees this repo is measured with

Two things this port depends on live OUTSIDE this repository — `skyroads-port/`,
the C reference it was originally written against, and `analysis/`, the Python
toolkit that decodes the retail data and searches for routes. Neither is a
submodule; both are sibling checkouts, so anything changed in them is one
`rm -rf` away from being gone. The patches here are those changes, kept in the
repo that depends on them.

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

### `0002-solver-sub-column-retry.patch`

Applies to `analysis/`, not to the C reference.

`sra solve`'s beam search de-duplicated states on which of the seven COLUMNS
the ship was over. A column is `0x2E * 0x80` x-units wide and **a tunnel bore
is narrower than that**, so "centred in column 5" and "scraping the edge of
column 5" were one niche and only one survived. When the survivor was the
off-centre one the bore could never be entered — and no beam width fixes it,
because the merge happens before selection. Road 6 failed at 8192 slots
exactly as it failed at 1024, and solved at 1024 once 9 bits of sub-column
position were kept.

It is not a free win, which is why it is a retry rather than a new default.
Splitting niches gives each fewer slots at a fixed beam, so it loses roads as
well as winning them. Measured over all 30 on 2026-08-31, at
`--beam 1024 --hold 1`:

| | roads |
|---|---|
| only the plain key solves | 5, 14, 24 |
| only the sub-column key solves | 6, 8, 25 |

Complementary, not ordered. So `sra solve` now runs the plain pass and retries
only the failures with `--sub-column 9`, keeping whichever succeeds. That is
sound because the search is authoritative in one direction only: a route found
is a proof, since `verify()` replays it from scratch.

```bash
python3 sra.py --data <retail dir> solve --beam 1024 --hold 1 --max-ticks 16000 \
    --write-scripts <out>          # both passes; --sub-column 0 disables the retry
```

Eleven roads still resist both: 10, 12, 13, 16, 18, 19, 20, 27, 28, 29, 30.
Three shapes, from the furthest row each reaches — 12 at 161/164 and 28 at
106/234 look like beam width or patience; 19 at 152.6/147 and 24 at 86.4/83
overfly the finish, which only triggers inside the final tunnel mouth; 10, 13
and 16 die below row 10 and neither key moves them.

## Adding to this directory

Keep one patch per defect, named `NNNN-<what>.patch`, and cite the EXE address
that settles it. A correction with no address behind it is a preference, and
this directory is for the other kind.
