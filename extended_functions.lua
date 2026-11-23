function enumModuleSymbols()
	local m=enumModules()
	local m_az={}
	for k,v in pairs(m) do
		local ma=v.Address
		local vn=v.Name
		local vns=getModuleSize(vn)
		local mlb=ma+vns-1
		table.insert(m_az,{ma,mlb,vn,vns})
	end
	local out={}
	for k,v in pairs(getMainSymbolList().getSymbolList()) do
		local md,sz,ed=nil,nil,nil
		
		for k1,v1 in pairs(m_az) do
            ed=v1[2]
			if v>=v1[1] and v<=ed then
				md=v1[3]
				sz=v1[4]
			end
		end

		if md~=nil then --modules only
			table.insert(out,{ Address=v, HexAddress=string.format('%X',v), Name=k, ModuleName=md, Size=sz, EndAddress=ed, EndHexAddress=string.format('%X',ed)})
		end

	end

	table.sort(out, function(a, b) return a.Address < b.Address end)

	return out
end

function table_filter(t,f)
	local out={}
	for k,v in pairs(t) do
		local tyk=type(k)
		if f(v,k,t) then
			if tyk=='number' then
				table.insert(out,v)
			else
				 out[k]=v
			end
		end
	end
	return out
end

function table_map(t,f) -- Javascript port
	local out={}
	for k,v in pairs(t) do
		out[k]=f(v,k,t)
	end
	return out
end


local function trim_str(s)
	return string.match(s,'^()%s*$') and '' or string.match(s,'^%s*(.*%S)')
end

local function deepcopy(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == 'table' then
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[deepcopy(orig_key)] = deepcopy(orig_value)
		end
		setmetatable(copy, deepcopy(getmetatable(orig)))
	else -- number, string, boolean, etc
		copy = orig
	end
	return copy
end

-- full_internal(rootObj [, onRow [, opts]])
--
--   onRow == nil       Returns the list of rows {type=, path=, value=}, exactly
--                      as before. The whole list is held in memory.
--   onRow == function  STREAMING. onRow(type, path, value) is called once per
--                      row, in the same order the list would have had, and
--                      nothing is accumulated. Returns the number of rows.
--                      Use this for anything large: memory stays flat.
--   opts.methodsOnce   Optional. Every node that shares a metatable re-emits that
--                      metatable's whole method list, which is usually the bulk
--                      of the rows. With this set, a method is emitted once per
--                      metatable; Property rows (values differ per object) are
--                      still emitted for every node. Default: off (full output).

-- Index / call through pcall WITHOUT building a closure per call.
local function rawIndex(o, k) return o[k] end
local function callMethod(o, name, ...) return o[name](...) end

local function luaStr(s)
	s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
	     :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
	return '"' .. s .. '"'
end

-- Path segment rendering. A positive identifier test, not a "contains a special
-- character" test, so getComponent(0) is a call and not a field.
local function seg(py)
	if py:match('^%[%d+%]$') then
		return py                              -- pre-formatted array index: [0]
	elseif py:match('^[%a_][%w_]*%b()%[%d+%]$') then
		return '.' .. py                       -- call followed by index
	elseif py:match('^[%a_][%w_]*%b()$') then
		return '.' .. py                       -- call expression: getComponent(0)
	elseif py:match('^[%a_][%w_]*$') then
		return '.' .. py                       -- ordinary field name
	end
	return '[' .. luaStr(py) .. ']'            -- genuine string key
end


-- full_internal(rootObj [, onRow] [, opts])
--
-- onRow(kind, path, value, depth)
--   Optional. When present, rows are handed over one at a time and NOT
--   accumulated; the return value is the row COUNT (a number), so a caller
--   that tests `type(res) == 'table'` will not double-emit.
--   When absent, the row LIST is returned, exactly as before.
--
-- maxDepth      nil / <=0 / NaN / inf = unlimited. 1 = the root's direct
--                    children only (a.b, not a.b.c). Enforced at ENQUEUE, so
--                    refused nodes are never produced and never marked visited.
-- methodsOnce   true = list a metatable's methods once, not once per object.
-- resolveMeta   default true. A metatable entry is a BINDING, not a value;
--                    read it through the object so __index resolves it.
--
-- Rows now carry `depth`, measured in components after the root: root = 0,
-- a.b = 1. That is the same scale as tprint's `indent`, so the two agree.
--
-- Needs trim_str from the surrounding file.

function full_internal(rootObj, maxDepth)
    opts = opts or {}
    local streaming   = true
    local methodsOnce = false
    local resolveMeta = true
    local loadstr     = loadstring or load

    local md, maxDepth = tonumber(opts.maxDepth), 0
    if md and md == md and md > 0 and md ~= math.huge then
        maxDepth = math.floor(md)
    end

    local plt, pltFinal = {}, {}
    local visited  = {}
    local metaDone = {}          -- methodsOnce: metatables already listed
    local emitted  = 0

    local function copyPath(t)
        local o = {}
        for i = 1, #t do o[i] = t[i] end
        return o
    end

    -- Identity by OBJECT. CE userdata frequently override __tostring to return
    -- a class name or caption, so tostring() keys collide and prune the graph.
    local function markVisited(obj)
        local ty = type(obj)
        if ty ~= 'userdata' and ty ~= 'table' then return false end
        if visited[obj] then return true end
        visited[obj] = true
        return false
    end

    -- tostring() on a CE object can fault. pcall is mitigation, NOT a guarantee:
    -- a native access violation is not reliably catchable.
    local function safeVal(v)
        local tv = type(v)
        if tv ~= 'userdata' and tv ~= 'table' then return v end
        local ok, s = pcall(tostring, v)
        if ok and type(s) == 'string' then return s end
        return '<' .. tv .. '>'
    end

    local function allowed(depth)
        return maxDepth <= 0 or depth <= maxDepth
    end

    -- Root name. Guarded, identifier-only, and it must resolve back to rootObj:
    -- the pattern also stops `load` executing arbitrary text from a Name.
    local vn, vna = '…', '(…)'
    local okN, nm = pcall(function() return rootObj.Name end)
    if okN and type(nm) == 'string' and nm:match('^[%a_][%w_]*$') then
        local f = loadstr('return ' .. nm)
        if f then
            local okR, r = pcall(f)
            if okR and r == rootObj then vn, vna = nm, nm end
        end
    end

    local function proc(k, p)
        local ks = tostring(k)
        local ok, v = pcall(function() return p[k] end)
        if not ok or v == nil then return '(…):' .. ks .. '(…)' end
        return vna .. '.' .. ks .. '(…)'
    end

    markVisited(rootObj)

    -- ONE enqueue path, so the depth gate and the visited test cannot drift
    -- between the four call sites. isRaw keeps a metatable value untouched.
    local function push(p2, name, val, kind, depth, recurse, isRaw)
        if not allowed(depth) then return end
        local np2 = copyPath(p2)
        np2[#np2 + 1] = name
        local nextData = nil
        if recurse then
            local ty = type(val)
            if (ty == 'userdata' or ty == 'table') and not markVisited(val) then
                nextData = val
            end
        end
        plt[#plt + 1] = {
            path2 = np2,
            data  = nextData,
            val   = isRaw and val or safeVal(val),
            type  = kind,
            depth = depth,
        }
    end

    local v, p2, currentDepth, w = rootObj, {}, 0, 0

    while true do
        if w > 0 then
            local cr = plt[w]
            if cr == nil then break end
            v = cr.data
            p2 = cr.path2               -- shared, never mutated; push copies
            currentDepth = cr.depth
        end

        local ty = type(v)
        if ty == 'userdata' or ty == 'table' then
            local childDepth = currentDepth + 1
            local seenChild = {}
            local function noteChild(o)
                local t = type(o)
                if t == 'userdata' or t == 'table' then seenChild[o] = true end
            end

            -- 1. Metatable methods and fields. CE/LCL usually put the methods
            --    in __index, so walk both, deduplicated by key.
            if allowed(childDepth) then
                local cb, mt = pcall(getmetatable, v)
                if cb and type(mt) == 'table'
                   and not (methodsOnce and metaDone[mt]) then
                    if methodsOnce then metaDone[mt] = true end
                    local sources = { mt }
                    local okIx, ix = pcall(function() return mt.__index end)
                    if okIx and type(ix) == 'table' then sources[2] = ix end
                    local seenKey = {}
                    for si = 1, #sources do
                        for k0, v0 in pairs(sources[si]) do
                            if type(k0) == 'string' and k0:sub(1, 2) ~= '__'
                               and not seenKey[k0] then
                                seenKey[k0] = true
                                local shown, kind = v0, 'Method'
                                if resolveMeta then
                                    local tv0 = type(v0)
                                    if tv0 == 'table' or tv0 == 'userdata'
                                       or tv0 == 'function' then
                                        local okp, got = pcall(function() return v[k0] end)
                                        if okp and got ~= nil then
                                            shown = got
                                            kind = (type(got) == 'function')
                                                   and 'Method' or 'Property'
                                        end
                                    end
                                end
                                local n = (w > 0) and k0 or proc(k0, v)
                                push(p2, n, shown, kind, childDepth, false, true)
                            end
                        end
                    end
                end
            end

            -- 2. Lua table keys.
            if ty == 'table' then
                for k, val in pairs(v) do
                    local keyStr = tostring(k)
                    local nm2 = (w > 0) and keyStr or (vna .. '.' .. keyStr)
                    local isObj = (type(val) == 'userdata' or type(val) == 'table')
                    noteChild(val)
                    push(p2, nm2, val, isObj and 'Object' or 'Property',
                         childDepth, true)
                end
            end

            -- 3. Userdata inspection.
            if ty == 'userdata' then
                -- 3a. Child components.
                local okCount, plc = pcall(function() return v.getComponentCount() end)
                if okCount and type(plc) == 'number' and plc > 0 and plc < 100000 then
                    for i = 0, plc - 1 do
                        local okComp, pli = pcall(function() return v.getComponent(i) end)
                        if okComp and pli ~= nil then
                            local okName, pli_nm = pcall(function() return pli.Name end)
                            local src
                            if okName and type(pli_nm) == 'string'
                               and trim_str(pli_nm) ~= '' then
                                src = trim_str(pli_nm)
                            else
                                src = string.format('getComponent(%d)', i)
                            end
                            local nm2 = (w > 0) and src or (vna .. '.' .. src)
                            noteChild(pli)
                            push(p2, nm2, pli, 'Component', childDepth, true)
                        end
                    end
                end

                -- 3b. Published properties. Every member access is guarded:
                --     getPropertyList may be absent, and its result may lack
                --     .Count, integer indexing or .destroy().
                local okPL, propertyList = pcall(getPropertyList, v)
                if okPL and propertyList ~= nil then
                    local okC, propCount = pcall(function() return propertyList.Count end)
                    if okC and type(propCount) == 'number'
                       and propCount > 0 and propCount < 100000 then
                        for i = 0, propCount - 1 do
                            local okI, pli = pcall(function() return propertyList[i] end)
                            if okI and type(pli) == 'string'
                               and pli ~= 'Parent' and pli ~= 'Owner' then
                                local okV, val = pcall(function() return v[pli] end)
                                if not okV then val = nil end
                                local nm2 = (w > 0) and pli or (vna .. '.' .. pli)
                                local isObj = (type(val) == 'userdata' or type(val) == 'table')
                                noteChild(val)
                                push(p2, nm2, val, isObj and 'Object' or 'Property',
                                     childDepth, true)
                            end
                        end
                    end
                    -- Reached even when the loop above raised or was skipped.
                    pcall(function() propertyList.destroy() end)
                end

                -- 3c. Indexed collections. Skips anything 3a/3b already emitted,
                --     which is where the duplicate rows came from.
                local okVc, vc = pcall(function() return v.Count or v.count end)
                if okVc and type(vc) == 'number' and vc > 0 and vc < 10000 then
                    for i = 0, vc - 1 do
                        local okItem, itemVal = pcall(function() return v[i] end)
                        if okItem and itemVal ~= nil and not seenChild[itemVal] then
                            noteChild(itemVal)
                            local idx = string.format('[%d]', i)
                            -- At root level the object prefix must be kept,
                            -- otherwise the whole path is just "[0]".
                            local nm2 = (w > 0) and idx or (vna .. idx)
                            local isObj = (type(itemVal) == 'userdata' or type(itemVal) == 'table')
                            push(p2, nm2, itemVal, isObj and 'Object' or 'Value',
                                 childDepth, true)
                        end
                    end
                end
            end
        end

        w = w + 1
    end

    -- Path rendering. A positive identifier test, plus call-expression branches
    -- so getComponent(0) is not quoted as a string key.
    local function luaStr(s)
        s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
             :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. s .. '"'
    end

    -- #plt is captured BEFORE any entry is released, so nil-ing is safe.
    local n = #plt
    for i = 1, n do
        local pi = plt[i]
        local pathArr = pi.path2
        for y = 2, #pathArr do
            local py = pathArr[y]
            if py:match('^%[%d+%]$') then
                pathArr[y] = py
            elseif py:match('^[%a_][%w_]*%b()%[%d+%]$') then
                pathArr[y] = '.' .. py
            elseif py:match('^[%a_][%w_]*%b()$') then
                pathArr[y] = '.' .. py
            elseif py:match('^[%a_][%w_]*$') then
                pathArr[y] = '.' .. py
            else
                pathArr[y] = '[' .. luaStr(py) .. ']'
            end
        end
        local path = table.concat(pathArr, '')

        if streaming then
            onRow(pi.type, path, pi.val, pi.depth)
            emitted = emitted + 1
            plt[i] = nil                 -- release the queue as we drain it
        else
            local ptj = { type = pi.type, path = path, depth = pi.depth }
            if pi.val ~= nil then ptj.value = pi.val end
            pltFinal[#pltFinal + 1] = ptj
        end
    end

    if streaming then return emitted end
    return pltFinal
end