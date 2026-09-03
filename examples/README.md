# examples

Roads built with the editor (`--editor NAME`), not decoded from `ROADS.LZS`.
They are the port author's own work, so unlike everything under `data/` they
are not carved out by `LICENSE`.

## `vaults.json`

Sixty rows, gravity 8: a narrowing run-up, a boost strip into a two-row gap, a
weave, a tunnel, a refuelling block, a burning centre lane, ice, a walled
section and two dog-legs, finishing in a full-width tunnel.

```sh
godot --path . -- --road 0 --level-file res://examples/vaults.json
godot --path . -- --editor vaults          # after copying it into user://levels/
```

`vaults_route.bin` is a solved route for it, found by `sra solve --road-json`
and replayed by the port to **complete in 484 ticks** — the same tick count the
solver reported, which is the three-engine agreement holding on a road that was
never in the retail data:

```sh
godot --path . -- --replay 0 --level-file res://examples/vaults.json \
    --route-file res://examples/vaults_route.bin
```

The first draft of this road was **unsolvable**, and the solver said so: it
died at row 34.7, where three rows of ice ended against a wall with a single
open lane. Widening that to three lanes and giving the ship one row of grip
before it fixed the road. That exchange is the whole argument for the validate
and solve buttons existing.
