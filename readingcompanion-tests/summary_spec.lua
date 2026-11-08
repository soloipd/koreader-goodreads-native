package.path="readingcompanion.koplugin/?.lua;"..package.path
local P=require("readingcompanion_policy")
local M=require("readingcompanion_summary")
local original_size=P.chunk_size
P.chunk_size=240
local a="Mara repaired the old clock in her workshop. The clock was accurate after she replaced the spring. "
local source=string.rep(a,8)
local requests, result=0,nil
local evidence="S0001"
local function decode() return {paragraphs={{text="Mara fixed the clock by replacing a faulty spring, restoring accurate timekeeping.",evidence={evidence}}}} end
M.run(source,function(prompt,input,cb)
 requests=requests+1
 evidence=assert(input:match("%[([SF]%d+)%]"))
 assert(not input:find("UNREAD ROBOT",1,true))
 cb(true,"json")
end,decode,function() return true end,function(ok,text,err) assert(ok,err);result=text end)
assert(requests==#P.chunks(source)+1 and result)
print("PASS all chunks followed by one coherent synthesis")
local called=0
M.run(source,function(_,_,cb) called=called+1;cb(false,nil,"offline") end,decode,function() return true end,function(ok,text,err) assert(not ok and not text and err=="offline") end)
assert(called==1);print("PASS first failed chunk stops pipeline without partial summary")
local active=true
M.run(source,function(_,_,cb) active=false;cb(true,"json") end,decode,function() return active end,function(ok,text,err) assert(not ok and not text and err=="Reading position changed") end)
print("PASS navigation cancels remaining chunk requests")
P.chunk_size=original_size
local attempts=0
M.run(a,function(_,_,cb) attempts=attempts+1;cb(true,"bad") end,function() return {} end,function() return true end,function(ok,text) assert(not ok and not text) end)
assert(attempts==2);print("PASS malformed answer retries once then fails closed")
attempts=0;evidence="S0001"
M.run(a,function(_,_,cb) attempts=attempts+1;cb(true,"json") end,function()
 if attempts==1 then return {} end;return decode()
end,function() return true end,function(ok,text) assert(ok and text) end)
assert(attempts==2);print("PASS corrected answer returns prose after evidence validation")
attempts=0
M.run(a,function(_,_,cb) attempts=attempts+1;cb(true,"json") end,decode,function() return true end,
function(ok,text,err) assert(not ok and not text and err:find("two paragraphs",1,true)) end,{length="standard"})
assert(attempts==2);print("PASS wrong paragraph count retries once then fails closed")
