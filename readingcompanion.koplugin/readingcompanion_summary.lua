local P = require("readingcompanion_policy")
local M = {}

-- Serial bounded requests: never send unread text and never run requests in
-- parallel on the Kindle. Final synthesis only sees source-grounded chunk notes.
function M.run(source, ask, decode, alive, done)
    local chunks = P.chunks(source)
    if not chunks then done(false, nil, "Cannot safely split source text"); return end
    local notes, index, final_evidence, evidence_count = {}, 1, {}, 0
    local function parse(response, scope, evidence_map)
        response = response:gsub("^```json%s*", ""):gsub("^```%s*", ""):gsub("%s*```%s*$", "")
        local ok, result = pcall(decode, response)
        if ok then return P.verify(result, scope, evidence_map) end
        return nil,nil,"invalid JSON"
    end
    local function request(prompt, input, scope, callback, evidence_map)
        if not alive() then done(false, nil, "Reading position changed"); return end
        if not evidence_map then
            local numbered
            numbered, evidence_map = P.numbered(scope)
            if not numbered then done(false,nil,"Cannot safely label source"); return end
            input = input .. "\n" .. numbered
        end
        local corrected = false
        local receive
        receive = function(ok, response, err)
            if not alive() then done(false, nil, "Reading position changed"); return end
            if not ok or type(response) ~= "string" then done(false,nil,err or "Request failed"); return end
            local text, paragraphs, reason = parse(response,scope,evidence_map)
            if not text then
                if not corrected then
                    corrected = true
                    ask(prompt .. "\nCORRECTION: A prior attempt failed validation (" .. (reason or "invalid response") .. "). Write a paraphrased recap, and cite ONLY source IDs explicitly present in the input. Do not put quotations into the evidence array. If a detail cannot be supported, omit it. Return the exact JSON schema requested.", input, receive)
                    return
                end
                done(false,nil,"Recap rejected: " .. (reason or "invalid response")); return
            end
            callback(text,paragraphs)
        end
        ask(prompt, input, receive)
    end
    if #chunks == 1 then
        request(P.prompt, "READ TEXT (exclusive position cutoff):", source, function(text) done(true,text) end)
        return
    end
    local nextChunk
    nextChunk = function()
        if index <= #chunks then
            local scope = chunks[index]
            request(P.prompt .. "\nThis is one chronological segment. Create concise factual working notes in the same JSON format; preserve important names and events without guessing missing context.",
                "READ SEGMENT " .. index .. " OF " .. #chunks .. ":", scope, function(_, paragraphs)
                    notes[#notes+1] = "SEGMENT " .. index
                    for _, p in ipairs(paragraphs) do
                        notes[#notes+1] = "Supported note: " .. p.text
                        for _, quote in ipairs(p.evidence) do
                            evidence_count = evidence_count+1
                            local id = string.format("F%04d",evidence_count)
                            final_evidence[id] = quote
                            notes[#notes+1] = "["..id.."] Original source: " .. quote
                        end
                    end
                    index = index+1
                    nextChunk()
                end)
        else
            request(P.prompt .. "\nSynthesize the chronological working notes into ONE coherent recap of everything read so far. Cite the F-prefixed original source IDs below. Do not mention the chunking process.",
                table.concat(notes,"\n"), source, function(text) done(true,text) end, final_evidence)
        end
    end
    nextChunk()
end
return M
