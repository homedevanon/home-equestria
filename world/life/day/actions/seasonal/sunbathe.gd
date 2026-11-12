extends "res://world/life/day/actions/go_to.gd"
## Summer: lie in the sun for a while (M-SEA-19): the go_to step (lie_down from the table), only
## while the sun is out and nothing falls.
const WORLD := preload("res://world/life/day/actions/seasonal/season_world.gd")

func start(ctx: Dictionary) -> bool:
	if not WORLD.sunny(ctx.tree): return false
	return super.start(ctx)
