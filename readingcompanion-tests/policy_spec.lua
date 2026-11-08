package.path = "readingcompanion.koplugin/?.lua;" .. package.path
local P = require("readingcompanion_policy")
local n = 0
local function check(value, name) assert(value, name); n=n+1; print("PASS "..name) end
local past="Mara repaired the old clock in the workshop. The clock began keeping time after she replaced its spring."
local future="SECRET CANARY: the captain is a robot."
local doc={file="fixture.epub",info={has_pages=false},getXPointer=function() return "cutoff" end,
 getPageFromXPointer=function() return 12 end,getPageXPointer=function(_,p) assert(p==1);return "start" end,
 getTextFromXPointers=function(_,a,b) assert(a=="start" and b=="cutoff");return past end}
local ctx=P.capture(doc)
check(ctx and ctx.source==past,"all read text from page one to exclusive cutoff")
check(not ctx.source:find(future,1,true),"unread canary excluded")
local function answer(text,evidence) return {paragraphs={{text=text,evidence={evidence}}}} end
local prose="Mara has restored the workshop clock to working order by replacing a faulty spring."
check(P.normalize("The ﬁrm’s pro\194\173mise")=="The firm's promise","EPUB typography normalization without fuzzy matching")
check(P.verify(answer(prose,past),past)==prose,"AI paraphrase displayed, not evidence quotations")
local indexed, references=P.numbered(past)
check(indexed:find("[S0001]",1,true) and references.S0001==past,"source IDs resolve only to bounded text")
check(P.verify(answer(prose,"S0001"),past,references)==prose,"AI prose with valid source ID accepted")
check(not P.verify(answer(prose,"S9999"),past,references),"nonexistent or unread source ID rejected")
check(not P.verify(answer(prose,future),past),"unread supporting evidence rejected")
check(not P.verify(answer(prose,"An invented supporting quotation that does not occur."),past),"invented evidence rejected")
check(not P.verify({paragraphs={{text=prose,evidence={}}}},past),"unsupported paragraph rejected")
check(not P.verify({paragraphs={{text=prose,evidence={123}}}},past),"non-string evidence rejected")
check(not P.verify({excerpts={past}},past),"old excerpt-only response rejected")
check(not P.verify(answer("tiny",past),past),"empty or tiny summary rejected")
check(not P.verify(answer(prose,string.rep("a",901)),past),"oversized evidence rejected")
local cache={version=P.version,file=ctx.file,xp=ctx.xp,source=ctx.source,text=prose,options_key=ctx.options_key}
check(P.cacheMatches(cache,ctx),"exact cache accepted")
local function mismatch(k,v,label) local old=cache[k];cache[k]=v;check(not P.cacheMatches(cache,ctx),label);cache[k]=old end
mismatch("xp","later","rewind cache rejected")
mismatch("file","other.epub","wrong-book cache rejected")
mismatch("source","changed","changed-edition cache rejected")
mismatch("version",1,"old excerpt cache invalidated")
check(not P.cacheMatches(nil,ctx),"missing cache safe")
local many=string.rep(past.." ",2200)
local chunks=P.chunks(many)
check(#chunks>1 and table.concat(chunks)==many,"chunking preserves every source byte")
for _,chunk in ipairs(chunks) do check(#chunk<=P.chunk_size,"bounded chunk size") end
doc.getTextFromXPointers=function() return string.rep("a",P.max_source+1) end
check(not P.capture(doc),"oversized source fails closed instead of truncating earlier chapters")
doc.info.has_pages=true;check(not P.capture(doc),"PDF fails closed");doc.info.has_pages=false
doc.getXPointer=function() return nil end;check(not P.capture(doc),"missing position fails closed")
doc.getXPointer=function() return "cutoff" end;doc.getPageFromXPointer=function() return 1 end
check(not P.capture(doc),"book start skipped")
doc.getPageFromXPointer=function() return 12 end;doc.getTextFromXPointers=function() return "" end
check(not P.capture(doc),"empty source fails closed")
doc.getTextFromXPointers=function() doc.getXPointer=function() return "moved" end;return past end
check(not P.capture(doc),"moving position fails closed")
print(n.." tests passed")
