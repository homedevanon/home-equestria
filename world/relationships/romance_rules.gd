extends RefCounted
## Relationship overhaul (docs/THREAD_FIX_RELATIONSHIP_2026_11_19.md; dev 2026-11-15: "It shouldn't
## be hard-locked ... The llm SHOULD have agency"). What counts toward love from game facts, the
## tolerant readers for what she and Anon actually said, and the numbers of the casual/committed
## split. Pure data and functions; player_bonds.gd and relationship_runtime.gd apply them.

## Rollback switch. false brings back the 0.3.1 behaviour: love only from the model's [romance] tags,
## no reading of her words for a yes or a kiss invitation, no casual/committed tracking, dates counted
## only while the game itself steers her, and her yes held to the same gates as her own offers.
const FACTS := true

## Relationship overhaul 2026-11-21: how often a reader below was called. With bond_rules.gd DYNAMIC
## on, nothing calls them (tools/relationships/test_bond_old_readers.gd counts it).
static var reads := 0

## Love from what actually happened, in romance points before the relationship pace. Every gain still
## passes pony_impressions.gd: nothing before Friend, the per-sitting budget and the per-day limit.
## [amount, minimum real seconds between two of that kind for one pony].
const LOVE := {
	"romantic_talk": [1, 60.0],   # he was romantic and her reply was warm, but carried no romance tag
	"kiss": [1, 300.0],           # a kiss she returned
	"her_kiss": [2, 300.0],       # a kiss she chose herself
	"affection": [1, 600.0],      # a welcomed hug or a held hoof
	"gift": [1, 0.0],             # a gift or food she accepted (once a game day, GIFT_DAYS)
	"activity": [1, 0.0],         # a shared activity (walk, meal, fishing...); its own cooldowns apply
	"date": [2, 0.0],             # an agreed date kept
	"together": [1, 0.0],         # every TOGETHER_LOVE_S spent near each other
	"intimacy": [2, 0.0],         # committed intimacy an adult mod reports (casual adds none)
}
const GIFT_DAYS := 1.0
const TOGETHER_LOVE_S := 1200.0

## Agreed plans (outings and dates): how long after the yes the plan stays open, how long together
## completes any plan whatever the activity, and how near counts as together.
const PLAN_SECONDS := 1800.0
const PLAN_TOGETHER_S := 240.0
const PLAN_NEAR_M := 8.0

## A warm moment: she tagged romance or kissed him within this many seconds, so a kiss is welcome.
const WARM_SECONDS := 600.0
## Her spoken kiss invitation: the window and number of kisses it covers.
const KISS_INVITE_SECONDS := 180.0
const KISS_INVITE_USES := 3
## "Just now" moments in her prompt: their age limit and how many.
const MOMENT_SECONDS := 600.0
const MOMENTS := 3
## Flings: casual intimacy with this many different mares within FLING_DAYS game days makes town talk.
const FLING_DAYS := 7.0
const FLING_TALK := 3

## Anon being romantic: compliments, confessions, asking her out, tenderness. Lower-case text.
const ROMANTIC := [
	"\\byou('re| are| look| looked| seem)( so| really| very| truly| absolutely| quite| just)? (beautiful|gorgeous|pretty|cute|lovely|adorable|stunning|radiant|charming|perfect|wonderful|amazing)\\b",
	"\\bi (really |truly )?(love|adore|fancy|missed|miss) you\\b|\\bi('ve| have) (got |had )?(a crush|feelings) (on|for) you\\b|\\b(falling|fallen|fell) for you\\b|\\bi really like you\\b",
	"\\byour (eyes|mane|smile|coat|voice|laugh|tail|face|lips) (is|are|look|looks)\\b",
	"\\b(sweetheart|darling|my dear|beautiful|gorgeous|be mine|my heart|kiss|on a date|date with me|go out with me|marry me|be my (mare|girl|colt|boy)friend|hold you|cuddle)\\b",
]
## Her reply turns him down or hedges (any of these, and her yes is not read as a yes).
const REFUSALS := [
	"\\bno\\b(?!,? doubt)(?! one)(?! other)(?! way!)",
	"\\bnot (ready|yet|now|sure|so sure|right now|like that|that way|today|tonight)\\b",
	"\\b(just|only) friends\\b",
	"\\b(can't|cannot|couldn't|won't|wouldn't|shouldn't) (be|do|say|go|date|accept|kiss|right now)\\b",
	"\\b(don't|do not) (think|want|feel|know)\\b",
	"\\btoo (soon|fast|quick|early)\\b", "\\brather not\\b", "\\bneed (some |more )?time\\b",
	"\\blet's (wait|not|slow)\\b", "\\bslow down\\b", "\\bmaybe\\b", "\\bperhaps\\b", "\\bi'm (sorry|afraid)\\b", "\\bsorry\\b",
	"\\bhold on\\b", "\\bwhoa\\b", "\\bnot so fast\\b",
]
const YES := "\\b(yes|yeah|yep|yess+|of course|absolutely|definitely|certainly|gladly|i'd love (to|that)|i would love (to|that)|i'd like that|i would like that|i accept|you bet|i thought you'd never ask|nothing would make me happier|i'd be (happy|honored|honoured|delighted|glad) to|i'm yours|be yours|i'd be your|i'll be your|i will be your|i'd love to be your)\\b"
## Her invitation to kiss, in her own words.
const KISS_INVITE := "\\b(kiss me|give me a kiss|gimme a kiss|how about a kiss|may i kiss you|can i kiss you|could i kiss you|let me kiss you|i (want|wanna|need) to kiss you|i'd (like|love) to kiss you|(want|wanna) (to )?kiss me|pucker up|plant one on me|smooch me|kiss me again|another kiss|one more kiss|kiss you|i (did |do |really )?want(ed)? (that|the|your|a) kiss)\\b"
const KISS_NOT := "\\b(don't|do not|won't|will not|never|not|no|stop|without) (\\w+ ){0,2}(kiss|smooch)"
## She asks him out herself in words (a question to him).
const HER_ASK := "\\b(be my (coltfriend|boyfriend|stallionfriend|marefriend|girlfriend|special somepony|very special somepony)|go out with me|go steady with me|start dating|be (a couple|together) with me|be mine)\\b"

static func _any(text: String, patterns: Array) -> bool:
	for pattern: String in patterns:
		if RegEx.create_from_string(pattern).search(text) != null: return true
	return false

static func lower(text: String) -> String:
	return text.to_lower().replace("’", "'").replace("‘", "'")

## Anon said something romantic to her.
static func romantic(said: String) -> bool:
	reads += 1
	return not said.strip_edges().is_empty() and _any(lower(said), ROMANTIC)

## Her words read as a clear yes: a yes and no refusal or hedge anywhere in the line.
static func says_yes(speech: String) -> bool:
	reads += 1
	var line := lower(speech)
	return RegEx.create_from_string(YES).search(line) != null and not _any(line, REFUSALS)

## She invites a kiss in her own words, and does not negate it.
static func invites_kiss(speech: String) -> bool:
	reads += 1
	var line := lower(speech)
	return RegEx.create_from_string(KISS_INVITE).search(line) != null and RegEx.create_from_string(KISS_NOT).search(line) == null

## She asks him out herself: a question to him naming the step, not negated.
static func asks_out(speech: String) -> bool:
	reads += 1
	var line := lower(speech)
	if not line.contains("?") or _any(line, REFUSALS): return false
	for sentence: String in line.split("?", false):
		if RegEx.create_from_string(HER_ASK).search(sentence) != null and RegEx.create_from_string("\\b(don't|do not|won't|never|not)\\b").search(sentence) == null: return true
	return false

## Anon asks her out in words the strict request parser (relationship_intent.gd) does not take as
## the whole line, such as "I adore you. Want to make it official?" or "be my marefriend, please".
## Only ever used together with her plain yes in the same turn (relationship_runtime.gd _read_reply).
const HIS_ASK := "\\b(be my (marefriend|girlfriend|coltfriend|boyfriend|special somepony|very special somepony)|go out with me|go steady with me|start dating|date me|be (a couple|mine)|make (it|us|this|things) official|be official)\\b"
static func he_asks_out(said: String) -> bool:
	reads += 1
	for sentence: String in RegEx.create_from_string("[.!?\\n]+").sub(lower(said), "|", true).split("|", false):
		if RegEx.create_from_string(HIS_ASK).search(sentence) != null and RegEx.create_from_string("\\b(don't|do not|won't|never|not|no longer|stop)\\b").search(sentence) == null: return true
	return false

## Faces that show romance on her (hybrid_mare/face_poses.gd: "affectionate" draws heart eyes and a
## blush). Her reply wearing one is a warm moment, like a romance tag (thread 43714868: "She literally
## looked at me blushing with heart shaped pupils" and the game refused the kiss).
const WARM_FACES := ["affectionate"]

## An outing or date invitation in her words (for a generated offer she voiced without its tag).
static func invites(speech: String) -> bool:
	reads += 1
	var line := lower(speech)
	if _any(line, REFUSALS): return false
	return RegEx.create_from_string("\\b(would you like|do you want|want to|wanna|care to|how about|shall we|let's|will you|join me|come with me|with me\\?)\\b").search(line) != null

## The step an [agreed: ...] tag names, from the ways models write it; "" when it names none.
## "marry" is engagement here; player_bonds.agree() turns it into marriage once engaged.
const AGREED := {
	"dating": ["dating", "couple", "relationship", "together", "going_steady", "go_steady", "girlfriend", "boyfriend", "marefriend",
		"coltfriend", "stallionfriend", "partner", "partners", "romance", "lovers", "sweethearts", "new_couple", "going_out", "go_out",
		"be_my_marefriend", "be_your_marefriend", "be_my_coltfriend", "be_your_coltfriend", "be_your_girlfriend", "be_your_boyfriend",
		"special_somepony", "start_dating", "date_each_other", "official"],
	"date": ["date", "a_date", "date_night", "romantic_date", "dinner_date", "go_on_a_date"],
	"outing": ["outing", "picnic", "hangout", "hang_out", "walk", "stroll", "trip"],
	"move_in": ["move_in", "moving_in", "live_together", "living_together", "move_in_together", "cohabit", "share_a_home", "share_home"],
	"engagement": ["engagement", "engaged", "proposal", "propose", "marry", "marry_me", "fiance", "fiancee"],
	"marriage": ["marriage", "married", "wedding", "get_married", "wed"],
	"kiss": ["kiss", "a_kiss", "kisses", "smooch"],
	"hug": ["hug", "a_hug", "hugs", "embrace"],
}
static func agreed_kind(raw: String) -> String:
	var key := lower(raw).strip_edges().replace(" ", "_").replace("-", "_").trim_prefix("to_")
	for kind: String in AGREED:
		if key in AGREED[kind]: return kind
	return ""

## [relationship_answer: yes] or [relationship_answer: dating, yes]: the words models use for a yes or no.
const ANSWER_YES := ["yes", "true", "accept", "accepted", "y", "ok", "okay", "sure", "agree", "agreed", "yeah", "of_course", "gladly"]
const ANSWER_NO := ["no", "false", "decline", "declined", "refuse", "reject", "n", "nope", "not_now"]
