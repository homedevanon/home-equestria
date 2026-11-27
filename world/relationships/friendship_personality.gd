extends RefCounted
## Observed experiences only. These weights never change romance or consent gates.
const RULES := preload("res://world/relationships/romance_rules.gd")
const PROFILES := {
	"pinkie_pie": {"familiarity": 2.5, "values": "You make friends easily and warm to good talks and shared fun. Friendship isn't consent to romance."},
	"fluttershy": {"familiarity": 0.8, "values": "You warm slowly to quiet walks and gentle, thoughtful visits. Being pushed won't make you trust someone."},
	"rainbow_dash": {"familiarity": 1.0, "values": "You don't care much for flattery. Doing things together and keeping promises is what wins your trust."},
	"twilight_sparkle": {"familiarity": 1.1, "values": "Good talks, shared curiosity and real, practical help bring you closer as friends."},
	"applejack": {"familiarity": 1.0, "values": "You warm to someone who stays around, keeps their word and gives practical help."},
	"rarity": {"familiarity": 1.1, "values": "Time together builds your friendship, along with thoughtfulness and genuine generosity. Endless gifts won't buy romance."},
	"spike": {"familiarity": 1.6, "values": "You like someone who treats you like a grown-up dragon, has fun with you and shares snacks, especially gems. You're a kid, so it's friendship only, never romance."},
}

static func gains(id: String, kind: String, previous: int = 0) -> Dictionary:
	var familiarity: float = 2.0 if kind == "conversation" else 8.0
	# A conversation was 0.5 trust: Friend (trust 10) took twenty separate chats, and love waits for
	# Friend, so it was the slowest step of all (THREAD_FIX_RELATIONSHIP 2026-11-19: a dev world had a
	# pony at familiarity 100 and trust 12 after 28 chats). Now ten chats; gifts stay at 0.5.
	var trust: float = (1.0 if RULES.FACTS else 0.5) if kind == "conversation" else (0.5 if kind == "gift" else 5.0)
	var profile: Dictionary = PROFILES.get(id, {})
	familiarity *= float(profile.get("familiarity", 1.0))
	match id:
		"fluttershy":
			if kind in ["walk", "fishing", "visit"]: trust += 1.0
		"rainbow_dash":
			if kind in ["walk", "fishing", "orchard", "place"]: trust += 2.0
		"twilight_sparkle":
			if kind == "conversation": familiarity += 1.5
			if kind == "orchard": trust += 1.0
		"applejack":
			if kind == "orchard": trust += 2.0
			if previous > 0 and kind not in ["conversation", "gift"]: trust += 0.5
		"spike":
			if kind in ["gift", "meal"]: trust += 1.5
		"rarity":
			if kind == "gift": trust += 2.0
			if kind in ["visit", "meal"]: trust += 1.0
	return {"familiarity": familiarity, "trust": trust}

static func kept_plan_trust(id: String) -> float:
	return 7.0 if id in ["rainbow_dash", "applejack"] else 5.0

static func prompt(id: String) -> String:
	return str((PROFILES.get(id, {}) as Dictionary).get("values", "Friendship grows through meaningful exchanges, shared experiences and kept promises."))

## Scale only earned positive friendship tags. Core still owns caps, scenario budgets,
## replay protection and saturation. Negative boundaries and romance remain unchanged.
static func positive_impression(id: String, amount: int) -> int:
	if amount <= 0: return amount
	var factor: float = float((PROFILES.get(id, {}) as Dictionary).get("familiarity", 1.0))
	return clampi(roundi(float(amount) * factor), 1, 5)
