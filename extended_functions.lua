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
    return string.match(s, '^()%s*$') and '' or string.match(s, '^%s*(.*%S)')
end

local function luaStr(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
         :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
end

-- full_internal(v [, maxDepth]) -> { {value=…, path=…, type=…, depth=…}, … }
--
-- maxDepth   nil / <=0 / NaN / inf = unlimited. 1 = the root's direct children
--            only (a.b, not a.b.c). Enforced at ENQUEUE, so a refused node is
--            never produced and never marked visited -- the same object reached
--            later at a shallower depth is still expanded.
--
-- type       'Method (Function)'  a function, from the metatable or a property
--            'Property'           a published property or a plain table key
--            'Component'          getComponent(i)
--            'Value ([i])'        an indexed-collection item, index included
--
-- value      The raw value. NOT stringified: a CE property descriptor is a real
--            table {__get=…, __set=…} and stringifying it would destroy the very
--            thing this returns. Rendering is the consumer's job -- tprint's
--            scalar() prints userdata without calling tostring, so this is safe.
--
--            A metatable entry that IS a descriptor is returned as that table.
--            To get the resolved value instead, see the marked line below.
--
-- depth      Components after the root: root = 0, a.b = 1. Same scale as
--            tprint's indent. Delete the marked line for strictly three fields.

function full_internal(v, maxDepth)
    local md, depthLimit = tonumber(maxDepth), 0
    if md and md == md and md > 0 and md ~= math.huge then
        depthLimit = math.floor(md)
    end

    local loadstr  = loadstring or load
    local plt, out = {}, {}
    local visited  = {}

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

    local function allowed(depth)
        return depthLimit <= 0 or depth <= depthLimit
    end

    -- A CE property descriptor: a table whose __get / __set are functions.
    local function descriptorOf(x)
        if type(x) ~= 'table' then return nil end
        local okg, g = pcall(rawget, x, '__get')
        local oks, s = pcall(rawget, x, '__set')
        if (okg and type(g) == 'function') or (oks and type(s) == 'function') then
            return x
        end
        return nil
    end

    local function kindOfValue(x)
        return (type(x) == 'function') and 'Method (Function)' or 'Property'
    end

    -- Root name. Guarded, identifier-only, and it must resolve back to v: the
    -- pattern also stops `load` executing arbitrary text from a Name.
    local rootObj = v
    local vna = '(…)'
    local okN, nm = pcall(function() return rootObj.Name end)
    if okN and type(nm) == 'string' and nm:match('^[%a_][%w_]*$') then
        local f = loadstr('return ' .. nm)
        if f then
            local okR, r = pcall(f)
            if okR and r == rootObj then vna = nm end
        end
    end

    markVisited(rootObj)

    -- ONE enqueue path, so the depth gate and the visited test cannot drift
    -- between the four call sites.
    local function push(p2, name, val, kind, depth, recurse)
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
            val   = val,
            type  = kind,
            depth = depth,
        }
    end

    local p2, currentDepth, w = {}, 0, 0

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
                if cb and type(mt) == 'table' then
                    local sources = { mt }
                    local okIx, ix = pcall(function() return mt.__index end)
                    if okIx and type(ix) == 'table' then sources[2] = ix end
                    local seenKey = {}
                    for si = 1, #sources do
                        for k0, v0 in pairs(sources[si]) do
                            if type(k0) == 'string' and k0:sub(1, 2) ~= '__'
                               and not seenKey[k0] then
                                seenKey[k0] = true

                                local shown, kind
                                local desc = descriptorOf(v0)
                                if desc then
                                    -- THE MARKED LINE: swap these two to prefer
                                    -- the resolved value over the descriptor.
                                    shown, kind = desc, 'Property'
                                elseif type(v0) == 'function' then
                                    shown, kind = v0, 'Method (Function)'
                                else
                                    local okp, got = pcall(function() return v[k0] end)
                                    if okp and got ~= nil then
                                        shown, kind = got, kindOfValue(got)
                                    else
                                        shown, kind = v0, 'Property'
                                    end
                                end

                                local n = (w > 0) and k0 or (vna .. '.' .. k0)
                                push(p2, n, shown, kind, childDepth, false)
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
                    noteChild(val)
                    push(p2, nm2, val, kindOfValue(val), childDepth, true)
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
                                noteChild(val)
                                push(p2, nm2, val, kindOfValue(val), childDepth, true)
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
                            push(p2, nm2, itemVal, 'Value (' .. idx .. ')',
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

        out[#out + 1] = {
            value = pi.val,
            path  = table.concat(pathArr, ''),
            type  = pi.type--[[,
            depth = pi.depth]]
        }
        plt[i] = nil                 -- release the queue as we drain it
    end

    return out
end