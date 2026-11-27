extends RefCounted
## Shared by ambient exchanges and player-chat lulls. Solicit from supplied
## observations/history, never inject a fictional event as a random topic.
const IDLE_GUIDANCE := """Ponies have lives beyond the weather. For idle chat, pick ONE topic that fits the speaker and company. Talk about your day so far, what is on your mind, your story, plans, wants, worries, opinions of ponies you know, a memory the moment brings up, or what is happening here. If you share something you heard, say who told you, since hearsay can be wrong or exaggerated. Only bring up weather or scenery when something is unusual. A brief exchange or silence are both fine. Never invent prices, quantities, statistics, or events outside your memory sections. If Anon looks busy, do not demand his attention. Ambient chatter between ponies is not addressed to him."""

static func seed_line() -> String:
	return IDLE_GUIDANCE
