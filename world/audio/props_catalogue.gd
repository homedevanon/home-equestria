extends RefCounted
## Recorded local foley, prepared from the CC0 sources in the October 13 archive.
## Audio core owns bounded voices, intensity/material selection and anti-repetition.

const SELECT := [
	preload("res://world/audio/designed/foley/select_01.res"),
	preload("res://world/audio/designed/foley/select_02.res"),
	preload("res://world/audio/designed/foley/select_03.res"),
]
const STOW := [
	preload("res://world/audio/designed/foley/stow_01.res"),
	preload("res://world/audio/designed/foley/stow_02.res"),
	preload("res://world/audio/designed/foley/stow_03.res"),
]
const PAGE := [
	preload("res://world/audio/designed/foley/page_01.res"),
	preload("res://world/audio/designed/foley/page_02.res"),
	preload("res://world/audio/designed/foley/page_03.res"),
]
const COVER := [
	preload("res://world/audio/designed/foley/cover_01.res"),
	preload("res://world/audio/designed/foley/cover_02.res"),
	preload("res://world/audio/designed/foley/cover_03.res"),
]
const PAPER := [
	preload("res://world/audio/designed/foley/paper_01.res"),
	preload("res://world/audio/designed/foley/paper_02.res"),
	preload("res://world/audio/designed/foley/paper_03.res"),
]
const CLOTH := [
	preload("res://world/audio/designed/foley/cloth_01.res"),
	preload("res://world/audio/designed/foley/cloth_02.res"),
	preload("res://world/audio/designed/foley/cloth_03.res"),
	preload("res://world/audio/designed/foley/cloth_04.res"),
]
const ROPE := [
	preload("res://world/audio/designed/foley/rope_01.res"),
	preload("res://world/audio/designed/foley/rope_02.res"),
	preload("res://world/audio/designed/foley/rope_03.res"),
]
const FURNITURE := [
	preload("res://world/audio/designed/foley/furniture_01.res"),
	preload("res://world/audio/designed/foley/furniture_02.res"),
	preload("res://world/audio/designed/foley/furniture_03.res"),
]
const PAN := [
	preload("res://world/audio/designed/foley/pan_01.res"),
	preload("res://world/audio/designed/foley/pan_02.res"),
	preload("res://world/audio/designed/foley/pan_03.res"),
]
const COIN := [
	preload("res://world/audio/designed/foley/coin_01.res"),
	preload("res://world/audio/designed/foley/coin_02.res"),
]
const SWITCH := [
	preload("res://world/audio/designed/foley/switch_01.res"),
	preload("res://world/audio/designed/foley/switch_02.res"),
]
const WOOD := [
	preload("res://world/audio/designed/foley/wood_01.res"),
	preload("res://world/audio/designed/foley/wood_02.res"),
	preload("res://world/audio/designed/foley/wood_03.res"),
]
const METAL := [
	preload("res://world/audio/designed/foley/metal_01.res"),
	preload("res://world/audio/designed/foley/metal_02.res"),
	preload("res://world/audio/designed/foley/metal_03.res"),
]
const CERAMIC := [
	preload("res://world/audio/designed/foley/ceramic_01.res"),
	preload("res://world/audio/designed/foley/ceramic_02.res"),
	preload("res://world/audio/designed/foley/ceramic_03.res"),
]
const GLASS := [
	preload("res://world/audio/designed/foley/glass_01.res"),
	preload("res://world/audio/designed/foley/glass_02.res"),
	preload("res://world/audio/designed/foley/glass_03.res"),
]
const SOFT := [
	preload("res://world/audio/designed/foley/soft_01.res"),
	preload("res://world/audio/designed/foley/soft_02.res"),
	preload("res://world/audio/designed/foley/soft_03.res"),
]
const TREE := [
	preload("res://world/audio/designed/foley/tree_01.res"),
	preload("res://world/audio/designed/foley/tree_02.res"),
	preload("res://world/audio/designed/foley/tree_03.res"),
]
const DOOR_OPEN := [
	preload("res://world/audio/designed/foley/door_open_01.res"),
	preload("res://world/audio/designed/foley/door_open_02.res"),
]
const DOOR_CLOSE := [
	preload("res://world/audio/designed/foley/door_close_01.res"),
	preload("res://world/audio/designed/foley/door_close_02.res"),
	preload("res://world/audio/designed/foley/door_close_03.res"),
]
const STEAM := [
	preload("res://world/audio/designed/foley/steam_01.res"),
	preload("res://world/audio/designed/foley/steam_02.res"),
	preload("res://world/audio/designed/foley/steam_03.res"),
]
const SPRAY := [
	preload("res://world/audio/designed/foley/spray_01.res"),
	preload("res://world/audio/designed/foley/spray_02.res"),
	preload("res://world/audio/designed/foley/spray_03.res"),
]
const SIZZLE := [preload("res://world/audio/designed/foley/sizzle_loop.res")]
const SIMMER := [preload("res://world/audio/designed/foley/simmer_loop.res")]
const FIRE := [preload("res://world/audio/designed/foley/fire_loop.res")]
const GRILL_START := [preload("res://world/audio/designed/foley/grill_start.res")]
const WHISTLE := [preload("res://world/audio/designed/foley/train_whistle.res")]

const BITE_CRISP := [preload("res://world/audio/designed/foley/apple_01.res"), preload("res://world/audio/designed/foley/apple_02.res")]
const BITE_CARROT := [preload("res://world/audio/designed/foley/carrot_01.res"), preload("res://world/audio/designed/foley/carrot_02.res"), preload("res://world/audio/designed/foley/carrot_03.res")]
const BITE_SOFT := [preload("res://world/audio/designed/foley/chew_01.res"), preload("res://world/audio/designed/foley/chew_02.res"), preload("res://world/audio/designed/foley/chew_03.res")]
const SIP := [preload("res://world/audio/designed/foley/sip_01.res"), preload("res://world/audio/designed/foley/sip_02.res"), preload("res://world/audio/designed/foley/sip_03.res")]
const TRAIN_ROLL := [preload("res://world/audio/designed/foley/train_roll_loop.res")]

const MATERIALS := {"wood": WOOD, "metal": METAL, "ceramic": CERAMIC, "glass": GLASS, "soft": SOFT, "cloth": CLOTH, "paper": PAPER}

const EVENTS := {
	"prop_bite_crisp": {"streams": BITE_CRISP, "volume_db": -21.0, "distance": 3.0, "cooldown": .32, "priority": 2, "concurrency": 2},
	"prop_bite_carrot": {"streams": BITE_CARROT, "volume_db": -23.0, "distance": 3.0, "cooldown": .32, "priority": 2, "concurrency": 2},
	"prop_bite_soft": {"streams": BITE_SOFT, "volume_db": -26.0, "distance": 3.0, "cooldown": .32, "priority": 2, "concurrency": 2},
	"prop_sip": {"streams": SIP, "volume_db": -26.0, "distance": 3.0, "cooldown": .45, "priority": 2, "concurrency": 2},
	"prop_train_roll_loop": {"streams": TRAIN_ROLL, "volume_db": -28.0, "distance": 45.0, "cooldown": .1, "priority": 1, "concurrency": 2, "loop": true, "pitch_min": 1.0, "pitch_max": 1.0},
	"prop_select": {"streams": SELECT, "volume_db": -29.0, "distance": 2.5, "cooldown": 0.09, "priority": 2, "concurrency": 2},
	"prop_stow": {"streams": STOW, "volume_db": -21.0, "distance": 4.0, "cooldown": 0.12, "priority": 2, "concurrency": 2},
	"prop_page": {"streams": PAGE, "volume_db": -21.0, "distance": 3.0, "cooldown": 0.2, "priority": 2, "concurrency": 2},
	"prop_cover": {"streams": COVER, "volume_db": -22.0, "distance": 3.0, "cooldown": 0.15, "priority": 2, "concurrency": 2},
	"prop_impact": {"streams": WOOD, "volume_db": -21.0, "distance": 7.0, "cooldown": 0.2, "priority": 1, "concurrency": 3, "materials": MATERIALS},
	"prop_pickup": {"streams": CLOTH, "volume_db": -26.0, "distance": 3.0, "cooldown": 0.15, "priority": 2, "concurrency": 2, "materials": MATERIALS},
	"prop_place": {"streams": WOOD, "volume_db": -23.0, "distance": 5.0, "cooldown": 0.18, "priority": 2, "concurrency": 3, "materials": MATERIALS},
	"prop_tree": {"streams": TREE, "volume_db": -16.0, "distance": 12.0, "cooldown": 0.3, "priority": 2, "concurrency": 3},
	"prop_harvest_deposit": {"streams": SOFT, "volume_db": -21.0, "distance": 5.0, "cooldown": 0.15, "priority": 2, "concurrency": 2},
	"prop_reel": {"streams": SELECT, "volume_db": -25.0, "distance": 4.0, "cooldown": 0.15, "priority": 2, "concurrency": 2},
	"prop_cast": {"streams": ROPE, "volume_db": -23.0, "distance": 6.0, "cooldown": 0.28, "priority": 2, "concurrency": 2},
	"prop_rod_take": {"streams": WOOD, "volume_db": -26.0, "distance": 4.0, "cooldown": 0.15, "priority": 2, "concurrency": 2},
	"prop_rod_return": {"streams": WOOD, "volume_db": -24.0, "distance": 4.0, "cooldown": 0.2, "priority": 2, "concurrency": 2},
	"prop_fish_land": {"streams": SOFT, "volume_db": -22.0, "distance": 6.0, "cooldown": 0.45, "priority": 2, "concurrency": 2},
	"prop_serve": {"streams": CERAMIC, "volume_db": -24.0, "distance": 5.0, "cooldown": 0.18, "priority": 2, "concurrency": 2},
	"prop_grill": {"streams": GRILL_START, "volume_db": -20.0, "distance": 6.0, "cooldown": 0.35, "priority": 2, "concurrency": 2},
	"prop_cook_toggle": {"streams": SWITCH, "volume_db": -24.0, "distance": 4.0, "cooldown": 0.18, "priority": 2, "concurrency": 2},
	"prop_cook_finish": {"streams": PAN, "volume_db": -28.0, "distance": 4.0, "cooldown": 0.4, "priority": 1, "concurrency": 1},
	"prop_pan_place": {"streams": PAN, "volume_db": -24.0, "distance": 5.0, "cooldown": 0.15, "priority": 2, "concurrency": 2},
	"prop_clothing": {"streams": CLOTH, "volume_db": -22.0, "distance": 3.0, "cooldown": 0.25, "priority": 2, "concurrency": 2},
	"prop_blanket": {"streams": CLOTH, "volume_db": -20.0, "distance": 4.0, "cooldown": 0.3, "priority": 2, "concurrency": 2},
	"prop_rest": {"streams": CLOTH, "volume_db": -26.0, "distance": 4.0, "cooldown": 0.35, "priority": 1, "concurrency": 2},
	"prop_furniture": {"streams": FURNITURE, "volume_db": -23.0, "distance": 7.0, "cooldown": 0.6, "priority": 1, "concurrency": 2},
	"prop_contact_cloth": {"streams": CLOTH, "volume_db": -29.0, "distance": 2.5, "cooldown": 0.8, "priority": 1, "concurrency": 2},
	"prop_door_open": {"streams": DOOR_OPEN, "volume_db": -21.0, "distance": 10.0, "cooldown": 0.6, "priority": 2, "concurrency": 3},
	"prop_door_close": {"streams": DOOR_CLOSE, "volume_db": -22.0, "distance": 10.0, "cooldown": 0.6, "priority": 2, "concurrency": 3},
	"prop_lamp": {"streams": SWITCH, "volume_db": -25.0, "distance": 4.0, "cooldown": 0.2, "priority": 2, "concurrency": 2},
	"prop_spray": {"streams": SPRAY, "volume_db": -22.0, "distance": 4.0, "cooldown": 0.44, "priority": 2, "concurrency": 2},
	"prop_coins": {"streams": COIN, "volume_db": -26.0, "distance": 4.0, "cooldown": 0.35, "priority": 2, "concurrency": 2},
	"prop_rope": {"streams": ROPE, "volume_db": -26.0, "distance": 4.0, "cooldown": 0.25, "priority": 2, "concurrency": 2},
	"prop_balloon_gate": {"streams": FURNITURE, "volume_db": -25.0, "distance": 6.0, "cooldown": 0.45, "priority": 2, "concurrency": 2},
	"prop_balloon_land": {"streams": SOFT, "volume_db": -20.0, "distance": 12.0, "cooldown": 0.8, "priority": 2, "concurrency": 2},
	"prop_burner": {"streams": STEAM, "volume_db": -28.0, "distance": 12.0, "cooldown": 0.7, "priority": 1, "concurrency": 1},
	"prop_vent": {"streams": STEAM, "volume_db": -28.0, "distance": 12.0, "cooldown": 0.8, "priority": 1, "concurrency": 1},
	"prop_train_stop": {"streams": STEAM, "volume_db": -25.0, "distance": 35.0, "cooldown": 2, "priority": 1, "concurrency": 1},
	"prop_train_departure": {"streams": WHISTLE, "volume_db": -26.0, "distance": 55.0, "cooldown": 5, "priority": 1, "concurrency": 1},
	"prop_train_door": {"streams": METAL, "volume_db": -29.0, "distance": 12.0, "cooldown": 0.6, "priority": 1, "concurrency": 1},
	"prop_ui_confirm": {"streams": SELECT, "volume_db": -33.0, "distance": 2.0, "cooldown": 0.1, "priority": 2, "concurrency": 1},
	"prop_ui_back": {"streams": SWITCH, "volume_db": -34.0, "distance": 2.0, "cooldown": 0.12, "priority": 2, "concurrency": 1},
	"prop_sizzle_loop": {"streams": SIZZLE, "volume_db": -19.0, "distance": 7.0, "cooldown": .1, "priority": 1, "concurrency": 2, "loop": true, "pitch_min": 1.0, "pitch_max": 1.0},
	"prop_simmer_loop": {"streams": SIMMER, "volume_db": -20.0, "distance": 7.0, "cooldown": .1, "priority": 1, "concurrency": 2, "loop": true, "pitch_min": 1.0, "pitch_max": 1.0},
	"prop_burner_loop": {"streams": FIRE, "volume_db": -21.0, "distance": 16.0, "cooldown": .1, "priority": 1, "concurrency": 2, "loop": true, "pitch_min": 1.0, "pitch_max": 1.0},
	# The player's mailbox (world/letters/courier/player_mailbox.gd): a small tin door and flag, so
	# the metal recordings pitched up; a letter going in or coming out is the paper ones.
	"prop_mailbox_open": {"streams": METAL, "volume_db": -25.0, "distance": 8.0, "cooldown": 0.5, "priority": 2, "concurrency": 1, "pitch_min": 1.2, "pitch_max": 1.35},
	"prop_mailbox_close": {"streams": METAL, "volume_db": -23.0, "distance": 8.0, "cooldown": 0.5, "priority": 2, "concurrency": 1, "pitch_min": 0.95, "pitch_max": 1.08},
	"prop_mailbox_flag": {"streams": METAL, "volume_db": -28.0, "distance": 6.0, "cooldown": 0.5, "priority": 2, "concurrency": 1, "pitch_min": 1.5, "pitch_max": 1.7},
	"prop_mailbox_letter": {"streams": PAPER, "volume_db": -22.0, "distance": 5.0, "cooldown": 0.2, "priority": 2, "concurrency": 2},
	# Applejack's apple wagon (world/mechanics/wagon_wheel/): the wheel giving way (the tree-wood
	# crack), the body dropping onto its axle (furniture, pitched down), and the spare going on.
	"prop_wagon_crack": {"streams": TREE, "volume_db": -12.0, "distance": 35.0, "cooldown": 1.0, "priority": 1, "concurrency": 1, "pitch_min": 0.85, "pitch_max": 0.95},
	"prop_wagon_drop": {"streams": FURNITURE, "volume_db": -12.0, "distance": 35.0, "cooldown": 0.3, "priority": 1, "concurrency": 2, "pitch_min": 0.6, "pitch_max": 0.72},
	"prop_wagon_fit": {"streams": WOOD, "volume_db": -15.0, "distance": 16.0, "cooldown": 0.15, "priority": 1, "concurrency": 2, "pitch_min": 0.75, "pitch_max": 0.9},
	"prop_wagon_apple": {"streams": SOFT, "volume_db": -24.0, "distance": 10.0, "cooldown": 0.08, "priority": 3, "concurrency": 3, "pitch_min": 1.1, "pitch_max": 1.4},
}

static func material_for_item(item_id: String) -> String:
	var name := item_id.to_lower()
	if name.begins_with("book:") or name.contains("notebook") or name.contains("recipe-card"): return "paper"
	if name.begins_with("wear:") or name.begins_with("outfit:") or name.contains("blanket") or name.contains("scarf") or name.contains("sock"): return "cloth"
	if name.contains("glass") or name.contains("cider") or name.contains("juice") or name.contains("bottle"): return "glass"
	if name.contains("tea") or name.contains("coffee") or (name.contains("cup") and not name.contains("cupcake")) or name.contains("bowl") or name.contains("soup") or name.contains("smoothie"): return "ceramic"
	if name.begins_with("food:") or name in ["apple", "carrot", "banana", "river-fish"]: return "soft"
	if name.contains("sandals") or name.contains("pan") or name.contains("tool") or name.contains("coin"): return "metal"
	return "wood"

static func food_cue_for_item(item_id: String) -> String:
	var name := item_id.to_lower()
	if name.contains("cider") or name.contains("juice") or name.contains("coffee") or name.ends_with("-tea") or name.contains("tea-cup") or name.contains("smoothie") or name.contains("nectar") or name.contains("soup"): return "prop_sip"
	if name.contains("carrot") and not name.contains("pancake") and not name.contains("dog"): return "prop_bite_carrot"
	if name == "apple" or name.contains("candy-apple") or name.contains("lettuce") or name.contains("cherries") or name.contains("berry") or name.contains("mushroom"): return "prop_bite_crisp"
	return "prop_bite_soft"
