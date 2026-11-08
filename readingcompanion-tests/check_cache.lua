-- Read-only on-device acceptance check. Pass the book path as argv[1].
require("setupkoenv")
G_reader_settings=require("luasettings"):open("/mnt/us/koreader/settings.reader.lua")
local ds=require("docsettings"):open(assert(arg[1],"book path required"))
local cache=assert(ds:readSetting("readingcompanion_recap"),"cache missing")
local words=0;for _ in cache.text:gmatch("%S+") do words=words+1 end
local paragraphs=1;for _ in cache.text:gmatch("\n\n") do paragraphs=paragraphs+1 end
print("cache_version="..cache.version)
print("source_bytes="..#cache.source)
print("summary_words="..words)
print("paragraphs="..paragraphs)
print("options="..tostring(cache.options_key))
print("saved_anchor_matches="..tostring(cache.xp==ds:readSetting("last_xpointer")))
assert(cache.version==3 and paragraphs==2,"wrong cache version or paragraph count")
assert(cache.options_key=="chapter:standard" and words>=80 and words<=160,"wrong default length or scope")
assert(cache.xp==ds:readSetting("last_xpointer"),"reading position changed")
