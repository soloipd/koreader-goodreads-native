package.path = "readingcompanion.koplugin/?.lua;" .. package.path
local scheduled, shown = {}, 0
package.loaded.logger={info=function() end,warn=function() end}
local U = {scheduleIn=function(_,_,f) scheduled[f]=true end,unschedule=function(_,f) scheduled[f]=nil end,
 nextTick=function(_,f) scheduled[f]=true end,show=function() shown=shown+1 end,close=function() end}
package.loaded["ui/uimanager"]=U
package.loaded["ui/widget/container/widgetcontainer"]={extend=function(_,t) return t end}
for _,name in ipairs({"device","ui/event","ui/widget/textwidget","ui/font","ffi/blitbuffer","ui/widget/textviewer"}) do package.loaded[name]={} end
package.loaded["ui/widget/infomessage"]={new=function(_,t) return t end}
package.loaded["luasettings"]={open=function() return {readSetting=function(_,k) if k=="features" then return {provider="test",model="test-model"} end end} end}
package.loaded["datastorage"]={getSettingsDir=function() return "/test" end}
local connected=true
package.loaded["ui/network/manager"]={isConnected=function() return connected end}
package.loaded["koassistant.request.message_history"]={new=function(_,s)
 return {messages={{role="system",content=s}},addUserMessage=function(self,t) self.messages[2]={role="user",content=t} end,getMessages=function(self) return self.messages end}
end}
local callback, config, messages
package.loaded["koassistant.request.gpt_query"]={query=function(m,c,cb) messages=m;config=c;callback=cb end}
local past="Mara repaired the old clock in the workshop. The clock began keeping time after she replaced its spring."
package.loaded.json={decode=function() return {paragraphs={{text="Mara has restored the old clock to working order by replacing its spring.",evidence={"S0001"}}}} end}
local C=dofile("readingcompanion.koplugin/main.lua")
local n=0
local function check(v,name) assert(v,name);n=n+1;print("PASS "..name) end
local function instance()
 local xp="cutoff"
 local data={}
 local self=setmetatable({alive=true,ui={document={file="book.epub",info={has_pages=false},
  getXPointer=function() return xp end,getPageFromXPointer=function() return 10 end,
  getPageXPointer=function() return "start" end,getTextFromXPointers=function() return past end},
  koassistant={ensureInitialized=function() end},doc_settings={readSetting=function(_,k) return data[k] end,saveSetting=function(_,k,v) data[k]=v end}}},{__index=C})
 self.display=function(s,t) s.displayed=t end
 return self,data,function(v) xp=v end
end
local s,data,move=instance();s:showRecap(true)
check(messages[1].role=="system" and messages[2].role=="user","query receives array, not History wrapper")
check(config.system.text:find("ONLY",1,true),"system instructions survive provider filtering")
check(config.features.enable_web_search==false and config.features.enable_book_tools==false,"web and book tools disabled")
check(config.features.enable_streaming==false,"draft text and reasoning never streamed to screen")
check(not config.features.book_metadata,"no title or future metadata sent")
check(s.pending and not s.displayed,"asynchronous request does not display partial answer")
callback(true,"json")
check(s.last_status=="generated_grounded" and s.displayed,"AI summary displayed")
check(data.readingcompanion_recap.xp=="cutoff","cache tied to exact position")
s.displayed=nil;connected=false;s:showRecap(true)
check(s.last_status=="cache_verified" and s.displayed,"exact cache works offline")
s,data,move=instance();s:showRecap(true)
check(s.last_status=="offline" and not s.pending,"offline misses do not start request")
connected=true;s:showRecap(true);move("earlier");callback(true,"json")
check(s.last_status=="stale_response_discarded" and not data.readingcompanion_recap,"rewind during request drops response")
s,data=instance();s:showRecap(true);s:onCloseDocument();s.ui.document=nil;callback(true,"json")
check(not s.displayed and not data.readingcompanion_recap,"completion after close does not touch destroyed document")
s=instance();s:showRecap(true);callback(false,nil,"test error")
check(s.last_status=="request_failed" and not s.pending,"failure releases request state")
s:showRecap(true);s.watchdog();callback(true,"json")
check(s.last_status=="timed_out" and not s.displayed,"late result after watchdog is discarded")
s:showRecap(true);callback(true,"json")
check(s.last_status=="generated_grounded","retry after completed timeout succeeds")
s=instance();s:onReaderReady();check(s.ready_task and scheduled[s.ready_task],"header deferred until core restoration completes")
s:onCloseDocument();check(not scheduled[s.ready_task],"close cancels deferred header installation")
print(n.." tests passed")
