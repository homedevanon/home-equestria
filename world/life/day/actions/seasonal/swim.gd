extends "res://world/life/day/actions/go_to.gd"
## Summer: cool off by the river (M-SEA-19, "swim"). Ponies have no swimming locomotion (pony
## water_escape.gd is a rescue path and routes avoid water), so she goes down to a river bridge on a
## warm sunny day and sits or lies by the water; the table's phrase says "cool off by the river",
## so dialogue never claims a swim that did not happen.
const WORLD := preload("res://world/life/day/actions/seasonal/season_world.gd")

func start(ctx: Dictionary) -> bool:
	if not WORLD.sunny(ctx.tree): return false
	return super.start(ctx)
