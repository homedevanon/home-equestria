class_name RiverSupport
extends RefCounted
## Validate generated water against final terrain, after imported zones/mesh fits.
## A coarse spline is authoring intent, not permission to draw a river in mid-air.
const SAMPLE_STEP := 4.0
const MAX_DEPTH := 4.0
const BANK_TOLERANCE := 0.35

static func supported(point: Vector3, side: Vector3, height_at: Callable) -> bool:
	var bed: float = height_at.call(point)
	if not is_finite(bed): return false
	var depth := point.y - bed
	if depth < 0.08 or depth > MAX_DEPTH: return false
	# The ribbon has support across its width. A surface crossing a cliff or floating
	# beside a deep imported valley is not supported by a centre sample alone.
	for sign in [-1.0, 1.0]:
		var bank: float = height_at.call(point + side * sign)
		if not is_finite(bank) or point.y - bank > MAX_DEPTH or bank - point.y > BANK_TOLERANCE: return false
	return true

static func sections(points: Array, half_width: float, height_at: Callable) -> Dictionary:
	var strips: Array = []; var strip: Array[Vector3] = []; var rejected := 0; var accepted := 0
	for i in points.size() - 1:
		var a := Vector3(points[i][0], points[i][1], points[i][2])
		var b := Vector3(points[i + 1][0], points[i + 1][1], points[i + 1][2])
		var forward := Vector3(b.x - a.x, 0, b.z - a.z).normalized()
		var side := Vector3(-forward.z, 0, forward.x) * half_width
		var steps := maxi(1, ceili(a.distance_to(b) / SAMPLE_STEP))
		for j in steps:
			var start := a.lerp(b, float(j) / steps); var end := a.lerp(b, float(j + 1) / steps)
			var valid := supported(start, side, height_at) and supported((start + end) * 0.5, side, height_at) and supported(end, side, height_at)
			if valid:
				if strip.is_empty(): strip.append(start)
				strip.append(end); accepted += 1
			else:
				if strip.size() >= 2: strips.append(strip)
				strip = []; rejected += 1
	if strip.size() >= 2: strips.append(strip)
	return {"strips": strips, "accepted": accepted, "rejected": rejected}
