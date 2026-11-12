extends RefCounted
## Sentence boundaries are soft display limits: never discard a suffix or split a word.
const DISPLAY_LIMIT := 168 # Former 140-character HUD limit +20%.
const ABBREVIATIONS := ["mr", "mrs", "ms", "dr", "st", "prof", "jr", "sr", "e.g", "i.e"]
static func split(text:String) -> Array[String]:
	var result:Array[String]=[]
	var start:=0
	var i:=0
	while i<text.length():
		if text[i] not in [".","!","?","…"]:i+=1;continue
		if text[i]==".":
			if i>0 and i+1<text.length() and text[i-1].is_valid_int() and text[i+1].is_valid_int():i+=1;continue
			var word:=text.substr(start,i-start).strip_edges().get_slice(" ",text.substr(start,i-start).strip_edges().get_slice_count(" ")-1).to_lower()
			if word in ABBREVIATIONS or (word.length()==1 and word.to_upper()==text[i-1]):i+=1;continue
		var end:=i+1
		while end<text.length() and text[end] in [".","!","?","…","\"","”","'","’"]:end+=1
		if end==text.length() or text[end] in [" ","\n","\t"]:
			result.append(text.substr(start,end-start).strip_edges())
			start=end
		i=end
	var tail:=text.substr(start).strip_edges()
	if not tail.is_empty():result.append(tail)
	return result

## The complete part of a solo reply the output limit cut off (dev 2026-10-22: 18 of 47 lines in a
## tester capture were cut, and each cut line cost a second full-price request). A dangling tag and the
## unfinished last sentence go; complete tags after the last full sentence stay. "" when nothing
## complete remains or the cut took more than half of the spoken words: the caller then asks again.
static func complete_part(text:String) -> String:
	var cut:=text.strip_edges()
	# Notes blocks (<brain>...</brain>) stay whole in front; only the speech after the last one is
	# trimmed, and speech with no complete sentence is asked again (never a notes-only silence).
	var head:=""
	var closes:=RegEx.create_from_string("</(?:story|brain)>").search_all(cut)
	if not closes.is_empty():
		head=cut.left(closes[-1].get_end());cut=cut.substr(head.length()).strip_edges()
	if cut.contains("<brain>") or cut.contains("<story>"):return ""
	var open:=cut.rfind("[")
	if open>=0 and cut.find("]",open)<0:cut=cut.left(open).strip_edges()
	# Complete tags become placeholders, so a sentence inside [thought: ...] never splits the line.
	var found:=RegEx.create_from_string("\\[[^\\]]*\\]").search_all(cut)
	var masked:=cut
	for i in range(found.size()-1,-1,-1):
		masked=masked.left(found[i].get_start())+"\uE000%d\uE001"%i+masked.substr(found[i].get_end())
	var marks:=RegEx.create_from_string("\uE000\\d+\uE001")
	var whole:=marks.sub(masked,"",true).strip_edges()
	if whole.is_empty():return ""
	if whole.rstrip("\"”'’)*").right(1) in [".","!","?","…"]:return (head+"\n"+cut).strip_edges()
	var sentences:=split(masked)
	if sentences.size()<2:return ""
	var kept:=" ".join(sentences.slice(0,sentences.size()-1))
	if marks.sub(kept,"",true).strip_edges().length()*2<whole.length():return ""
	for mark in marks.search_all(sentences[-1]):kept+=" "+mark.get_string()
	for i in found.size():kept=kept.replace("\uE000%d\uE001"%i,found[i].get_string())
	return (head+"\n"+kept.strip_edges()).strip_edges()

static func expand(beats:Array) -> Array:
	var result:Array=[]
	for beat:Dictionary in beats:
		if bool(beat.get("silent_travel", false)):
			result.append(beat.duplicate(true)); continue
		var first:=true
		var emotion:=""
		var tag:=RegEx.new();tag.compile("^\\s*(\\[[a-zA-Z_ -]+\\])\\s*")
		var found:=tag.search(beat.speech)
		if found:emotion=found.get_string(1)+" "
		var parts:=audio_parts(beat.speech)
		# Per-sentence faces from the raw tagged line (pony_dialogue_tags.gd sentence_faces).
		var faces:Array=beat.get("face_map",[])
		var cursor:=[0]
		var face:=str(beat.get("face",""))
		for sentence_index in parts.size():
			var sentence:String=parts[sentence_index]
			var next:=beat.duplicate(true);next.speech=sentence;next.erase("face_map")
			if not faces.is_empty():
				face=preload("res://world/ai/pony_dialogue_tags.gd").face_for(faces,sentence,cursor,face)
				next.face=face
			if not first:next.actions=[];next.speech=emotion+sentence
			if sentence_index<parts.size()-1:next.erase("impression")
			next["continuation"]=not first
			result.append(next);first=false
	return result

## Normally one full sentence per message. An unusually long single sentence
## continues on word boundaries; its spoken audio and every word remain intact.
static func display_page(text:String,revealed:int) -> String:
	var start:=0
	while text.length()-start>DISPLAY_LIMIT:
		var boundary:=text.rfind(" ",start+DISPLAY_LIMIT)
		if boundary<=start:
			boundary=text.find(" ",start+DISPLAY_LIMIT)
			if boundary<0:break
		if revealed<=boundary:break
		start=boundary+1
	return text.substr(start,maxi(0,revealed-start))

## When no provider word alignment exists, distribute words by spoken length.
## The audio clock drives this approximation; exact chatter word cues supersede it.
static func timed_words(text:String,duration:float) -> Array:
	var regex:=RegEx.new();regex.compile("\\S+")
	var tokens:=regex.search_all(text)
	var total:=0.0
	for token in tokens:total+=maxf(2.0,token.get_string().length())
	var result:Array=[];var cursor:=0.0
	for token in tokens:
		result.append({"start":cursor/maxf(total,1.0)*duration,"end_char":token.get_end()})
		cursor+=maxf(2.0,token.get_string().length())
	return result

## Voice clients that can play a line while the server still renders it (tts_client.gd). With
## one, the first sound no longer waits for the end of the clip, so short sentences travel
## together: fewer requests, no gap between them (breeze-tts-pny mod by nak, MIT, 2026-11-10).
const AUDIO_TARGET := 160
const AUDIO_MAX := 400
const TINY_AUDIO := 48
static var _stream_clients := {}

static func note_stream_client(id:int, streaming:bool) -> void:
	if streaming:_stream_clients[id]=true
	else:_stream_clients.erase(id)

static func grouping() -> bool:
	return not _stream_clients.is_empty()

## One speaker's sentences gathered toward AUDIO_TARGET characters. An opening shorter than
## TINY_AUDIO stays with the sentence after it; a long piece splits at a space near AUDIO_MAX.
static func grouped_parts(text:String) -> Array[String]:
	var result:Array[String]=[]
	var pending:=""
	for sentence:String in split(text):
		if not pending.is_empty() and pending.length()+sentence.length()+1>AUDIO_TARGET and pending.length()>=TINY_AUDIO:
			result.append(pending);pending=""
		pending+=(" " if not pending.is_empty() else "")+sentence
		while pending.length()>AUDIO_MAX:
			var end:=pending.rfind(" ",AUDIO_MAX)
			if end<=0:break # An unusually long word stays whole.
			result.append(pending.left(end));pending=pending.substr(end+1)
	if not pending.is_empty():result.append(pending)
	return result

static func audio_parts(text:String) -> Array[String]:
	if grouping():return grouped_parts(text)
	var result:Array[String]=[]
	for sentence in split(text):
		while sentence.length()>400:
			var end:=sentence.rfind(" ",400)
			if end<=0:break
			result.append(sentence.left(end));sentence=sentence.substr(end+1)
		result.append(sentence)
	return result
