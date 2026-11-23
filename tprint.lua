-- tprint.lua — full, fixed.
--
-- USAGE
--   tprint(tbl)                      -- console
--   tprint(tbl, [[C:\dump.txt]])     -- file, then a completion line on the console
--   tprint(userdata)                 -- expanded via full_internal, one line per row
--   tprint(string)                   -- internals + string library via __index
--   tprint(number)                   -- internals + math library via __index
--   tprint(table)                    -- internals + table library via __index, then keys
--   printDump(false, 'text')         -- always console
--   printDump(true,  'text')         -- file if one is open, else console
--
-- LIBRARY LISTING (first argument only, for number / string / table)
--   Obtained ONLY through a metatable: a fresh proxy is built as
--       setmetatable({}, { __index = lib })
--   and the library is reached as getmetatable(probe).__index.
--   setmetatable() accepts tables only, so the value itself is never given a
--   metatable. debug.setmetatable() is deliberately NOT used: it would alter
--   the metatable of an entire type for the whole Lua state.
--   Every listed name is then re-read THROUGH the proxy and compared, so the
--   report states how many actually resolve rather than assuming they do.
--   Non-function entries (math.pi, math.huge, …) are reported as constants.
--   Extend the mapping with:
--       tprintConfig.libraries.number = { 'math', 'bit' }
--
-- SAFETY
--   The old file crashed because it invoked CE metamethods while walking:
--   tbl[0] -> __index, pairs(tbl) -> __pairs, #tbl -> __len,
--   tostring(v) -> __tostring on userdata. A native AV is not reliably
--   catchable by pcall, so those calls are avoided entirely:
--     * keys via next(), values via rawget(), no # on foreign tables
--     * userdata / functions / threads print as type markers, never tostring()
--
--   Other defects fixed: cycle guard; table.sort instead of bubbleSort;
--   safe key labels; full string escaping; collision-free long brackets;
--   per-key meta flag; no stale mtvr; getmetatable_formatted removed.
--
-- FILE OUTPUT
--   write / flush / close return values are all CHECKED, so a silent
--   truncation becomes a reported INCOMPLETE. Trailing whitespace is trimmed
--   by holding back the whitespace run and discarding it at close (Lua io has
--   no truncate). The completion line goes to the CONSOLE, never into the file.
--
-- NO depth limit. A genuinely enormous structure raises a Lua stack overflow,
-- which is reported rather than hidden. The only cap is a BREADTH cap on the
-- per-byte string listing, and the omitted count is always stated.

local realprint = print          -- captured once: a reassigned global print cannot recurse

tprintConfig_libs= {
    table  = { 'table'  },
    string = { 'string' },
    number = { 'math'   },
}

-- Dump state. File-level so printDump also works outside tprint; with no file
-- open it simply falls back to the console.
local dumpFile   = nil
local dumpLines  = 0
local dumpBytes  = 0
local dumpFailed = nil
local wsTail     = ''            -- held-back trailing whitespace, never written

---------------------------------------------------------------- strings

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

---------------------------------------------------------------- identity & raw metatables

-- tostring() on a table/userdata/function invokes __tostring, which on a CE
-- object can fault. Only call it when the metatable has no __tostring; the
-- default form ("table: 0x…") is then safe and gives us the identity.
local function safeIdentity(v)
    local tv = type(v)
    if tv ~= 'table' and tv ~= 'userdata'
       and tv ~= 'function' and tv ~= 'thread' then
        return scalar(v)
    end
    local ok, mt = pcall(getmetatable, v)
    if ok and type(mt) == 'table' then
        local ok2, ts = pcall(rawget, mt, '__tostring')
        if ok2 and ts ~= nil then
            return '<' .. tv .. ' with __tostring>'
        end
    end
    local ok3, s = pcall(tostring, v)
    if ok3 and type(s) == 'string' then return s end
    return '<' .. tv .. '>'
end

-- The metatable slot, read raw. getmetatable honours __metatable, which is a
-- value rather than a call, so this cannot fault on a Lua table.
local function rawMeta(v)
    local ok, mt = pcall(getmetatable, v)
    if ok and mt ~= nil then return mt end
    return nil
end

---------------------------------------------------------------- byte / UTF-8 helpers

local function byteHex(s, from, to)
    local out = {}
    for i = from, to do out[#out+1] = string.format('%02X', s:byte(i)) end
    return table.concat(out, ' ')
end

local function byteDec(s, from, to)
    local out = {}
    for i = from, to do out[#out+1] = tostring(s:byte(i)) end
    return table.concat(out, ' ')
end

-- Returns valid, codepointCount, firstBadByteIndex, wasCoarse.
-- Prefers utf8.len (Lua 5.3+). The fallback is a COARSE lead/continuation
-- check: it does not reject overlong forms or surrogates.
local function utf8Stats(s)
    if type(utf8) == 'table' and type(utf8.len) == 'function' then
        local ok, n, bad = pcall(utf8.len, s)
        if ok then
            if n then return true, n, nil, false end
            return false, nil, bad, false
        end
    end
    local n, i, bad = 0, 1, nil
    while i <= #s do
        local c = s:byte(i)
        local need
        if     c < 0x80                then need = 0
        elseif c >= 0xC2 and c <= 0xDF then need = 1
        elseif c >= 0xE0 and c <= 0xEF then need = 2
        elseif c >= 0xF0 and c <= 0xF4 then need = 3
        else bad = i break end
        if i + need > #s then bad = i break end
        for k = 1, need do
            local cc = s:byte(i + k)
            if cc < 0x80 or cc > 0xBF then bad = i break end
        end
        if bad then break end
        n = n + 1
        i = i + need + 1
    end
    if bad then return false, nil, bad, true end
    return true, n, nil, true
end

-- 8-byte little-endian IEEE-754 double, or nil when string.pack is absent.
local function doubleBytesLE(n)
    if type(string.pack) ~= 'function' then return nil end
    local ok, s = pcall(string.pack, '<d', n)
    if ok and type(s) == 'string' and #s == 8 then return s end
    return nil
end

local function floatBytesLE(n)
    if type(string.pack) ~= 'function' then return nil end
    local ok, s = pcall(string.pack, '<f', n)
    if ok and type(s) == 'string' and #s == 4 then return s end
    return nil
end

local function int64BytesLE(n)
    if type(string.pack) ~= 'function' then return nil end
    if type(math.tointeger) ~= 'function' then return nil end
    local ok0, i = pcall(math.tointeger, n)
    if not ok0 or i == nil then return nil end
    local ok, s = pcall(string.pack, '<i8', i)
    if ok and type(s) == 'string' and #s == 8 then return s end
    return nil
end

local function reverseBytes(s)
    local out = {}
    for i = #s, 1, -1 do out[#out+1] = s:sub(i, i) end
    return table.concat(out)
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
    local dropped = #wsTail
    wsTail = ''                    -- THE TRIM: held whitespace is never written
    local pok, res, err = pcall(f.flush, f)
    if not pok or res == nil then
        dumpFailed = dumpFailed or ('flush failed: ' .. tostring(pok and err or res))
    end
    pok, res, err = pcall(f.close, f)
    if not pok or res == nil then
        dumpFailed = dumpFailed or ('close failed: ' .. tostring(pok and err or res))
    end
    return dropped
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

    local function line(s) printDump(toFile, s) end

    ---------------------------------------------------------- metatable report

    -- One level of metatable keys, plus one level of __index keys when it is a
    -- table. Bounded by construction: it never recurses further.
    local function emitMetatable(v, indent)
        local pad = string.rep('\t', indent)
        local mt  = rawMeta(v)
        if mt == nil then
            line(pad .. 'metatable: none')
            return
        end
        if type(mt) ~= 'table' then
            line(pad .. 'metatable: <shielded by __metatable = ' .. scalar(mt) .. '>')
            return
        end
        line(pad .. 'metatable: ' .. safeIdentity(mt))
        local ks = orderedKeys(mt)
        if #ks == 0 then
            line(pad .. '\t(empty)')
            return
        end

        -- `raw` is what the metatable stores. When that is a descriptor rather
        -- than a value, read the property through the object so __index can
        -- resolve it. Guarded, and the result is never tostring()ed if it is
        -- userdata -- safeIdentity/scalar handle that.
        local function render(k, raw)
            local val = raw
            if type(k) == 'string' and k:sub(1, 2) ~= '__'
               and type(raw) ~= 'string' and type(raw) ~= 'number'
               and type(raw) ~= 'boolean' then
                local okp, got = pcall(function() return v[k] end)
                if okp and got ~= nil then val = got end
            end
            if type(val) == 'table' or type(val) == 'userdata' then
                return safeIdentity(val)
            end
            return scalar(val)
        end

        local ix = nil
        for i = 1, #ks do
            local k = ks[i]
            local okv, raw = pcall(rawget, mt, k)
            if okv then
                line(pad .. '\t' .. keyLabel(k) .. ': ' .. render(k, raw))
                if k == '__index' and type(raw) == 'table' then ix = raw end
            end
        end

        if ix ~= nil and ix ~= mt then
            local iks = orderedKeys(ix)
            line(pad .. '\t__index keys (' .. #iks .. ' entries):')
            for i = 1, #iks do
                local k = iks[i]
                local okv, raw = pcall(rawget, ix, k)
                if okv then
                    line(pad .. '\t\t' .. keyLabel(k) .. ': ' .. render(k, raw))
                end
            end
        end
    end

    ---------------------------------------------------------- library report

    -- Eligible libraries, reached ONLY through a metatable.
    --
    -- setmetatable() accepts TABLES ONLY, so a fresh proxy is built per library
    -- rather than touching the value. debug.setmetatable() is deliberately not
    -- used: it would change the metatable of an entire type state-wide.
    --
    -- __index IS the library table, so enumerating it enumerates that library;
    -- the metatable is the route by which it is reached. Each name is then
    -- re-read THROUGH the proxy and compared, so the count of names that
    -- actually resolve is measured rather than assumed.
    local function emitLibrary(v)
        local tv = type(v)
        local cfg = tprintConfig_libs
        local names = (type(cfg) == 'table') and cfg[tv] or nil
        if type(names) ~= 'table' or #names == 0 then return end

        for li = 1, #names do
            local libName = names[li]
            local lib = _G[libName]
            if type(lib) ~= 'table' then
                line('library ' .. tostring(libName) .. ': absent in this Lua state')
            else
                -- THE ONLY ROUTE: a proxy table whose __index is the library.
                local okp, probe = pcall(setmetatable, {}, { __index = lib })
                if not okp or type(probe) ~= 'table' then
                    line('library ' .. libName .. ': proxy creation failed')
                else
                    local mt = getmetatable(probe)
                    local ix = (type(mt) == 'table') and mt.__index or nil
                    if type(ix) ~= 'table' then
                        line('library ' .. libName .. ': unreachable via __index')
                    else
                        local fns, consts = {}, {}
                        for k, val in next, ix do
                            if type(k) == 'string' then
                                if type(val) == 'function' then
                                    fns[#fns+1] = k
                                else
                                    consts[#consts+1] = k
                                end
                            end
                        end
                        pcall(table.sort, fns)
                        pcall(table.sort, consts)

                        -- Verify the mechanism: rawget must miss, proxy must hit.
                        local resolved, rawMiss = 0, 0
                        for i = 1, #fns do
                            local nm = fns[i]
                            if rawget(probe, nm) == nil then rawMiss = rawMiss + 1 end
                            local okr, got = pcall(function() return probe[nm] end)
                            if okr and got == ix[nm] then resolved = resolved + 1 end
                        end

                        line(string.format(
                            'library via __index = %s: %d function(s), %d/%d resolve, %d own',
                            libName, #fns, resolved, #fns, #fns - rawMiss))
                        for i = 1, #fns do
                            line('\t' .. libName .. '.' .. fns[i])
                        end
                        if #consts > 0 then
                            line(string.format('\t(%d constant(s): %s)',
                                #consts, table.concat(consts, ', ')))
                        end
                    end
                end
            end
        end
    end

    ---------------------------------------------------------- table walk

    -- No depth parameter and no depth test. `seen` only stops a table being
    -- descended into while it is already an ancestor of itself; it is cleared
    -- on the way out, so a table reached by two paths is shown in both places.
    local function dump(v, indent, label)
        local pad    = string.rep('\t', indent)
        local prefix = label and (pad .. label .. ': ') or pad

        if type(v) ~= 'table' then
            line(prefix .. scalar(v))
            return
        end

        if seen[v] then
            line(prefix .. '<cycle>')
            return
        end
        seen[v] = true

        local keys = orderedKeys(v)
        if #keys == 0 then
            line(prefix .. '{}')
            seen[v] = nil
            return
        end

        if label then line(prefix) end

        for i = 1, #keys do
            local k = keys[i]
            local okv, val = pcall(rawget, v, k)   -- raw: __index never invoked
            if not okv then
                line(string.rep('\t', indent + 1)
                     .. keyLabel(k) .. ': <unreadable>')
            else
                dump(val, indent + 1, keyLabel(k))
            end
        end

        seen[v] = nil
    end

    ---------------------------------------------------------- userdata

    local function dumpUserdata(obj)
        line('type: userdata')
        line('identity: ' .. safeIdentity(obj))
        emitMetatable(obj, 0)

        if type(full_internal) ~= 'function' then
            line('tprint: full_internal is not loaded; cannot expand userdata')
            return
        end

        local okf, rows = pcall(full_internal, obj)
        if not okf then
            line('tprint: full_internal raised: ' .. tostring(rows))
            return
        end
        if type(rows) ~= 'table' then
            line('tprint: full_internal returned no rows')
            return
        end

        local n = 0
        for i = 1, #rows do
            local r = rows[i]
            if type(r) == 'table' then
                n = n + 1
                local l = string.format('%-9s %s',
                    tostring(r.type or '?'), tostring(r.path or '?'))
                if r.value ~= nil then
                    l = l .. ' = ' .. scalar(r.value)
                end
                line(l)
            end
        end
        line(string.format('(%d row(s))', n))
    end

    ---------------------------------------------------------- string

    local function dumpString(s)
        local n = #s
        line('type: string')
        line('length: ' .. n .. ' byte(s)')
        line('value: ' .. renderString(s))

        local _, nl = s:gsub('\n', '')
        line('lines: ' .. tostring(nl + 1))

        local valid, cps, bad, coarse = utf8Stats(s)
        if valid then
            line('UTF-8: valid, ' .. cps .. ' codepoint(s)'
                 .. (coarse and ' (coarse check)' or ''))
        else
            line('UTF-8: invalid at byte ' .. tostring(bad)
                 .. (coarse and ' (coarse check)' or ''))
        end

        local dec = tonumber(s)
        line('tonumber(s): ' .. (dec ~= nil and tostring(dec) or 'nil'))
        local hexn = tonumber(s, 16)
        line('tonumber(s,16): ' .. (hexn ~= nil and tostring(hexn) or 'nil'))
        if type(getAddress) == 'function' then
            local oka, a = pcall(getAddress, s)
            if oka and type(a) == 'number' then
                line('getAddress(s): ' .. string.format('%X', a))
            else
                line('getAddress(s): unresolvable')
            end
        end

        if n > 0 then
            local cap = 0
            local shown = n
            line('bytes hex: ' .. byteHex(s, 1, shown))
            line('bytes dec: ' .. byteDec(s, 1, shown))
            line('per-byte:')
            for i = 1, shown do
                local c = s:byte(i)
                local pr = (c >= 0x20 and c < 0x7F) and string.char(c) or '.'
                line(string.format('\t[%d] %02X  %3d  %s', i, c, c, pr))
            end
            if shown < n then
                line('\t… ' .. (n - shown).. ')')
            end
        end

        emitMetatable(s, 0)
        emitLibrary(s)
    end

    ---------------------------------------------------------- number

    local function dumpNumber(v)
        line('type: number')

        local sub = 'unknown'
        if type(math.type) == 'function' then
            local okt, t = pcall(math.type, v)
            if okt and t then sub = t end
        end
        line('subtype: ' .. sub)
        line('value: ' .. tostring(v))
        if sub == 'integer' then
            line(string.format('hex: %X', v))
        else
            local oka, hx = pcall(string.format, '%a', v)
            line('hex: ' .. (oka and hx or tostring(v)))
        end
        line(string.format('scientific: %e', v))
        line(string.format('shortest: %g', v))

        local isInt = (v == math.floor(v) and v == v
                       and v ~= math.huge and v ~= -math.huge)
        line('integral: ' .. tostring(isInt))
        if type(math.tointeger) == 'function' then
            local oki, i = pcall(math.tointeger, v)
            line('math.tointeger: ' .. ((oki and i ~= nil) and tostring(i) or 'nil'))
        end
        line('sign: ' .. (v < 0 and '-' or (v == 0 and 'zero' or '+')))
        if v ~= v then line('isNaN: true') end
        if v == math.huge or v == -math.huge then line('isInf: true') end

        local d = doubleBytesLE(v)
        if d ~= nil then
            line('double LE: ' .. byteHex(d, 1, 8))
            line('double BE: ' .. byteHex(reverseBytes(d), 1, 8))
            local b1,b2,b3,b4,b5,b6,b7,b8 = d:byte(1,8)
            local sign = math.floor(b8 / 128)
            local exp  = (b8 % 128) * 16 + math.floor(b7 / 16)
            local low48 = b1 + b2*256 + b3*65536 + b4*16777216
                        + b5*4294967296 + b6*1099511627776
            local mant = (b7 % 16) * 281474976710656 + low48
            line(string.format(
                'IEEE754: sign=%d exponent=0x%03X (%d, unbiased %d) mantissa=0x%013X',
                sign, exp, exp, exp - 1023, mant))
            if exp == 0 then
                line('class: ' .. (mant == 0 and 'zero' or 'subnormal'))
            elseif exp == 0x7FF then
                line('class: ' .. (mant == 0 and 'infinity' or 'NaN'))
            else
                line('class: normal')
            end
        else
            line('double bytes: unavailable (string.pack absent)')
        end

        local f = floatBytesLE(v)
        if f ~= nil then line('float32 LE: ' .. byteHex(f, 1, 4)) end
        local i8 = int64BytesLE(v)
        if i8 ~= nil then line('int64 LE: ' .. byteHex(i8, 1, 8)) end

        if isInt and v > 0 and v < 281474976710656 then
            line(string.format('as address: %X', v))
            if type(getNameFromAddress) == 'function' then
                local okn, nm = pcall(getNameFromAddress, v, true, false, true)
                if okn and type(nm) == 'string' and nm ~= '' then
                    line('symbol: ' .. nm)
                end
            end
            if type(readBytes) == 'function' then
                local okb, b = pcall(readBytes, v, 16, true)
                if okb and type(b) == 'table' and #b > 0 then
                    local hx = {}
                    for i = 1, #b do hx[i] = string.format('%02X', b[i]) end
                    line('bytes at address: ' .. table.concat(hx, ' '))
                else
                    line('bytes at address: unreadable')
                end
            end
        end

        emitMetatable(v, 0)
        emitLibrary(v)
    end

    ---------------------------------------------------------- table

    local function dumpTable(t)
        line('type: table')
        line('identity: ' .. safeIdentity(t))

        local ks = orderedKeys(t)
        local nn, ns, no = 0, 0, 0
        for i = 1, #ks do
            local tk = type(ks[i])
            if     tk == 'number' then nn = nn + 1
            elseif tk == 'string' then ns = ns + 1
            else                       no = no + 1 end
        end
        line('keys: ' .. #ks .. ' (' .. nn .. ' number, '
             .. ns .. ' string, ' .. no .. ' other)')

        local rl
        if type(rawlen) == 'function' then
            local okr, r = pcall(rawlen, t)
            if okr then rl = r end
        end
        if rl == nil then
            local n = 0
            while rawget(t, n + 1) ~= nil do n = n + 1 end
            rl = n
        end
        line('rawlen: ' .. tostring(rl))

        local seq = true
        for i = 1, rl do
            if rawget(t, i) == nil then seq = false break end
        end
        if seq and nn ~= rl then seq = false end
        line('sequence: ' .. tostring(seq))

        emitMetatable(t, 0)
        emitLibrary(t)
        line('contents:')
        dump(t, 0, nil)
    end

    ---------------------------------------------------------- everything else

    local function dumpGeneric(v)
        line('type: ' .. type(v))
        line('value: ' .. scalar(v))
        if type(v) == 'function' or type(v) == 'thread' then
            line('identity: ' .. safeIdentity(v))
        end
        if type(v) == 'function' and type(debug) == 'table'
           and type(debug.getinfo) == 'function' then
            local oki, inf = pcall(debug.getinfo, v, 'Slnu')
            if oki and type(inf) == 'table' then
                line('what: ' .. tostring(inf.what))
                line('source: ' .. tostring(inf.short_src))
                line('linedefined: ' .. tostring(inf.linedefined))
                line('nups: ' .. tostring(inf.nups))
                line('isvararg: ' .. tostring(inf.isvararg))
            end
        end
        emitMetatable(v, 0)
        -- No library section: boolean / nil / function / thread are not eligible.
    end

    ---------------------------------------------------------- run

    local ok, err = pcall(function()
        local tv = type(tbl)
        if     tv == 'userdata' then dumpUserdata(tbl)
        elseif tv == 'string'   then dumpString(tbl)
        elseif tv == 'number'   then dumpNumber(tbl)
        elseif tv == 'table'    then dumpTable(tbl)
        else                         dumpGeneric(tbl) end
        line('')
    end)
    if not ok then
        dumpFailed = dumpFailed or ('walk failed: ' .. tostring(err))
    end

    local dropped = closeDump()

    if not toFile then realprint('') end

    if dumpFailed then
        realprint('tprint: INCOMPLETE — ' .. dumpFailed
                  .. ' (' .. dumpLines .. ' line(s) written to ' .. tostring(pth) .. ')')
    elseif toFile then
        local lns = dumpLines + (dumpBytes > 0 and 1 or 0)
        realprint(string.format(
            'tprint: finished — %d line(s), %d byte(s) → %s (trimmed %d trailing byte(s))',
            lns, dumpBytes, tostring(pth), dropped))
    end
end