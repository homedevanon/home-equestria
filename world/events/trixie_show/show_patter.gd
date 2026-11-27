extends RefCounted
## Trixie's stage patter: at each moment of the show the director generates one short line from
## a purpose (never a script) through its normal intent queue, voice and speech bubble. One AI
## round trip per moment, about 10-12 per show (opening speech, each trick, the pause between
## tricks, finale, bow); shows are rare (3 % of days, 7-day cooldown). Skipped quietly while the
## player is out of earshot (the show goes on without words then), or without AI. Her lines are
## firm (dev 2026-10-28): Anon cannot cut one off, his words wait for its end, and a newer line
## replaces one she never got to say.

const SITUATION := "[Observed situation, not player speech] You are on the schoolhouse stage, putting on your magic show for a crowd of ponies%s. "
const PURPOSE := {
	"speech_open": "Alone on stage as the spotlights hit you, kick off your show in two sentences. Introduce yourself as The Great and Powerful Trixie with full showmare flair and welcome Ponyville.",
	"speech_promise": "Keep going with your opening speech in two or three sentences. Promise the crowd wonders they have never seen before, dare any doubters to keep watching, and finish by announcing your first trick, %s.",
	"interlude": "The crowd is cheering for your last trick (%s). Take a bow and soak it in, then tease what you have coming up next (%s) in two short sentences.",
	"cards": "You float a full deck of cards into spinning rings and stars above the stage. Brag about it to the crowd in one short sentence.",
	"pick_card": "Float a card from your deck out to %s in the crowd to look at before you pull it from your hat. Speak to them in one short sentence.",
	"doves": "Doves burst from your magician's hat. Present the trick grandly in one short sentence.",
	"rings": "Your linking rings float around you and lock together in mid-air. Boast about it in one short sentence.",
	"vanish": "You step into your magic box to vanish. Build suspense in one short line.",
	"vanish_reveal": "After vanishing from the box, you reappear right behind the audience. Gloat in one short sentence.",
	"cannon_ask": "You've wheeled out your cannon and Anon is watching. Ask him to be your human cannonball; he just needs to walk up to the cannon. One or two short sentences.",
	"cannon_declined": "Anon didn't come up to be your human cannonball. Brush it off with flair in one short sentence.",
	"cannon_fire": "Anon is in your cannon. Count down as you light the fuse. One short sentence.",
	"cannon_land": "Your cannon just shot Anon over the crowd into a hay pile. React in one short sentence.",
	"finale": "Your grand finale is starting. Announce it in one short sentence.",
	"mishap": "A mishap on stage, %s. React in one short sentence as Trixie, embarrassed yet saving your pride.",
	"closing": "The show is over. Verbally take a bow and thank your adoring fans in your usual boastful way. One short sentence.",
}

var runtime: Node
var session: Dictionary
var _count := 0

func _init(owner_node: Node) -> void:
	runtime = owner_node
	session = runtime.show

var _last_key := ""

## Queues her line for this moment; `finished` runs once it was spoken to the end. False when no
## line is coming (no AI, Anon out of earshot).
func say(key: String, detail := "", finished := Callable()) -> bool:
	var director: Node = runtime.game.get("director") if runtime.game != null else null
	if director == null or not director.has_method("queue_generated_intent") or not PURPOSE.has(key): return false
	if not runtime._near_stage(runtime.EARSHOT): return false
	# A line she never got to say is stale by now (Anon talked over the show): drop it, unless
	# she is saying it right now.
	if _last_key != "" and str(director.get("_authored_active")) != _last_key and director.has_method("cancel_authored_line"):
		director.cancel_authored_line(_last_key)
	var crowd := ""
	if runtime.audience != null:
		var n: int = runtime.audience.watching_ids().size()
		crowd = " (%d watching)" % n if n > 0 else " (hardly anypony came)"
	var purpose: String = PURPOSE[key]
	var parts := detail.split("|")
	var count := purpose.count("%s")
	if count == 1: purpose = purpose % (detail if not detail.is_empty() else "somepony")
	elif count == 2: purpose = purpose % [parts[0], parts[1] if parts.size() > 1 else "the next trick"]
	_count += 1
	var day := int(runtime.show.get("day", 0))
	var show_key := "trixie_show:%d:%s:%d" % [day, key, _count]
	var valid := func() -> bool: return is_instance_valid(runtime) and runtime.owns_show(session) and runtime.trixie() != null
	if not director.queue_generated_intent(runtime.TRIXIE, SITUATION % crowd + purpose, show_key, valid, finished, false, true): return false
	_last_key = show_key
	return true
