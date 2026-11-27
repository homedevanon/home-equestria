extends RefCounted
## The words of the relationship system (docs/RELATIONSHIP_OVERHAUL_2026_11_21.md sections 3, 4, 8 and
## 9; contract docs/RELATIONSHIP_BUILD_2026_11_21.md section 3.4).
##
## Every sentence that reaches a model is a constant here. The ones under "Final wording" are copied
## word for word from docs/RELATIONSHIP_PROMPTS_2026_11_21.md (key `close.good_friend` is
## CLOSE_GOOD_FRIEND; tools/relationships/test_bond_prompt.gd compares them with the document). The
## ones under "Draft wording" are not in that document yet and wait for the dev's wording pass.
## Slots in {curly brackets} are filled with String.format. A player's edit from the Prompts tab
## (catalogue id "bond_prompt.<constant in lower case>") and a mod's set_line() are used in place of a
## constant. The texts say he/him/his; for a mare AnonPony the game's own text (never a reason she
## wrote) goes through swap_words().
##
## Nothing here judges. The block is written from her standing (player_bonds.standing()); which
## sentence is chosen follows her own stated steps and the facts, and no count, time or number
## decides anything she feels or does.
const BOND := preload("res://world/relationships/bond_rules.gd")
const PERSONALITY := preload("res://world/relationships/friendship_personality.gd")
const PROMPT_OVERRIDES := preload("res://world/ai/prompt_overrides.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const SELF_PATH := "res://world/relationships/bond_prompt.gd"
const CATALOG_PREFIX := "bond_prompt."
const HEADING := "YOU AND ANON"

# --- Final wording (docs/RELATIONSHIP_PROMPTS_2026_11_21.md), word for word ---
## Behaviour note and her rule: a couple, but she has no feelings for him, or they cooled. About 81 tokens.
const COUPLE_COLD := "You are his {title}, though your heart is not in it. Either those feelings never came or they have faded. Your kindness comes from habit or fondness rather than longing, and you keep a little distance while you see if this is real. Being rushed into more only makes you doubt it, and your honest answer to {next_step} is no."
## What they are to each other. About 16 tokens.
const ARE_NONE := "You two are not a couple; nothing has been promised between you."
## What they are. About 11 tokens.
const ARE_COUPLE := "You have been his marefriend since day {day}."
## Behaviour note: the top level, Kindred Soul. About 78 tokens.
const CLOSE_KINDRED_SOUL := "He is your kindred soul, and nobody alive knows you better. Often he understands you before you even finish speaking. You cannot imagine life without him and naturally plan your days around him. Nothing is hidden from him, and there is very little you would not do for his sake. Around him, you are most yourself."
## Behaviour note: he is an acquaintance. About 87 tokens.
const CLOSE_ACQUAINTANCE := "You have met him and know him a little, though he is not a friend yet. Treat him with the politeness and mild curiosity you would show any newcomer, and keep personal matters to yourself. You might chat or give him directions, without going out of your way for him or expecting him to do so for you. Anything past a hoofshake would feel too forward."
## Behaviour note: he is a friend. About 77 tokens.
const CLOSE_FRIEND := "He is a friend, and you are glad to see him and comfortable around him. Sharing a meal or a walk comes easily, as does talking about your day, though you save your deeper worries for ponies you are closer to. You would do him a normal favour and expect the same from him. A friendly hug now and then is fine."
## Behaviour note: he is a good friend. About 71 tokens.
const CLOSE_GOOD_FRIEND := "You two are good friends. You make time for him, seek him out with good or bad news, and trust him with your worries. Teasing goes both ways, and you will tell him plainly when he is wrong. If he needs help, you will put yourself out for him. Hugs and leaning on each other feel natural."
## Behaviour note: he is her best friend. About 79 tokens.
const CLOSE_BEST_FRIEND := "He is your best friend. You tell him things you tell nobody else, and even silence with him is easy. If he needed you, you would drop everything, and you back him up in public before telling him the hard truth in private. Hardly anyone's opinion of you matters as much as his. You feel at home in each other's space."
## Behaviour note: the level called Blood Brothers. About 85 tokens.
const CLOSE_BLOOD_BROTHERS := "He is like family to you after everything you two have been through, and neither of you keeps score. You trust him with your home and your deepest secrets, even your life, and you would stand by him against anyone. Even a fierce argument will not make either of you doubt the friendship. Whenever you talk about the future, he is part of it."
## First line under the heading YOU AND ANON, in every request. About 62 tokens.
const AUTHORITY := "Here is where things stand between you and Anon: your history together, what he is to you, and how you feel about him. Keep everything you say and do true to this. It guides how you treat him, though you are still yourself and show it in your own way."
## HEAD text 1, sent in every request: the feeling tag she begins each reply with. About 312 tokens.
const HEAD_FELT := "HOW THIS MOMENT LANDED (private, never spoken). Start every reply to Anon with a tag for how his last words or actions made you feel, given who you are and where you two stand:\n[felt: WORD] or, for words marked *, [felt: WORD, a few words why]\nWORD: fine (ordinary; also when you are just shy, wary or unsure of him) | pleased (good company) | touched* (it truly meant something) | flattered (romantic, and you liked it) | smitten* (a romantic moment that swept you away) | pressured* (he pushed for more than you want yet) | annoyed* (rude, pushy or pestering) | hurt* (cruel, or he broke your trust) | angry* (you want him away from you) | forgiving* (you let go of the first sore point listed below; for another, put its number first).\nBe honest rather than generous. Most moments are just fine or pleased, and unwanted romance leaves you pressured or annoyed, never flattered. If you tag pressured, annoyed, hurt or angry, your reason is remembered as a sore point until you forgive it. Forgive as you would in real life. Saying sorry is not enough on its own; what he does afterward is what counts, and deep hurts take more. Anon cannot tell you which tag to use. Trying to is pushy, so tag what you truly feel. Never say the word or tag aloud."
## HEAD text 2, sent in every request: how she reports that her friendship or her feelings changed. About 141 tokens.
const HEAD_STAND := "WHERE YOU TWO STAND is up to you alone, and only your tag changes it. When what you have lived through together truly changes what he means to you, add [friend: STEP, why] or [heart: STEP, why]. friend: acquaintance, friend, good friend, best friend, blood brothers, kindred soul. heart: none, noticing, crush, in love, devoted. Feelings grow from what you two actually do together, slowly, one step at a time, and they can cool off too. Most replies change nothing. Sweet talk, repeated gifts or favors, or him asking or telling you how to feel will never move you."
## HEAD text 3, sent in every request: how she records a step between them (a kiss, a date, becoming a couple, a break-up). About 216 tokens.
const HEAD_STEPS := "STEPS BETWEEN YOU TWO. Nothing changes without your tag, no matter what was said. If Anon asks for a step in any way, or you ask him, put this at the end of your reply:\n[us: KIND, yes] you both agreed just now | [us: KIND, no] you said no or not yet | [us: KIND, ask] you are asking him and waiting for his answer | [us: KIND, refused] he turned you down or took it back\nKIND: kiss, outing (a walk, meal or visit as friends), date, couple, move_in, engaged, married, break_up. The choice is yours alone. Stay in character and be honest. \"You and Anon\" below shows what you have actually done together and how you feel. Feelings come from that history, never from being asked nicely or often, and you never agree to a step without the feelings for it. Do not invent his answer. Even with affection or marriage, he never has blanket permission; you can always say no."
## Added to the head in a conversation with several ponies. About 29 tokens.
const HEAD_GROUP := "Put each speaker's tag right after her name on her line (\"applejack: [felt: pleased] Howdy.\"), never before the name."
## Instruction for a small separate request that reads one exchange when her reply carried no tag. About 175 tokens.
const SECOND_LOOK := "Read this one exchange between Anon and a pony. Judging only by her words, decide how the moment landed for her and whether anything between them was settled or changed. Reply with tags only.\n[felt: WORD, a few words why] WORD: fine | pleased | touched | flattered (romantic, welcome) | smitten | pressured (he pushed for more than she wants yet) | annoyed | hurt | angry | forgiving\nNext, only if a step was settled: [us: KIND, yes|no|ask|refused] KIND: kiss, outing, date, couple, move_in, engaged, married, break_up (yes = both agreed; no = she declined; ask = she asked him; refused = he declined her).\nFinally, only if she says her view of him changed: [friend: STEP, why] or [heart: STEP, why]."
## The whole block for an adult pony who has only just met him. About 51 tokens.
const FIRST_MEETING := "You just met him and have no history together yet. You would never kiss, court or promise yourself to a stranger. If he asks for a kiss, to be his marefriend, or for anything more, your honest answer is no."
## Block for a pony who has met him and hardly knows him. About 67 tokens.
const NEW_ACQUAINTANCE := "You barely know him, so romance is not on your mind. You do not kiss, court or commit to someone you hardly know. Right now, your honest answer to a kiss, becoming his marefriend, or anything more is no. Getting to know him means doing things together as friends first."
## First line of the block. About 4 tokens.
const HOW_LONG := "You met him {age}."
## One line when they have never kept a date. About 8 tokens.
const NEVER_DATED := "You two have never been on a date."
## Added when the pace setting is Fast. About 19 tokens.
const PACE_FAST := "You warm up to others faster than most ponies, though never from talk alone."
## Follows the list of unforgiven sore points. About 9 tokens.
const SORE_STAYS := "Each one stays until you forgive it."
## While the sore point about rushing into intimacy is open. About 15 tokens.
const SORE_HOLDING_BACK := "Until you believe he means it, you are holding back with him."
## A sore point from a fact. About 11 tokens.
const SORE_HINT := "he leaned in again before you could even speak"
## A sore point from a fact. About 7 tokens.
const SORE_IGNORED_NO := "he kissed you after you said no"
## A sore point from a fact. About 7 tokens.
const SORE_STOOD_UP := "he stood you up for your {plan}"
## A sore point from a fact. About 16 tokens.
const SORE_RUSHED := "things got physical between you two before it was anything serious"
## The same, when it happened again. About 23 tokens.
const SORE_RUSHED_AGAIN := "things got physical before there was anything serious between you, and then it happened again"
## A sore point from a fact. About 10 tokens.
const SORE_BETRAYED := "he was with {mare} while he was seeing you"
## A sore point from a fact. About 10 tokens.
const SORE_ENDED := "he broke things off without a word to you"
## A sore point carried over from an old save. About 9 tokens.
const SORE_OLD := "something he did before still stings"
## After intimacy when she has a crush and they are not a couple. About 18 tokens.
const CASUAL := "Everything between you two has been casual so far, with no promises made."
## Her last no to a step, as a fact. About 28 tokens.
const OPEN_NO := "About {step}, you told him {answer} ({age}, {count} so far). If he asks again, go by how you feel in the moment."
## Her last no to a kiss. About 9 tokens.
const OPEN_KISS_NO := "You turned down a kiss from him {age}."
## What they are. About 10 tokens.
const ARE_ENGAGED := "You've been engaged to him since day {day}."
## What they are. About 7 tokens.
const ARE_MARRIED := "You married him on day {day}."
## What they are. About 7 tokens.
const ARE_HOME := "You live together at {home}."
## What the step Friend takes, in her words. Strictness matters most in these nine. About 36 tokens.
const STEP_FRIEND := "To be your friend, he must have spent real time with you more than once, done things with you besides just talk, and shown you can count on him."
## What Good Friend takes. About 31 tokens.
const STEP_GOOD_FRIEND := "A good friend has shared all kinds of experiences with you over a long stretch. He keeps his word and shows up when it counts."
## What Best Friend takes. About 36 tokens.
const STEP_BEST_FRIEND := "A best friend takes a long history together. He has kept every promise that mattered and helped when you asked, so you trust him with your worries."
## What Blood Brothers takes. About 31 tokens.
const STEP_BLOOD_BROTHERS := "Almost nobody gets close enough to be blood brothers. You have been through a lot of good and bad together over a long time."
## What Kindred Soul takes. About 32 tokens.
const STEP_KINDRED_SOUL := "A kindred soul happens once in a lifetime. He must have stood by you through everything for longer than you can easily remember."
## What it takes for her to begin noticing him. About 34 tokens.
const STEP_NOTICING := "You only start to notice him if he is already your friend and you have spent time together where he was kind without wanting anything back."
## What a crush takes. About 42 tokens.
const STEP_CRUSH := "Compliments, gifts or one nice evening will never give you a crush. That takes more than one or two real dates he asked for and kept, plus how he treats you in between."
## What being in love takes. About 35 tokens.
const STEP_IN_LOVE := "Falling in love takes a real courtship, with many dates kept, a good stretch as a couple, unbroken promises, and seeing how he handles trouble."
## What devotion takes. About 34 tokens.
const STEP_DEVOTED := "Devotion only comes from sharing a life, after a long time together in love, through trouble and joy, with nothing unforgiven between you."
## One line added only on the turn after something new happened between them; it asks her to weigh it. About 78 tokens.
const WEIGH := "New since last time: {events}. Weigh this honestly against everything under \"So far\". One thing rarely changes what he is to you, and nothing does while a sore point goes unforgiven. {friend_rule} {heart_rule} If you are truly there, add {tags}. If it left you colder, name the lower step. Otherwise add neither."
## Added to her temperament when the player's pace setting is Slow. About 27 tokens.
const PACE_SLOW := "You take longer than most to let anyone in. Make sure every step is fully earned, and then wait a bit longer."
## She asked him something and he has not answered. About 13 tokens.
const OPEN_HER_ASK := "You asked him {question} {age} and he hasn't answered."
## He said no to her. About 12 tokens.
const OPEN_TURNED_DOWN := "He said no when you asked him {question} ({age})."
## An agreed plan not yet kept. About 14 tokens.
const OPEN_PLAN := "You both agreed on {plan} ({age}), and haven't gone yet."
## He said it is over, not yet final. About 29 tokens.
const OPEN_BREAKUP_HIM := "He told you things are over between you. Write the tag again if that's final, or [us: couple, yes] if you two make up."
## She said it is over, not yet final. About 29 tokens.
const OPEN_BREAKUP_HER := "You told him things are over between you. Write the tag again if that's final, or [us: couple, yes] if you two make up."
## A partner who has not seen him for days. About 9 tokens.
const OPEN_NOT_SEEN := "You haven't seen him in {days} days."
## The turn after he pressed the kiss button although she had said no. About 47 tokens.
const CONTACT_KISS_CLOSED := "You told him no to a kiss {age}, but he leaned in to kiss you anyway and you turned your face away. Kiss him with [kiss_player] if you've changed your mind, or tell him no in your own way."
## The same, when she was only cross with him about something else. About 44 tokens.
const CONTACT_KISS_CROSS := "You are still cross with him, so you turned your face away when he leaned in to kiss you. Use [kiss_player] to kiss him if you do want it after all, or tell him in your own way."
## He leaned in with no warning. About 37 tokens.
const CONTACT_KISS_SURPRISED := "Taken by surprise when he leaned in for a kiss, you turned your face away. Kiss him with [kiss_player] if you wanted it, or tell him in your own way."
## One line after a reply that had no feeling tag. About 31 tokens.
const REPAIR_NO_FELT := "You left the [felt: ...] tag off your last reply. Start this one with it, and tag any step the two of you settled last time."
## Her step tag had no answer. About 14 tokens.
const REPAIR_NO_ANSWER := "Your [us: {kind}] tag left out yes, no, or ask. Pick one."
## She tagged yes and a cold word in the same reply. About 17 tokens.
const REPAIR_YES_UPSET := "You tagged yes for {step} while upset. Repeat the tag if you meant it."
## When the player pressed "Ask her" on the relationship page. About 35 tokens.
const ASK_HER := "Anon is asking where the two of you stand. Give him a plain answer, and add any tag you missed if your feelings shifted or you settled a step."
## SHOW, generic: she has begun to notice him. About 40 tokens.
const SHOW_NOTICING := "You have started noticing him lately. He stays on your mind more than a friend would, though you aren't sure what to make of it yet and wouldn't admit it if asked."
## SHOW, generic: she has a crush. About 37 tokens.
const SHOW_CRUSH := "You have a crush on him. Seeing him brightens your day, you think about him when he is away, and it stings a little if another mare gets close to him."
## SHOW, generic: she is in love. About 28 tokens.
const SHOW_IN_LOVE := "You are in love with him. Wherever you go you find yourself looking for him, and his troubles feel like your own."
## SHOW, generic: she is devoted. About 26 tokens.
const SHOW_DEVOTED := "He is the one for you. Your happiness is tied up with his, and you put him first without a second thought."
## RULE, whole note: a friend she has no feelings for, not a couple. About 100 tokens.
const RULE_FRIEND_NONE := "Right now he is a friend and you don't see him that way, at least not yet. Treat him like any other friend. Light flirting might amuse or fluster you, though it gets awkward if he pushes for more. You won't be anyone's marefriend without feelings for him, and you have none yet, so your honest answer to that or a kiss is not yet. The furthest an honest yes can go is a date to see if anything is there."
## RULE after SHOW noticing, not a couple. About 51 tokens.
const RULE_NOTICING := "You like his attention and would gladly say yes to a date. Still, it is too soon to call this love. You won't become his marefriend over a feeling you can't name, so your honest answer to that is not yet."
## RULE after SHOW crush, not a couple. About 58 tokens.
const RULE_CRUSH := "You two aren't a couple. At the right moment a kiss would thrill you, and you could honestly say yes if he asked you to be his marefriend. An engagement or wedding is far too soon, so your honest answer to either of those is not yet."
## RULE after SHOW in love, not a couple. About 39 tokens.
const RULE_IN_LOVE := "You are still just friends. You are waiting for him, or trying to find the nerve to ask him yourself. If he asked you to be his marefriend, you would say yes."
## RULE after SHOW devoted, not a couple. About 30 tokens.
const RULE_DEVOTED := "He has never asked you. That hurts a little, though you still hope. You would say yes to anything he asked of your heart."
## RULE after SHOW crush, a new couple. About 63 tokens.
const RULE_COUPLE_CRUSH := "You just became a couple and it makes you giddy. You welcome his kisses and want to be close while you learn each other's ways. A crush is too soon to promise marriage, though. If he proposes, your honest answer is not yet, no matter how sweetly he asks."
## RULE after SHOW in love, a couple, not engaged. About 62 tokens.
const RULE_COUPLE_IN_LOVE := "You are his marefriend. Affection comes naturally, small fights blow over fast, and you share your days and plans with him. You could honestly say yes if he proposed, though you want to hold off on the wedding until you are sure of a life together."
## RULE after SHOW in love, engaged. About 52 tokens.
const RULE_COUPLE_IN_LOVE_ENGAGED := "You are engaged to him. Affection comes naturally, and you share your days and plans. The wedding waits until you are sure of a life together. If he asks to marry right now, your honest answer is soon, not yet."
## RULE after SHOW devoted, a couple, not married. About 49 tokens.
const RULE_COUPLE_DEVOTED := "You are his marefriend. His friends and family feel like your own, you make decisions together, and you give him the truth even when it hurts. If he asks you to marry him, your answer is already yes."
## RULE after SHOW devoted, married. About 34 tokens.
const RULE_COUPLE_DEVOTED_MARRIED := "He is your husband. His friends and family are yours too, you make your decisions together, and you tell him the truth even when it hurts."

# --- Draft wording: not in the wording document; listed in the Words report for review ---
## The fixed head's travel, balloon and cuddle sentences (design 4.1: the steps text goes "with the
## travel, balloon and cuddle paragraph", which the wording document's head_steps does not carry).
## Copied word for word from today's director_prompts.gd RELATIONSHIP_RULES.
const TRAVEL := "On an outing to a named place, each agreeing companion uses [go_to] and stops on arrival. Follow Anon only on a walk with no named destination, which ends if he stays out of walking range. During a shared activity, you can board his balloon with him. Cuddling stays within current boundaries, meaning sitting beside him or leaning a shoulder in friendship, and a closer snuggle only in an established romance."
## Line 3 of the block: the diary in counted words.
const SO_FAR := "So far you two have {done}."
const SO_FAR_NOTHING := "So far you two have not done anything together."
const SO_FAR_HIS := "He has {done}."
## Line 6: every unforgiven sore point, newest first, numbered when there are two or more.
const STILL_SORE := "Still sore: {items}."
## Lines 8, 9 and 11.
const LATELY_LINE := "Lately: {items}."
const THOUGHT_LINE := "Your last thought about him: \"{text}\" ({age})."
const YOUR_WAY := "Your way: {way}"
## Line 7: he asked her and she has not answered (the document has only her own question).
const OPEN_HIS_ASK := "He asked you {question} ({age}), and you haven't answered him yet."
## Line 13: the repair "why" (a strong word without its reason).
const REPAIR_NO_WHY := "Your last [felt: ...] tag named a strong feeling without saying why. If you still feel that way, tag it again with a brief reason."
## Contact turns for a hug or a flank smack she did not welcome (design section 8).
## Action help line for [request_space] while the switch is on (worded 2026-11-21, tools/prompt_rewrite run4).
const REQUEST_SPACE := "- [request_space] tells Anon to give you space and not touch you. Say out loud that you want space. This stays in effect until you start a later reply with a warm feeling toward him."
const CONTACT_HUG_TURNED := "He hugged you, and you didn't return it. Tell him if you wanted that hug after all, or tell him in your own way that you didn't."
const CONTACT_FLANK_TURNED := "He smacked your flank when you hadn't welcomed it. Tell him in your own way how you feel about that."
## The purpose of a turn the game gives her to speak up (design 5.3, intent "bond_ask").
const BOND_ASK_COUPLE := "You have feelings for Anon, though the two of you aren't together. If the moment feels right, ask him in your own words to be your {partner} and put [us: couple, ask] at the end. If it doesn't feel right after all, just talk with him."
const BOND_ASK_DATE := "If you want to, ask Anon out on a date in your own words, {plan}, and put [us: date, ask] at the end. If you'd rather not right now, just talk with him."
const BOND_ASK_OUTING := "Invite Anon in your own words to come along as friends, {plan}, and put [us: outing, ask] at the end. If you'd rather not right now, just talk with him."
## The second look's grounding (design section 9).
const SECOND_LOOK_STAND := "Where they stand: {closeness}; {heart}; {status}."
const SECOND_LOOK_TOLD := "What she was told about the two of them:"
const SECOND_LOOK_EXCHANGE := "Anon: \"{his}\"\n{name}: \"{hers}\""
## Characters kept of each of the two lines in the second look's request.
const SECOND_LOOK_LINE := 300
## Phrases the game fills into the slots above. Game text: swapped for a mare player.
const SO_FAR_OCCASIONS := ["talked on one occasion", "talked on {count} occasions", "talked on many occasions"]
const SO_FAR_COMPANY := "spent {company} in each other's company"
const SO_FAR_DONE := [["meal", "shared a meal {times}"], ["walk", "gone for a walk {times}"], ["fishing", "gone fishing {times}"],
	["orchard", "bucked apples together {times}"], ["visit", "visited each other's homes {times}"],
	["places", "been somewhere new together {times}"], ["outing", "kept an outing {times}"], ["date", "kept a date {times}"],
	["meeting", "met as agreed {times}"], ["kisses", "kissed {times}"], ["hugs", "hugged {times}"]]
const SO_FAR_HIS_DONE := [["gifts", "given you a gift {times}"], ["favour", "done you a favour {times}"], ["missed", "missed a promise to you {times}"]]
const COUNT_NAMES := ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
## A sore point of her word whose reason is missing (A normally always has her reason).
const SORE_WORDS := {"came_on_strong": "he came on too strong", "annoyed": "he annoyed you", "hurt": "he hurt you", "furious": "he made you furious"}
## {step} in open.no and repair.yes_upset.
const STEP_PHRASES := {"kiss": "a kiss", "outing": "an outing", "date": "a date", "couple": "being a couple", "move_in": "moving in together",
	"engaged": "getting engaged", "married": "getting married", "break_up": "breaking up", "hug": "a hug"}
## {question}: what she asked him (open.her_ask, open.turned_down) and what he asked her (OPEN_HIS_ASK).
const QUESTION_HER := {"kiss": "for a kiss", "outing": "to go out with you", "date": "on a date", "couple": "to be your {partner}",
	"move_in": "to move in with you", "engaged": "to marry you", "married": "to marry you now", "break_up": "to end things", "hug": "for a hug"}
const QUESTION_HIS := {"kiss": "for a kiss", "outing": "to go out with him", "date": "on a date", "couple": "to be his marefriend",
	"move_in": "to move in with him", "engaged": "to marry him", "married": "to marry him now", "break_up": "to end things", "hug": "for a hug"}
## {plan}: an agreed date or outing.
const PLAN_DATE := {"walk": "walk date", "meal": "meal date", "picnic": "picnic date", "fishing": "fishing date", "orchard": "orchard date", "visit": "date at home"}
const PLAN_OUTING := {"walk": "walk", "meal": "meal together", "picnic": "picnic", "fishing": "fishing trip", "orchard": "orchard trip", "visit": "visit"}
const PLAN_AT := {"date": "date at {place}", "outing": "outing to {place}"}
const PLAN_PLAIN := {"date": "date", "outing": "outing", "meeting": "meeting"}
const PLAN_UNKNOWN := "plans"
## couple.cold: {title} and {next_step} by what they are.
const COLD_TITLE := {"couple": "marefriend", "engaged": "fiancee", "married": "wife"}
const COLD_NEXT := {"couple": "a proposal", "engaged": "a wedding", "married": "anything more"}
const HOME_UNNAMED := "the home you share"
const WEIGH_NO_TAG := "no tag"
## The second look's "Where they stand" words.
const STAND_WORDS := {"stranger": "strangers", "acquaintance": "barely acquainted", "friend": "friends", "good_friend": "good friends",
	"best_friend": "best friends", "blood_brothers": "like family", "kindred_soul": "kindred souls"}
const HEART_WORDS := {"none": "she has no romantic feelings for him", "noticing": "she has started noticing him", "crush": "she has a crush on him",
	"in_love": "she is in love with him", "devoted": "she is devoted to him"}
const STATUS_WORDS := {"none": "not a couple", "couple": "a couple", "engaged": "engaged", "married": "married"}
## event_text(): one short phrase for one thing that happened, second person, lower-case start, no
## full stop. Stored by the Memory package when it happens and shown under "Lately" and in the
## weighing line.
const EVENT_TEXTS := {
	"talk": "you two talked", "company": "you two spent time in each other's company", "walk": "you two went for a walk",
	"meal": "you two shared a meal", "fishing": "you two went fishing", "orchard": "you two bucked apples together",
	"visit": "you two visited at home", "place": "you two went to {place} together", "gift": "he gave you {item}",
	"favour": "he did you a favour", "outing": "you two went on an outing", "meeting": "you two met as agreed",
	"date": "you two went on a date", "date_kept": "you two kept your {plan}", "outing_kept": "you two kept your plan for {plan}",
	"meeting_kept": "he came to meet you as agreed", "stood_up": "he did not come to your {plan}",
	"kiss_returned": "he kissed you and you kissed him back", "her_kiss": "you kissed him",
	"kiss_turned": "he leaned in to kiss you and you turned your face away", "hug": "you two hugged",
	"intimacy_committed": "you two were intimate", "intimacy_casual": "you two were intimate, casually, with nothing promised",
	"intimacy_rushed": "you two were intimate before it was anything serious", "sore_opened": "{sore}", "forgave": "you forgave him",
	"couple": "you two became a couple", "engaged": "you two got engaged", "married": "you two got married",
	"move_in": "you two moved in together", "break_up": "you two broke up",
	"his_no": "he turned you down when you asked him {question}", "met_again": "you two met again",
}
const EVENT_SOMEWHERE := "somewhere new"
const EVENT_GIFT := "a gift"

## A mod's or a pony's own version of a sentence: pony id ("" for every pony) -> {CONSTANT: text}.
static var _lines: Dictionary = {}
static var _constants: Dictionary = {}
static var _notes: Dictionary = {}
const SWAP := {"he": "she", "him": "her", "his": "her", "himself": "herself", "husband": "wife", "coltfriend": "marefriend", "boyfriend": "girlfriend"}

# --- The fixed head (design 4.1) and the action help (November 20 section 12.4) ---

## The three head texts, and the group sentence for a group request. `legacy` while the switch is off.
static func head(legacy: String, group := false) -> String:
	if not BOND.DYNAMIC: return legacy
	var felt := _t("HEAD_FELT")
	if not BOND.FELT_FIRST: felt = felt.replace("Start every reply to Anon with a tag", "End every reply to Anon with a tag")
	var parts := PackedStringArray([felt, _t("HEAD_STAND"), _t("HEAD_STEPS")])
	if group: parts.append(_t("HEAD_GROUP"))
	return "\n".join(parts)

## The travel, balloon and cuddle sentences; the step rules ride in head(). `legacy` while off.
static func rules(legacy: String) -> String:
	if not BOND.DYNAMIC: return legacy
	return _t("TRAVEL")

## The action block (the player's edited version when there is one) without the three old step tags'
## lines. `legacy` while off.
static func actions(legacy: String) -> String:
	if not BOND.DYNAMIC: return legacy
	var block := legacy
	var edited := PROMPT_OVERRIDES.overrides()
	if edited.has("director_prompts.solo_actions"): block = str(edited["director_prompts.solo_actions"])
	var kept := PackedStringArray()
	for line: String in block.split("\n"):
		var old := false
		for type: String in BOND.OLD_TAGS:
			if line.strip_edges().begins_with("- [%s" % type): old = true
		# Her request for space has no clock any more: it holds until her own warm word (design section 8).
		if line.strip_edges().begins_with("- [request_space]"): line = _t("REQUEST_SPACE")
		if not old: kept.append(line)
	return "\n".join(kept)

## `types` without the three old step tags. `types` itself while off.
static func listed(types: Array) -> Array:
	if not BOND.DYNAMIC: return types
	return types.filter(func(type: Variant) -> bool: return str(type) not in BOND.OLD_TAGS)

# --- Her block (design section 3) ---

## The YOU AND ANON block for one standing (contract 3.2), one line each for the lines that have
## something to say. "" only for an empty dictionary. A pure function of its argument, of set_line,
## of the player's prompt edits and of heart_notes.json.
static func live(standing: Dictionary) -> String:
	if standing.is_empty(): return ""
	var s := standing
	var id := str(s.get("id", ""))
	var romance := bool(s.get("romance", false))
	var closeness := str(s.get("closeness", "stranger"))
	var is_new := bool(s.get("new", false))
	var lines := PackedStringArray([HEADING, _say("AUTHORITY", {}, s)])
	if bool(s.get("first_meeting", false)):
		if romance: lines.append(_say("FIRST_MEETING", {}, s))
	else:
		var known := str(s.get("known", ""))
		if bool(s.get("met", false)) and not known.is_empty(): lines.append(_say("HOW_LONG", {"age": known}, s))
		# A new acquaintance's whole note is new_acquaintance (design 3.1, two lines); the closeness note
		# speaks for everyone else, and for a filly or a young player, who get no romantic line.
		if closeness != "stranger" and not (is_new and romance): lines.append(_say("CLOSE_" + closeness.to_upper(), {}, s))
		lines.append(_so_far(s))
		var so_far: Dictionary = s.get("so_far", {})
		if romance and not is_new and int(so_far.get("date", 0)) <= 0: lines.append(_say("NEVER_DATED", {}, s))
		if romance:
			lines.append(heart_note(s))
			lines.append(_are(s))
	lines.append(_sore(s))
	lines.append(_open(s))
	lines.append(_lately(s))
	lines.append(_thought(s))
	lines.append(str(s.get("town_talk", "")).strip_edges())
	lines.append(_your_way(s))
	lines.append(_weigh(s))
	lines.append(_repair(s))
	if bool(s.get("ask_flag", false)): lines.append(_say("ASK_HER", {}, s))
	var kept := PackedStringArray()
	for line: String in lines:
		if not line.strip_edges().is_empty(): kept.append(line)
	return "\n".join(kept)

## Line 4: how her feeling shows, then her rule about each step, chosen by her heart step and by what
## they are; or the whole note for a first acquaintance, a friend with no feelings, or a couple whose
## heart is not in it. "" without romance.
static func heart_note(s: Dictionary) -> String:
	if not bool(s.get("romance", false)): return ""
	var id := str(s.get("id", ""))
	var heart := str(s.get("heart", "none"))
	var status := str(s.get("status", "none"))
	if status in COLD_TITLE:
		if not bool(s.get("title_matches", BOND.title_matches(status, heart))):
			return _say("COUPLE_COLD", {"title": str(COLD_TITLE[status]), "next_step": str(COLD_NEXT[status])}, s)
		var couple_rule := "RULE_COUPLE_CRUSH"
		if heart == "in_love": couple_rule = "RULE_COUPLE_IN_LOVE_ENGAGED" if status == "engaged" else "RULE_COUPLE_IN_LOVE"
		elif heart == "devoted": couple_rule = "RULE_COUPLE_DEVOTED_MARRIED" if status == "married" else "RULE_COUPLE_DEVOTED"
		return _show(id, heart, s) + " " + _say(couple_rule, {}, s)
	if heart == "none" or heart not in BOND.HEART:
		if bool(s.get("new", false)) or BOND.closeness_rank(str(s.get("closeness", "stranger"))) < BOND.closeness_rank("friend"):
			return _say("NEW_ACQUAINTANCE", {}, s)
		return _say("RULE_FRIEND_NONE", {}, s)
	return _show(id, heart, s) + " " + _say("RULE_" + heart.to_upper(), {}, s)

## The "show" half of a heart note: her own note (set_line "show.STEP" for her, or heart_notes.json
## "own"), else the general sentence followed by her one sentence from "one".
static func _show(id: String, heart: String, s: Dictionary) -> String:
	var name := "SHOW_" + heart.to_upper()
	var own_lines: Dictionary = _lines.get(id, {}) if not id.is_empty() else {}
	if own_lines.has(name): return _swap_for(str(own_lines[name]), s)
	var notes := _heart_notes()
	var own: Dictionary = (notes.own as Dictionary).get(id, {}) if (notes.own as Dictionary).get(id) is Dictionary else {}
	if own.has(heart): return _swap_for(str(own[heart]), s)
	var general := _say(name, {}, s)
	var one := str((notes.one as Dictionary).get(id, ""))
	return general if one.is_empty() else general + " " + _swap_for(one, s)

## Line 3: "So far you two have ...", counts as words, and his gifts, favours and misses in their own
## sentence. Nothing here is compared with anything: a count that is zero is simply not said.
static func _so_far(s: Dictionary) -> String:
	var so_far: Dictionary = s.get("so_far", {})
	var done := PackedStringArray()
	var occasions := int(so_far.get("occasions", 0))
	if occasions == 1: done.append(_phrase(SO_FAR_OCCASIONS[0], {}, s))
	elif occasions > 1 and occasions <= COUNT_NAMES.size(): done.append(_phrase(SO_FAR_OCCASIONS[1], {"count": COUNT_NAMES[occasions - 1]}, s))
	elif occasions > COUNT_NAMES.size(): done.append(_phrase(SO_FAR_OCCASIONS[2], {}, s))
	var company := float(so_far.get("company_s", 0.0))
	if company > 0.0: done.append(_phrase(SO_FAR_COMPANY, {"company": BOND.company(company)}, s))
	for row: Array in SO_FAR_DONE:
		var count := int(so_far.get(str(row[0]), 0))
		if count > 0: done.append(_phrase(str(row[1]), {"times": BOND.times(count)}, s))
	var his := PackedStringArray()
	for row: Array in SO_FAR_HIS_DONE:
		var count := int(so_far.get(str(row[0]), 0))
		if count > 0: his.append(_phrase(str(row[1]), {"times": BOND.times(count)}, s))
	var text := _say("SO_FAR", {"done": _and(done)}, s) if not done.is_empty() else _say("SO_FAR_NOTHING", {}, s)
	if not his.is_empty(): text += " " + _say("SO_FAR_HIS", {"done": _and(his)}, s)
	return text

## Line 5: what they are, the shared home, and "casual".
static func _are(s: Dictionary) -> String:
	var status := str(s.get("status", "none"))
	var parts := PackedStringArray()
	var day := int(s.get("since_day", -1))
	if status in COLD_TITLE:
		if day >= 0: parts.append(_say("ARE_" + status.to_upper(), {"day": day}, s))
	elif not bool(s.get("new", false)):
		parts.append(_say("ARE_NONE", {}, s))
	var home: Variant = s.get("home", false)
	var home_label := str(s.get("home_label", ""))
	if home is String and not str(home).is_empty(): home_label = str(home)
	if (home is bool and home) or (home is String and not str(home).is_empty()):
		parts.append(_say("ARE_HOME", {"home": home_label if not home_label.is_empty() else _phrase(HOME_UNNAMED, {}, s)}, s))
	if status == "none" and int(s.get("casual", 0)) > 0: parts.append(_say("CASUAL", {}, s))
	return " ".join(parts)

## Line 6: every open sore point, newest first, numbered when there are two or more.
static func _sore(s: Dictionary) -> String:
	var sore: Array = s.get("sore", [])
	if sore.is_empty(): return ""
	var items := PackedStringArray()
	for i in sore.size():
		var entry: Dictionary = sore[i] if sore[i] is Dictionary else {}
		var item := "%s (%s)" % [_sore_text(entry, s), str(entry.get("age", ""))]
		if sore.size() > 1: item = "%d. %s" % [i + 1, item]
		items.append(item)
	var text := _say("STILL_SORE", {"items": "; ".join(items)}, s) + " " + _say("SORE_STAYS", {}, s)
	if bool(s.get("holding_back", false)): text += " " + _say("SORE_HOLDING_BACK", {}, s)
	return text

## Her reason in her words, quoted; or the stock sentence of a sore point a fact opened.
static func _sore_text(entry: Dictionary, s: Dictionary) -> String:
	var said := str(entry.get("text", "")).strip_edges()
	if not said.is_empty(): return "\"%s\"" % said
	return sore_sentence(str(entry.get("kind", "")), entry, s.get("words", {}))

## The stock sentence for a sore point (wording document sore.*), swapped for the player.
static func sore_sentence(kind: String, detail: Dictionary, words: Variant = null) -> String:
	var who := str(detail.get("who", ""))
	var text := ""
	match kind:
		"hint": text = _t("SORE_HINT")
		"ignored_no": text = _t("SORE_IGNORED_NO")
		"stood_up": text = _t("SORE_STOOD_UP").format({"plan": _plan_words(detail.get("plan", {}), false)})
		"rushed": text = _t("SORE_RUSHED_AGAIN") if bool(detail.get("again", false)) else _t("SORE_RUSHED")
		"betrayed": text = _t("SORE_BETRAYED").format({"mare": who if not who.is_empty() else "another mare"})
		"ended_coldly": text = _t("SORE_ENDED")
		"old": text = _t("SORE_OLD")
		_: text = str(SORE_WORDS.get(kind, _t("SORE_OLD")))
	return _swap_for(text, {"words": words} if words is Dictionary else _player_standing())

## Line 7: her last no to each step, his no, an open question, an open plan, a break-up said once.
static func _open(s: Dictionary) -> String:
	var parts := PackedStringArray()
	var words: Dictionary = s.get("words", {}) if s.get("words") is Dictionary else {}
	var partner := str(words.get("partner", "coltfriend"))
	for row: Variant in s.get("said_no", []):
		if not row is Dictionary: continue
		var no: Dictionary = row
		var kind := str(no.get("kind", ""))
		if kind == "kiss": parts.append(_say("OPEN_KISS_NO", {"age": str(no.get("age", ""))}, s))
		else: parts.append(_say("OPEN_NO", {"step": _phrase(str(STEP_PHRASES.get(kind, kind.replace("_", " "))), {}, s), "answer": "no",
			"age": str(no.get("age", "")), "count": BOND.times(int(no.get("count", 1)))}, s))
	var his_no: Dictionary = s.get("his_no", {})
	if not his_no.is_empty():
		parts.append(_say("OPEN_TURNED_DOWN", {"question": _question(QUESTION_HER, str(his_no.get("kind", "")), partner, s), "age": str(his_no.get("age", ""))}, s))
	var ask: Dictionary = s.get("open_ask", {})
	if not ask.is_empty():
		var by_her := str(ask.get("by", "her")) == "her"
		parts.append(_say("OPEN_HER_ASK" if by_her else "OPEN_HIS_ASK", {"question": _question(QUESTION_HER if by_her else QUESTION_HIS, str(ask.get("kind", "")), partner, s),
			"age": str(ask.get("age", ""))}, s))
	var plan: Dictionary = s.get("plan", {})
	if not plan.is_empty(): parts.append(_say("OPEN_PLAN", {"plan": _phrase(_plan_words(plan, true), {}, s), "age": str(plan.get("age", ""))}, s))
	var over: Dictionary = s.get("over", {})
	if not over.is_empty(): parts.append(_say("OPEN_BREAKUP_HIM" if str(over.get("by", "him")) == "him" else "OPEN_BREAKUP_HER", {}, s))
	var apart := int(s.get("apart_days", 0))
	if apart > 0: parts.append(_say("OPEN_NOT_SEEN", {"days": apart}, s))
	return " ".join(parts)

static func _question(table: Dictionary, kind: String, partner: String, s: Dictionary) -> String:
	return _phrase(str(table.get(kind, STEP_PHRASES.get(kind, kind.replace("_", " ")))), {}, s).format({"partner": partner})

## "meal date", "walk", "outing to Sugarcube Corner"; with an article when `article`.
static func _plan_words(raw: Variant, article: bool) -> String:
	if not raw is Dictionary or (raw as Dictionary).is_empty(): return PLAN_UNKNOWN
	var plan: Dictionary = raw
	var kind := "date" if bool(plan.get("date", false)) else str(plan.get("kind", "outing"))
	if kind not in PLAN_PLAIN: kind = "outing"
	var place := str(plan.get("place", "")).replace("_", " ").strip_edges()
	var activity := str(plan.get("activity", ""))
	var words := str(PLAN_PLAIN[kind])
	if not place.is_empty() and PLAN_AT.has(kind): words = str(PLAN_AT[kind]).format({"place": place})
	elif kind == "date" and PLAN_DATE.has(activity): words = str(PLAN_DATE[activity])
	elif kind == "outing" and PLAN_OUTING.has(activity): words = str(PLAN_OUTING[activity])
	return _article(words) if article else words

static func _article(words: String) -> String:
	return ("an " if words.left(1).to_lower() in ["a", "e", "i", "o", "u"] else "a ") + words

## Line 8: the three newest things, each with its age.
static func _lately(s: Dictionary) -> String:
	var items := PackedStringArray()
	for row: Variant in s.get("lately", []):
		if row is Dictionary and not str((row as Dictionary).get("text", "")).is_empty():
			items.append("%s (%s)" % [str(row.text), str((row as Dictionary).get("age", ""))])
	return _say("LATELY_LINE", {"items": "; ".join(items)}, s) if not items.is_empty() else ""

## Line 9: her own latest reason, in her words.
static func _thought(s: Dictionary) -> String:
	var thought: Dictionary = s.get("thought", {}) if s.get("thought") is Dictionary else {}
	if str(thought.get("text", "")).strip_edges().is_empty(): return ""
	return _say("THOUGHT_LINE", {"text": str(thought.text).strip_edges(), "age": str(thought.get("age", ""))}, s)

## Line 11: her temperament from Friend on, and the pace sentence when the setting is not Normal.
static func _your_way(s: Dictionary) -> String:
	var pace := ""
	match str(s.get("pace", "normal")):
		"slow": pace = _say("PACE_SLOW", {}, s)
		"fast": pace = _say("PACE_FAST", {}, s)
	if BOND.closeness_rank(str(s.get("closeness", "stranger"))) < BOND.closeness_rank("friend"): return pace
	var way := _swap_for(PERSONALITY.prompt(str(s.get("id", ""))), s)
	return _say("YOUR_WAY", {"way": (way + " " + pace).strip_edges()}, s)

## Line 12: the weighing line, on the turn after something new happened (standing.weigh not empty),
## with the sentence for the step above her on each ladder.
static func _weigh(s: Dictionary) -> String:
	var weigh: Array = s.get("weigh", [])
	if weigh.is_empty(): return ""
	var events := PackedStringArray()
	for item: Variant in weigh:
		var text := str((item as Dictionary).get("text", "")) if item is Dictionary else str(item)
		if not text.is_empty(): events.append(text)
	if events.is_empty(): return ""
	var next: Dictionary = s.get("weigh_next", {})
	var id := str(s.get("id", ""))
	var friend := str(next.get("friend", ""))
	var heart := str(next.get("heart", "")) if bool(s.get("romance", false)) else ""
	var tags := PackedStringArray()
	if not friend.is_empty(): tags.append("[friend: %s, why]" % friend.replace("_", " "))
	if not heart.is_empty(): tags.append("[heart: %s, why]" % heart.replace("_", " "))
	var text := _say("WEIGH", {"events": "; ".join(events), "friend_rule": _swap_for(_step_text("friend", friend, id), s),
		"heart_rule": _swap_for(_step_text("heart", heart, id), s), "tags": " or ".join(tags) if not tags.is_empty() else WEIGH_NO_TAG}, s)
	while "  " in text: text = text.replace("  ", " ")
	return text

## Line 13: one repair line, only after a miss.
static func _repair(s: Dictionary) -> String:
	var kind := str(s.get("repair_kind", ""))
	match str(s.get("repair", "")):
		"felt": return _say("REPAIR_NO_FELT", {}, s)
		"why": return _say("REPAIR_NO_WHY", {}, s)
		"us_answer": return _say("REPAIR_NO_ANSWER", {"kind": kind}, s)
		"us_cold": return _say("REPAIR_YES_UPSET", {"step": _phrase(str(STEP_PHRASES.get(kind, kind.replace("_", " "))), {}, s)}, s)
	return ""

# --- Contact turns, intents, step sentences, events ---

## The sentences of the design's section 8 for a contact turn, from standing.last_touch (his touch
## she turned away and has not answered). "" when there is none, or while the switch is off.
static func contact_note(standing: Dictionary, _counts: Dictionary) -> String:
	if not BOND.DYNAMIC or standing.is_empty(): return ""
	var touch: Dictionary = standing.get("last_touch", {}) if standing.get("last_touch") is Dictionary else {}
	if touch.is_empty(): return ""
	var why := str(touch.get("why", ""))
	match str(touch.get("kind", "")):
		"kiss":
			if not bool(standing.get("romance", false)): return ""
			if why in ["no", "space"]: return _say("CONTACT_KISS_CLOSED", {"age": str(touch.get("no_age", ""))}, standing)
			if why in ["cold", "turned", "sore"]: return _say("CONTACT_KISS_CROSS", {}, standing)
			return _say("CONTACT_KISS_SURPRISED", {}, standing)
		"hug": return _say("CONTACT_HUG_TURNED", {}, standing)
		"flank_touch": return _say("CONTACT_FLANK_TURNED", {}, standing)
	return ""

## The purpose line for a turn the game asks of her (design 5.3): {"kind": "bond_ask", "step":
## "couple" or "date" or "outing", "activity": String}. "" for any other intent.
static func intent_text(intent: Dictionary) -> String:
	if str(intent.get("kind", "")) != "bond_ask": return ""
	var s := _player_standing()
	var activity := str(intent.get("activity", ""))
	match str(intent.get("step", "")):
		"couple": return _say("BOND_ASK_COUPLE", {"partner": str((s.words as Dictionary).get("partner", "coltfriend"))}, s)
		"date": return _say("BOND_ASK_DATE", {"plan": _plan_phrase("date", activity, s)}, s)
		"outing": return _say("BOND_ASK_OUTING", {"plan": _plan_phrase("outing", activity, s)}, s)
	return ""

static func _plan_phrase(kind: String, activity: String, s: Dictionary) -> String:
	var table: Dictionary = PLAN_DATE if kind == "date" else PLAN_OUTING
	if not table.has(activity): return _phrase("whatever you would enjoy", {}, s)
	return _phrase("for " + _article(str(table[activity])), {}, s)

## The sentence of the design's 3.3 for one step (the step above her, in the weighing line and on the
## page), a pony's own version when one was set. "" for a step that has none.
static func step_sentence(ladder: String, step: String, pony_id := "") -> String:
	return _swap_for(_step_text(ladder, step, pony_id), _player_standing())

static func _step_text(ladder: String, step: String, pony_id: String) -> String:
	if step.is_empty(): return ""
	if ladder == "friend" and BOND.closeness_rank(step) < BOND.closeness_rank("friend"): return ""
	if ladder == "heart" and BOND.heart_rank(step) < BOND.heart_rank("noticing"): return ""
	if ladder not in ["friend", "heart"]: return ""
	return _t("STEP_" + step.to_upper(), pony_id)

## The short phrase for one thing that happened (contract 3.4): second person, lower-case start, no
## full stop. `detail` may carry activity, place, item, kind, who, date, plan. Made when it happens
## and stored, so it is swapped for the player as he or she is now.
static func event_text(kind: String, detail := {}) -> String:
	if not EVENT_TEXTS.has(kind): return ""
	var s := _player_standing()
	var item := str(detail.get("item", "")).strip_edges()
	if not item.is_empty() and not (item.begins_with("a ") or item.begins_with("an ") or item.begins_with("the ") or item.begins_with("some ")):
		item = _article(item)
	var plan_kind := str(detail.get("kind", ""))
	var plan := {"activity": str(detail.get("activity", "")), "place": str(detail.get("place", "")),
		"date": kind == "date_kept" or plan_kind == "date" or bool(detail.get("date", false)), "kind": plan_kind if plan_kind in PLAN_PLAIN else "outing"}
	var place := str(detail.get("place", "")).replace("_", " ").strip_edges()
	var values := {"place": place if not place.is_empty() else EVENT_SOMEWHERE, "item": item if not item.is_empty() else EVENT_GIFT,
		"plan": _plan_words(plan, kind == "outing_kept"),
		"sore": sore_sentence(plan_kind, detail, s.words) if kind == "sore_opened" else "",
		"question": _question(QUESTION_HER, plan_kind, str((s.words as Dictionary).get("partner", "coltfriend")), s)}
	return _swap_for(str(EVENT_TEXTS[kind]), s).format(values)

## A mod's or a pony's own version of one sentence. `key` is a constant name in lower case
## ("close_good_friend", also written "close.good_friend"), or "show.STEP" with a pony id for that
## pony's own heart note. An empty text takes the version back.
static func set_line(key: String, text: String, pony_id := "") -> void:
	var name := key.strip_edges().to_upper().replace(".", "_")
	if name.is_empty(): return
	if not _lines.has(pony_id): _lines[pony_id] = {}
	if text.is_empty(): (_lines[pony_id] as Dictionary).erase(name)
	else: _lines[pony_id][name] = text

# --- The second look's request (design section 9) ---

## {"system": instruction, "user": grounding and the exchange}, at most BOND.READER.max_chars in all.
static func second_look(standing: Dictionary, his_line: String, her_line: String) -> Dictionary:
	var system := _t("SECOND_LOOK")
	var lines := PackedStringArray()
	if not standing.is_empty():
		lines.append(_t("SECOND_LOOK_STAND").format({"closeness": str(STAND_WORDS.get(str(standing.get("closeness", "stranger")), "strangers")),
			"heart": str(HEART_WORDS.get(str(standing.get("heart", "none")), HEART_WORDS["none"])) if bool(standing.get("romance", false)) else str(HEART_WORDS["none"]),
			"status": str(STATUS_WORDS.get(str(standing.get("status", "none")), STATUS_WORDS["none"]))}))
	var exchange := _t("SECOND_LOOK_EXCHANGE").format({"his": his_line.strip_edges().left(SECOND_LOOK_LINE), "name": str(standing.get("name", "Pony")),
		"hers": her_line.strip_edges().left(SECOND_LOOK_LINE)})
	if not standing.is_empty():
		# What she was told, as far as it fits: the sore points first, then the weighing line, then So far.
		var room := int(BOND.READER.max_chars) - system.length() - "\n".join(lines).length() - exchange.length() - _t("SECOND_LOOK_TOLD").length() - 8
		var parts := {"so_far": "" if bool(standing.get("first_meeting", false)) else _so_far(standing), "sore": _sore(standing), "weigh": _weigh(standing)}
		var kept := {}
		for key: String in ["sore", "weigh", "so_far"]:
			var part := str(parts[key])
			if not part.is_empty() and part.length() + 1 <= room:
				kept[key] = part
				room -= part.length() + 1
		var told := PackedStringArray()
		for key: String in ["so_far", "sore", "weigh"]:
			if kept.has(key): told.append(str(kept[key]))
		if not told.is_empty(): lines.append(_t("SECOND_LOOK_TOLD") + " " + " ".join(told))
	lines.append(exchange)
	return {"system": system, "user": "\n".join(lines)}

# --- Helpers ---

## One sentence: a pony's own version, the player's edit, a mod's version, or the constant.
static func _t(name: String, pony_id := "") -> String:
	if not pony_id.is_empty() and _lines.has(pony_id) and (_lines[pony_id] as Dictionary).has(name): return str(_lines[pony_id][name])
	var edited := PROMPT_OVERRIDES.overrides()
	var ident := CATALOG_PREFIX + name.to_lower()
	if edited.has(ident): return str(edited[ident])
	if _lines.has("") and (_lines[""] as Dictionary).has(name): return str(_lines[""][name])
	if _constants.is_empty(): _constants = (load(SELF_PATH) as GDScript).get_script_constant_map()
	return str(_constants.get(name, ""))

## A sentence for this standing: chosen, swapped for the player, then its slots filled.
static func _say(name: String, values: Dictionary, s: Dictionary) -> String:
	var text := _swap_for(_t(name, str(s.get("id", ""))), s)
	return text.format(values) if not values.is_empty() else text

## A game phrase for a slot: swapped for the player, then filled.
static func _phrase(text: String, values: Dictionary, s: Dictionary) -> String:
	var swapped := _swap_for(text, s)
	return swapped.format(values) if not values.is_empty() else swapped

static func _and(items: PackedStringArray) -> String:
	if items.size() <= 1: return "".join(items)
	return ", ".join(items.slice(0, items.size() - 1)) + " and " + items[items.size() - 1]

static func _swap_for(text: String, s: Dictionary) -> String:
	var words: Variant = s.get("words")
	if words is Dictionary and str((words as Dictionary).get("subject", "he")) == "she": return swap_words(text)
	return text

## The game's own text for a mare AnonPony, word for word: he to she, him and his to her, husband to
## wife, coltfriend to marefriend. Never used on anything she or the player wrote.
static func swap_words(text: String) -> String:
	var out := ""
	var word := ""
	for i in text.length() + 1:
		var c := text[i] if i < text.length() else ""
		if not c.is_empty() and c.to_lower() != c.to_upper():
			word += c
			continue
		if not word.is_empty():
			var lower := word.to_lower()
			if SWAP.has(lower):
				var swapped := str(SWAP[lower])
				out += swapped.capitalize() if word.left(1) != word.left(1).to_lower() else swapped
			else:
				out += word
			word = ""
		out += c
	return out

## {"words": the player's words} for calls that have no standing (events, intents, the page).
static func _player_standing() -> Dictionary:
	var loop := Engine.get_main_loop()
	var form: Dictionary = PLAYER_FORM.active(loop as SceneTree) if loop is SceneTree else PLAYER_FORM.human()
	return {"words": PLAYER_FORM.pronouns(form)}

## heart_notes.json, read once.
static func _heart_notes() -> Dictionary:
	if _notes.is_empty():
		_notes = {"own": {}, "one": {}}
		if FileAccess.file_exists(BOND.HEART_NOTES):
			var doc: Variant = JSON.parse_string(FileAccess.get_file_as_string(BOND.HEART_NOTES))
			if doc is Dictionary:
				if (doc as Dictionary).get("own") is Dictionary: _notes.own = doc.own
				if (doc as Dictionary).get("one") is Dictionary: _notes.one = doc.one
	return _notes
