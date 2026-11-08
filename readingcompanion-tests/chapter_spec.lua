package.path="readingcompanion.koplugin/?.lua;"..package.path
local P=require("readingcompanion_policy")
local n=0
local function check(v,label) assert(v,label); n=n+1;print("PASS "..label) end
local current=2499
local toc={{xpointer=1,depth=1},{xpointer=2000,depth=1},{xpointer=4000,depth=1}}
local start_seen
local doc={file="fixture.epub",info={has_pages=false},getXPointer=function() return current end,
getPageFromXPointer=function() return 20 end,getPageXPointer=function() return 1 end,
getToc=function() return toc end,compareXPointers=function(_,a,b) return a==b and 0 or (a<b and 1 or -1) end,
getTextFromXPointers=function(_,a,b) assert(b==current);start_seen=a;return string.rep("word ",b-a) end}
local ctx=P.capture(doc)
check(start_seen==1 and ctx.mode=="chapter_transition","first 500 words connect previous chapter")
current=2000;ctx=P.capture(doc)
check(start_seen==1,"exact chapter start uses previous chapter only")
current=2500;ctx=P.capture(doc)
check(start_seen==2000 and ctx.mode=="chapter","500 word boundary excludes previous chapter")
current=3900;ctx=P.capture(doc)
check(start_seen==2000 and P.wordCount(ctx.source)==1900,"mid chapter excludes previous and future chapters")
ctx=P.capture(doc,{scope="all"});check(start_seen==1,"whole book scope remains available")
ctx=P.capture(doc,{scope="recent"});check(P.wordCount(ctx.source)==2500,"recent scope bounded to 2500 words")
toc={};ctx=P.capture(doc);check(ctx.mode=="recent" and P.wordCount(ctx.source)==2500,"missing TOC falls back to recent text")
toc={{xpointer=1,depth=1},{xpointer=1000,depth=2},{xpointer=2000,depth=1}}
ctx=P.capture(doc);check(start_seen==2000,"new parent does not inherit previous chapter subsection")
toc={{xpointer=1,depth=1},{xpointer=2000,depth=1}};current=600
ctx=P.capture(doc);check(start_seen==1,"first chapter has no previous chapter")
local cache={version=P.version,file=ctx.file,xp=ctx.xp,source=ctx.source,text="recap",options_key=ctx.options_key}
check(not P.cacheMatches(cache,P.capture(doc,{length="brief"})),"length change invalidates cache")
check(not P.cacheMatches(cache,P.capture(doc,{scope="all"})),"scope change invalidates cache")
local paragraphs={{text=string.rep("word ",50)},{text=string.rep("other ",50)}}
check(P.checkLength(paragraphs,{}),"two short paragraphs accepted")
check(not P.checkLength({paragraphs[1]},{}),"single paragraph rejected")
paragraphs[2].text=string.rep("word ",200)
check(not P.checkLength(paragraphs,{}),"oversized standard recap rejected")
check(P.checkLength(paragraphs,{length="detailed"}),"detailed length configurable")
check(P.options({scope="bad",length="bad"}).scope=="chapter","invalid settings default safely")
print(n.." tests passed")
