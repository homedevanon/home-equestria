extends RefCounted
## Developer launch flags that keep the old code paths while dev reviews the ported ones
## (docs/MECHANICS_ARCHITECTURE_2026_11_01.md 1.3; the same pattern as `-- --no-spa`). Player
## builds drop them (world/dev_tools.gd PLAYER_ARGS). Removed once dev accepts the ports.
const DEV := preload("res://world/dev_tools.gd")

## `-- --old-jobs` (also `-- --legacy-jobs`): hayburger, spa and orchard keep their own
## queue/shift/pay code (WP5).
static func old_jobs() -> bool:
	return old_jobs_in(DEV.user_args())

## The flag test on a given argument list (the seam tools/mechanics/test_job_core.gd uses).
static func old_jobs_in(args: PackedStringArray) -> bool:
	return "--old-jobs" in args or "--legacy-jobs" in args

## `-- --old-events`: the Trixie show keeps its own daily roll (WP7).
static func old_events() -> bool:
	return "--old-events" in DEV.user_args()
