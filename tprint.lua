-- tprint.lua — full, fixed.
--
-- USAGE
--   tprint(tbl)                      -- console
--   tprint(tbl, [[C:\dump.txt]])     -- file, then a completion line on the console
--   tprint(userdata)                 -- expanded via full_internal, one line per row
--   printDump(false, 'text')         -- always console
--   printDump(true,  'text')         -- file if one is open, else console
--
-- WHAT WAS WRONG, AND WHAT CHANGED
--   The old file crashed with an access violation because it invoked CE
--   metamethods while walking: tbl[0] -> __index, pairs(tbl) -> __pairs,
--   #tbl -> __len, tostring(v) -> __tostring on userdata. A native AV is not
--   reliably catchable by pcall, so the fix is to AVOID those calls:
--     * keys via next(), values via rawget(), no # on foreign tables
--     * userdata / functions / threads are printed as type markers, never
--       passed to tostring()
--
--   Other defects fixed:
--     * no cycle guard                  -> identity-keyed `seen`, cleared on exit
--     * bubbleSort, string keys unsorted-> table.sort on both, pcall-guarded
--     * non-string/number key concat    -> keyLabel()
--     * '"'..v..'"' broke on quotes     -> full escaping
--     * '[['..v..']]' broke on payload]]-> collision-free long bracket
--     * fOnce shared across keys        -> removed
--     * stale mtvr reused per iteration -> removed
--     * getmetatable_formatted: pcall(mtv) instead of pcall(gcnt), undefined
--       `tycn`, globals fp/fpb/fpr, pltFinal[i] overwriting structured keys
--       -> that whole helper is gone; nothing here calls CE object methods
--
--   File output:
--     * write / flush / close return values are all CHECKED, so a silent
--       truncation becomes a reported INCOMPLETE
--     * trailing spaces and blank lines are trimmed by holding back the
--       whitespace run and discarding it at close (Lua io has no truncate)
--     * the completion line goes to the CONSOLE, never into the file
--
--   NEW: a userdata first argument is expanded by full_internal and printed
--   as one line per pth row. Table arguments are unaffected.
--
--   NO depth limit on the table walker. A genuinely enormous structure raises
--   a Lua stack overflow, which is reported rather than hidden.

local realprint = print          -- captured once: a reassigned global print cannot recurse

-- Dump state. File-level so printDump also works outside tprint; with no file
-- open it simply falls back to the console.
local dumpFile   = nil
local dumpLines  = 0
local dumpBytes  = 0
local dumpFailed = nil
local wsTail     = ''            -- held-back trailing whitespace, never written

---------------------------------------------------------------- strings

local function s_pluralise(c,t)
	local d=tostring(c)..' '
	if c~=1 then
		return d..t..'s'
	else
		return d..t
	end
end

local function escString(s)
    local out = {'"'}
    for i = 1, #s do
        local c = s:byte(i)
        if     c == 34 then out[#out+1] = '\\"'
        elseif c == 92 then out[#out+1] = '\\\\'
        elseif c == 10 then out[#out+1] = '\\n'
        elseif c == 13 then out[#out+1] = '\\r'
        elseif c == 9  then out[#out+1] = '\\t'
        elseif c < 32 or c == 127 then out[#out+1] = string.format('\\%03d', c)
        else out[#out+1] = string.char(c) end
    end
    out[#out+1] = '"'
    return table.concat(out)
end

-- Enough '=' that the payload cannot close the bracket early.
local function longBracket(s)
    local eq = ''
    while string.find(s, ']' .. eq .. ']', 1, true) do eq = eq .. '=' end
    return '[' .. eq .. '[' .. s .. ']' .. eq .. ']'
end

local function renderString(s)
    if string.find(s, '\n', 1, true) then
        -- Long brackets read far better for multiline text, but only when the
        -- payload has no other control bytes. CR is excluded because Lua
        -- normalises line endings inside long strings.
        local clean = true
        for i = 1, #s do
            local c = s:byte(i)
            if (c < 32 or c == 127) and c ~= 10 and c ~= 9 then
                clean = false break
            end
        end
        if clean then return longBracket(s) end
    end
    return escString(s)
end

-- NEVER tostring() userdata: __tostring on a CE object can fault.
local function scalar(v)
    local tv = type(v)
    if tv == 'string' then return renderString(v) end
    if tv == 'number' or tv == 'boolean' or tv == 'nil' then return tostring(v) end
    if tv == 'function' then return 'function (…) … end' end
    if tv == 'userdata' then return 'userdata' end
    if tv == 'thread'   then return 'thread' end
    return '<' .. tv .. '>'
end

---------------------------------------------------------------- file output

local function isWS(c)
    return c == 32 or c == 9 or c == 10 or c == 13   -- space, tab, LF, CR
end

local function rawWrite(s)
    if s == '' then return true end
    if dumpFile == nil then return false end
    local pok, res, werr = pcall(dumpFile.write, dumpFile, s)
    if not pok or res == nil then
        dumpFailed = dumpFailed or ('write failed: ' .. tostring(pok and werr or res))
        realprint('tprint: ' .. dumpFailed)
        realprint(s)                                  -- echo, so the data is not lost
        return false
    end
    dumpBytes = dumpBytes + #s
    local _, nl = s:gsub('\n', '')                    -- C-speed newline count
    dumpLines = dumpLines + nl
    if dumpLines > 0 and dumpLines % 1000 == 0 then
        local fok, fres, ferr = pcall(dumpFile.flush, dumpFile)
        if not fok or fres == nil then
            dumpFailed = dumpFailed or ('flush failed: ' .. tostring(fok and ferr or fres))
        end
    end
    return true
end

-- Hold back every whitespace byte seen since the last non-whitespace byte.
-- Whatever is still held at close is discarded: that is the trailing trim.
-- Interior blank lines survive, because they get flushed as soon as any later
-- non-whitespace byte arrives.
local function fileWriteTrim(s)
    local last = #s
    while last > 0 and isWS(s:byte(last)) do last = last - 1 end
    if last == 0 then
        wsTail = wsTail .. s
        return true
    end
    local ok = rawWrite(wsTail .. s:sub(1, last))
    wsTail = s:sub(last + 1)
    return ok
end

-- f == true  -> file if one is open, else console
-- f ~= true  -> console
-- Mimics print(): arguments tab-separated, no arguments = blank line.
function printDump(f, ...)
    local n = select('#', ...)
    local parts = {}
    for i = 1, n do
        local a = (select(i, ...))
        parts[i] = (type(a) == 'string') and a or scalar(a)
    end
    local line = table.concat(parts, '\t')

    if f == true and dumpFile ~= nil then
        fileWriteTrim(line .. '\n')
    else
        realprint(line)
    end
end

local function closeDump()
    if dumpFile == nil then return 0 end
    local f = dumpFile
    dumpFile = nil                 -- stop routing BEFORE closing
    --local dropped = #wsTail
    wsTail = ''                    -- THE TRIM: held whitespace is never written
    local pok, res, err = pcall(f.flush, f)
    if not pok or res == nil then
        dumpFailed = dumpFailed or ('flush failed: ' .. tostring(pok and err or res))
    end
    pok, res, err = pcall(f.close, f)
    if not pok or res == nil then
        dumpFailed = dumpFailed or ('close failed: ' .. tostring(pok and err or res))
    end
    --return dropped
end

---------------------------------------------------------------- keys

local function keyLabel(k)
    local tk = type(k)
    if tk == 'string' then
        if string.find(k, '%c') then return escString(k) end
        return k
    end
    if tk == 'number' or tk == 'boolean' then return tostring(k) end
    return '<' .. tk .. ' key>'
end

-- next() is raw: __pairs is never consulted.
local function orderedKeys(t)
    local nums, strs, others = {}, {}, {}
    for k in next, t do
        local tk = type(k)
        if     tk == 'number' then nums[#nums+1]     = k
        elseif tk == 'string' then strs[#strs+1]     = k
        else                       others[#others+1] = k end
    end
    pcall(table.sort, nums)        -- a NaN key would otherwise raise
    pcall(table.sort, strs)
    local out = {}
    for i = 1, #nums   do out[#out+1] = nums[i]   end
    for i = 1, #strs   do out[#out+1] = strs[i]   end
    for i = 1, #others do out[#out+1] = others[i] end
    return out
end

---------------------------------------------------------------- printer

function tprint(tbl, pth)
    if dumpFile ~= nil then
        realprint('tprint: a dump is already open; ignoring the new path')
        pth = nil
    end

    dumpLines, dumpBytes, dumpFailed, wsTail = 0, 0, nil, ''

    if pth ~= nil and pth ~= '' then
        local fh, err = io.open(pth, 'w')
        if fh == nil then
            realprint('tprint: cannot open ' .. tostring(pth)
                      .. ' (' .. tostring(err) .. ')')
            realprint('tprint: falling back to console')
        else
            dumpFile = fh
        end
    end
    local toFile = (dumpFile ~= nil)

    local seen = {}

    -- No depth parameter and no depth test. `seen` only stops a table being
    -- descended into while it is already an ancestor of itself; it is cleared
    -- on the way out, so a table reached by two pths is shown in both places.
    local function dump(v, indent, label)
        local pad    = string.rep('\t', indent)
        local prefix = label and (pad .. label .. ': ') or pad

        if type(v) ~= 'table' then
            printDump(toFile, prefix .. scalar(v))
            return
        end

        if seen[v] then
            printDump(toFile, prefix .. '<cycle>')
            return
        end
        seen[v] = true

        local keys = orderedKeys(v)
        if #keys == 0 then
            printDump(toFile, prefix .. '{}')
            seen[v] = nil
            return
        end

        if label then printDump(toFile, prefix) end

        for i = 1, #keys do
            local k = keys[i]
            local okv, val = pcall(rawget, v, k)   -- raw: __index never invoked
            if not okv then
                printDump(toFile, string.rep('\t', indent + 1)
                                  .. keyLabel(k) .. ': <unreadable>')
            else
                dump(val, indent + 1, keyLabel(k))
            end
        end

        seen[v] = nil
    end

    -- A userdata FIRST ARGUMENT is expanded by full_internal, then rendered
    -- one line per pth row. Only the first argument: expanding every nested
    -- userdata would re-run full_internal's whole graph walk at each node.
    --
    -- full_internal already stringifies object values, so nothing here needs
    -- to call tostring on a CE object. Its own tostring(val) is inherited
    -- behaviour, not something tprint can guard.
    local function dumpUserdata(obj)
        if type(full_internal) ~= 'function' then
            printDump(toFile, 'tprint: full_internal is not loaded; cannot expand userdata')
            printDump(toFile, scalar(obj))
            return
        end

        local rows = full_internal(obj)
        if type(rows) ~= 'table' then
            printDump(toFile, 'tprint: full_internal returned no rows')
            printDump(toFile, scalar(obj))
            return
        end

        local n = 0
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == 'table' then
                n = n + 1
                local line = string.format('%-9s %s',
                    tostring(r.type or '?'), tostring(r.path or '?'))
                -- scalar() renders a raw metatable table as <table> rather
                -- than walking it, so a live CE proxy cannot be descended.
                if r.value ~= nil then
                    line = line .. ' = ' .. scalar(r.value)
                end
                printDump(toFile, line)
            end
        end
        printDump(toFile, string.format('(%s)', s_pluralise(n,'row')))
    end

    local ok, err = pcall(function()
        if type(tbl) == 'userdata' then
            dumpUserdata(tbl)
        else
            dump(tbl, 0, nil)
        end
        printDump(toFile, '')
    end)
    if not ok then
        dumpFailed = dumpFailed or ('walk failed: ' .. tostring(err))
    end

	closeDump()

    if not toFile then realprint('') end

    if dumpFailed then
        realprint('tprint: INCOMPLETE — ' .. dumpFailed
                  .. ' (' .. s_pluralise(dumpLines,'line')..' written to ' .. tostring(pth)..')')
    elseif toFile then
        local lns = dumpLines + (dumpBytes > 0 and 1 or 0)
        realprint(string.format(
            'tprint: finished — %s, %s → %s',
            s_pluralise(lns,'line'), s_pluralise(dumpBytes,'byte'), tostring(pth)))
    end
end