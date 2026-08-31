#!/usr/bin/env bash
# One command that has to be green before anything is called working.
#
# Three passes, because a suite run alone lies in two documented ways:
#   1. `--script suite.gd` only loads what that suite references, so a syntax
#      error in an unreferenced file ships with a 100% green run.
#   2. Grepping for "FAIL" reports a suite that died early (parse error, crash)
#      as passing, because it printed no FAIL. Every suite must print a
#      "Result:" line and we assert on that positive signal.
# `--quit` is deliberately NOT passed: it exits after one frame and would skip
# any frame-driven suite entirely.
set -uo pipefail
GODOT="${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}"
# resolve through symlinks, so tools/verify.sh -> godot/verify.sh works
SRC="${BASH_SOURCE[0]}"
while [ -L "$SRC" ]; do
    DIR="$(cd -P "$(dirname "$SRC")" && pwd)"
    SRC="$(readlink "$SRC")"
    [[ $SRC != /* ]] && SRC="$DIR/$SRC"
done
HERE="$(cd -P "$(dirname "$SRC")" && pwd)"
status=0

echo "== parse pass (every script, referenced or not) =="
while IFS= read -r f; do
    rel="res://${f#"$HERE"/}"
    out=$("$GODOT" --headless --path "$HERE" --check-only --script "$rel" 2>&1 \
          | grep -E "SCRIPT ERROR|Parse Error")
    if [ -n "$out" ]; then
        echo "  FAIL $rel"
        echo "$out" | sed 's/^/       /'
        status=1
    else
        echo "  ok   $rel"
    fi
done < <(find "$HERE/scripts" "$HERE/tests" "$HERE/data" -name '*.gd' 2>/dev/null | sort)

echo
echo "== rendering (needs a real GPU context, so not headless) =="
# The headless rasterizer draws nothing, so anything that asserts on pixels has
# to run windowed. Occlusion is exactly that kind of check: the simulation
# stops the ship at a wall, and this proves the player is shown that.
# The dashboard is compared against C reference frames, which means the port
# has to actually PLAY to those ticks first. Capture them once, windowed,
# before the pixel suites run; render_dashboard.gd reads the directory from
# SR_DASH_SHOTS and self-skips if the capture did not happen.
# A windowed capture on macOS is starved of frames whenever its window is not
# frontmost, and then produces nothing — which would fail the pixel suites for
# a reason that has nothing to do with the code. Retry once, and say so.
capture() {
    local dir="$1" want="$2" road="$3" route="$4" ticks="$5"
    local attempt
    for attempt in 1 2; do
        "$GODOT" --path "$HERE" --resolution 640x480 -- \
            --replay "$road" --route-file "$route" \
            --shots "$dir" --shot-ticks "$ticks" >/dev/null 2>&1
        [ "$(find "$dir" -name '*.png' | wc -l)" -ge "$want" ] && return 0
        echo "       (capture for road $road produced nothing; retrying)"
    done
    echo "       WARNING: road $road never captured — its pixel suite will fail"
    return 1
}

SR_DASH_SHOTS="$(mktemp -d)"
SR_SKY_SHOTS="$(mktemp -d)"
export SR_DASH_SHOTS SR_SKY_SHOTS
trap 'rm -rf "$SR_DASH_SHOTS" "$SR_SKY_SHOTS"' EXIT
capture "$SR_DASH_SHOTS" 4 2 res://tests/fixtures/road02_route.bin 101,241,421,641
# road 26 is world 8, whose sky is mostly palette index 0 — the case that
# exposes anything wrong with how the backdrop handles it. Road 5 is world 1:
# tall roadside blocks beside the ship, which is what used to project up out
# of the viewport into the sky (render_backdrop.gd).
capture "$SR_SKY_SHOTS" 2 26 res://tests/fixtures/accel_route.bin 61,241
capture "$SR_SKY_SHOTS" 4 5 res://tests/fixtures/accel_route.bin 61,121

for t in "$HERE"/tests/render_*.gd "$HERE"/tests/test_occlusion.gd; do
    [ -e "$t" ] || continue
    name="$(basename "$t")"
    out=$("$GODOT" --path "$HERE" --resolution 640x480 --script "res://tests/$name" 2>&1)
    if printf '%s' "$out" | grep -q "^Result:"; then
        printf '%s\n' "$out" | grep -E "^( +(menu_|dash |sky )|ship pixels|Result:)" | sed 's/^/       /'
        if printf '%s' "$out" | grep -q "FAIL"; then
            printf '%s\n' "$out" | grep "FAIL" | sed 's/^/       /'
            echo "  FAIL $name"; status=1
        else
            echo "  ok   $name"
        fi
    else
        echo "  FAIL $name (no Result line)"; status=1
    fi
done

# The touch shell runs on its own: it needs `-- --touch` (the phone controls
# are off on a desktop by design) and it pushes synthetic touches through the
# real input pipeline, so it needs a window like the pixel suites do.
# It runs once per window size: the taps are written in 320x240 canvas space
# and divided by the root viewport's stretch on the way in, so a scale factor
# that is wrong is only visible at a scale that is not 1. 1280x960 is the size
# the desktop window now actually opens at (project.godot's *_override), and
# it is an integer 4x, which the 640x480 case cannot distinguish from a
# fractional one.
if [ -e "$HERE/tests/touch_shell.gd" ]; then
    for res in 640x480 1280x960; do
        out=$("$GODOT" --path "$HERE" --resolution "$res" \
            --script res://tests/touch_shell.gd -- --touch 2>&1)
        if printf '%s' "$out" | grep -q "^Result:"; then
            printf '%s\n' "$out" | grep -E "^Result:" | sed "s/^/       $res /"
            if printf '%s' "$out" | grep -q "FAIL"; then
                printf '%s\n' "$out" | grep "FAIL" | sed 's/^/       /'
                echo "  FAIL touch_shell.gd ($res)"; status=1
            else
                echo "  ok   touch_shell.gd ($res)"
            fi
        else
            echo "  FAIL touch_shell.gd ($res, no Result line)"; status=1
        fi
    done
fi

echo
echo "== suites =="
for t in "$HERE"/tests/test_*.gd; do
    name="$(basename "$t")"
    # occlusion needs a GPU context and ran above
    [ "$name" = "test_occlusion.gd" ] && continue
    out=$("$GODOT" --headless --path "$HERE" --script "res://tests/$name" 2>&1)
    fails=$(printf '%s' "$out" | grep -c "FAIL" || true)
    # a suite that never printed Result: died before its assertions ran
    if ! printf '%s' "$out" | grep -q "^Result:"; then
        echo "  FAIL $name (no Result line — died before asserting)"
        printf '%s\n' "$out" | grep -vE "^$|Godot Engine" | tail -5 | sed 's/^/       /'
        status=1
        continue
    fi
    printf '%s\n' "$out" | grep -E "^(road|Result:)" | sed 's/^/       /'
    if [ "$fails" -gt 0 ]; then
        echo "  FAIL $name"
        printf '%s\n' "$out" | grep "FAIL" | sed 's/^/       /'
        status=1
    else
        echo "  ok   $name"
    fi
done

echo
echo "== end to end (real scene, real loop, real tick rate) =="
# The suites exercise SkyRoadsPlay directly. This drives the whole stack:
# Main.tscn -> GameLoop's fixed-step accumulator -> the simulation. It fails if
# any of the three is broken, which unit tests on the physics alone would miss.
# Only roads with a winning route can be replayed to completion. Roads the
# solver could not finish are still covered field-by-field by the suites above,
# through a deterministic probe.
for f in "$HERE"/data/routes/road_*.bin; do
    [ -e "$f" ] || continue
    # only the plain winning routes: skip probes and named variants
    case "$f" in *_probe.bin|*_crash.bin) continue;; esac
    road=$(basename "$f" .bin); road=${road#road_}; road=$((10#$road))
    out=$("$GODOT" --headless --path "$HERE" -- --replay "$road" 2>&1)
    rc=$?
    line=$(printf '%s' "$out" | grep "^finished:")
    if [ $rc -eq 0 ] && printf '%s' "$line" | grep -q "complete"; then
        echo "  ok   road $road — $line"
    else
        echo "  FAIL road $road (exit $rc)"
        printf '%s\n' "$out" | grep -vE "^$|Godot Engine" | tail -5 | sed 's/^/       /'
        status=1
    fi
done
for f in "$HERE"/data/routes/*_probe.bin; do
    [ -e "$f" ] || continue
    road=$(basename "$f" _probe.bin); road=${road#road_}
    echo "  --   road $((10#$road)) has no winning route; covered by its probe trace"
done

# The suites above replay two solved routes: ticks that all complete, so they
# never reach a wall crash, a burning tile, a fall or an empty tank. The
# three-way differential covers those. It needs the analysis toolkit and a C
# compiler, so it is opt-in rather than a hard gate here.
if [ "${THREEWAY:-0}" = "1" ]; then
    echo
    echo "== the shipped levels, all three engines, many pilots =="
    # The suites replay one route per level and the differential below uses
    # randomised roads, so neither drives the ACTUAL shipped levels under
    # varied input. This does, loading each road from the exported JSON that
    # Godot consumes rather than from the source file.
    if (cd "$HERE/../analysis" && ./sra.py validate 1 30 --pilots "${PILOTS:-60}" 2>&1 | tail -4); then
        echo "  ok"
    else
        echo "  FAIL"
        status=1
    fi

    echo
    echo "== three-way differential (randomised roads) =="
    if (cd "$HERE/../analysis" && ./sra.py threeway --trials "${TRIALS:-150}" 2>&1 | tail -3); then
        echo "  ok"
    else
        echo "  FAIL"
        status=1
    fi
fi

echo
[ $status -eq 0 ] && echo "VERIFY OK" || echo "VERIFY FAILED"
exit $status
