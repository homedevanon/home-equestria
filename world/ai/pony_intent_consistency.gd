extends RefCounted
## Ask the model to repair an accepted request; never invent or execute an action here.
static func missing(request: String, speech: String, actions: Array) -> String:
	var input := request.to_lower().replace("’", "'")
	var answer := speech.to_lower().replace("’", "'")
	var invitation := RegEx.new()
	invitation.compile("(go (on|for) (a )?walk|walk (with|beside|behind) me|follow me|let's (go|walk)|come (with|along with) me)")
	if invitation.search(input) == null: return ""
	var refusal := RegEx.new()
	refusal.compile("\\b(no|not|can't|cannot|don't|won't|later|maybe|rather|busy)\\b|why |where |what ")
	if refusal.search(answer) != null: return ""
	var accepted := RegEx.new()
	accepted.compile("\\b(ok|okay|sure|yes|yeah|yep|alright|absolutely|let's|lead|coming|follow|with you)\\b")
	if accepted.search(answer) == null: return ""
	for action: Dictionary in actions:
		if action.get("type") in ["go_to", "lead"] and not str(action.get("location_id", "")).is_empty(): return ""
		if action.get("type") == "follow" and action.get("target_id") == "player": return ""
	return "You agreed to go along without a travel action. Use [go_to: LOCATION] for a named destination, or [follow: player] for an open-ended walk. Otherwise, clarify or decline. Travel makes you stand up, so skip [stand]."
