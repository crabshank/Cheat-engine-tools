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

function full_internal(rootObj)
    local plt = {}
    local pltFinal = {}
    local visited = {}          -- keyed by the OBJECT, not by tostring(obj)

    -- path2 is an array of immutable strings: a shallow copy is sufficient.
    local function copyPath(t)
        local o = {}
        for i = 1, #t do o[i] = t[i] end
        return o
    end

    -- Identity by object. CE userdata frequently override __tostring to return
    -- a class name or caption, so tostring() keys collide and silently prune
    -- the graph. Tables and userdata are both valid table keys.
    local function markVisited(obj)
        local ty = type(obj)
        if ty ~= 'userdata' and ty ~= 'table' then return false end
        if visited[obj] then return true end
        visited[obj] = true
        return false
    end

    -- Root name. Guarded: many CE userdata raise on an unknown property read.
    -- The identifier pattern also prevents `load` from executing arbitrary
    -- text, and the identity test stops a Name like "print" being accepted.
    local vn, vna = '…', '(…)'
    local okN, nm = pcall(function() return rootObj.Name end)
    if okN and type(nm) == 'string' and nm:match('^[%a_][%w_]*$') then
        local f = load('return ' .. nm)
        if f then
            local okR, r = pcall(f)
            if okR and r == rootObj then
                vn, vna = nm, nm
            end
        end
    end

    local function proc(k, p)
        local ks = tostring(k)
        local ok, v = pcall(function() return p[k] end)
        if not ok or v == nil then
            return '(…):' .. ks .. '(…)'
        end
        return vna .. '.' .. ks .. '(…)'
    end

    markVisited(rootObj)

    -- One enqueue path, so the depth cap, the row cap and the visited test
    -- are applied uniformly rather than being repeated at each call site.
    local function enqueue(p2, name, val, kind, depth, recurse)
        local np2 = copyPath(p2)
        np2[#np2 + 1] = name
        local isObj = (type(val) == 'userdata' or type(val) == 'table')
        local nextData = nil
        if recurse and isObj and not markVisited(val) then
            nextData = val
        end
        plt[#plt + 1] = {
            path2 = np2,
            data  = nextData,
            val   = isObj and tostring(val) or val,
            type  = kind,
            depth = depth
        }
    end

    local v = rootObj
    local p2 = {}
    local currentDepth = 0
    local w = 0

    while true do
        if w > 0 then
            local cr = plt[w]
            if cr == nil then break end
            v = cr.data
            p2 = cr.path2               -- shared, never mutated; enqueue copies
            currentDepth = cr.depth
        end

        local canRecurse = (type(v) == 'userdata' or type(v) == 'table')

        if canRecurse then
            -- Children already emitted for THIS node, so the component walk
            -- and the indexed walk cannot produce the same row twice.
            local seenChild = {}
            local function noteChild(o)
                local ty = type(o)
                if ty == 'userdata' or ty == 'table' then seenChild[o] = true end
            end

            -- 1. Metatable methods and fields. CE/LCL metatables commonly
            --    place methods in __index, so walk both, deduplicated.
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
                            local n = (w > 0) and k0 or proc(k0, v)
                            local np2 = copyPath(p2)
                            np2[#np2 + 1] = n

                            -- ClassName / Caption / AnchorSideLeft etc. sit in
                            -- the metatable as descriptor tables. v[k0] runs
                            -- __index and yields the actual value. Only tried
                            -- for non-scalars, and never for '__' keys.
                            local shown, kind = v0, 'Method'
                            local tv0 = type(v0)
                            if (tv0 == 'table' or tv0 == 'userdata' or tv0 == 'function') then
                                local okp, got = pcall(function() return v[k0] end)
                                if okp and got ~= nil then
                                    shown = got
                                    -- Now the label can be a finding rather
                                    -- than a blanket assumption.
                                    kind = (type(got) == 'function') and 'Method' or 'Property'
                                end
                            end

                            plt[#plt + 1] = {
                                path2 = np2,
                                data  = nil,    -- still never recurse from here
                                val   = shown,
                                type  = kind,
                                depth = currentDepth + 1
                            }
                        end
                    end
                end
            end

            -- 2. Lua table keys.
            if type(v) == 'table' then
                for k, val in pairs(v) do
                    local keyStr = tostring(k)
                    local nm2 = (w > 0) and keyStr or (vna .. '.' .. keyStr)
                    local isObj = (type(val) == 'userdata' or type(val) == 'table')
                    noteChild(val)
                    enqueue(p2, nm2, val, isObj and 'Object' or 'Property',
                            currentDepth + 1, true)
                end
            end

            -- 3. Userdata inspection.
            if type(v) == 'userdata' then
                -- 3a. Child components.
                local okCount, plc = pcall(function() return v.getComponentCount() end)
                if okCount and type(plc) == 'number' then
                    for i = 0, plc - 1 do
                        local okComp, pli = pcall(function() return v.getComponent(i) end)
                        if okComp and pli ~= nil then
                            local okName, pli_nm = pcall(function() return pli.Name end)
                            local nm2src
                            if okName and type(pli_nm) == 'string'
                               and trim_str(pli_nm) ~= '' then
                                nm2src = trim_str(pli_nm)
                            else
                                nm2src = string.format('getComponent(%d)', i)
                            end
                            local nm2 = (w > 0) and nm2src or (vna .. '.' .. nm2src)
                            noteChild(pli)
                            enqueue(p2, nm2, pli, 'Component', currentDepth + 1, true)
                        end
                    end
                end

                -- 3b. Published properties. Every member access is guarded:
                --     getPropertyList may be absent, and its result may not
                --     have .Count, integer indexing, or .destroy().
                local okPL, propertyList = pcall(getPropertyList, v)
                if okPL and propertyList ~= nil then
                    local okC, propCount = pcall(function() return propertyList.Count end)
                    if okC and type(propCount) == 'number' then
                        for i = 0, propCount - 1 do
                            local okI, pli = pcall(function() return propertyList[i] end)
                            if okI and type(pli) == 'string'
                               and pli ~= 'Parent' and pli ~= 'Owner' then
                                local okV, val = pcall(function() return v[pli] end)
                                if not okV then val = nil end
                                local nm2 = (w > 0) and pli or (vna .. '.' .. pli)
                                local isObj = (type(val) == 'userdata' or type(val) == 'table')
                                noteChild(val)
                                enqueue(p2, nm2, val, isObj and 'Object' or 'Property',
                                        currentDepth + 1, true)
                            end
                        end
                    end
                    -- Reached even when the loop above raised or was skipped.
                    pcall(function() propertyList.destroy() end)
                end

                -- 3c. Indexed collections. Skips anything 3a/3b already
                --     emitted, which is where the duplicate rows came from.
                local okVc, vc = pcall(function() return v.Count or v.count end)
                if okVc and type(vc) == 'number' then
                    for i = 0, vc - 1 do
                        local okItem, itemVal = pcall(function() return v[i] end)
                        if okItem and itemVal ~= nil and not seenChild[itemVal] then
                            noteChild(itemVal)
                            local idx = string.format('[%d]', i)
                            -- At root level the object prefix must be kept,
                            -- otherwise the whole path is just "[0]".
                            local nm2 = (w > 0) and idx or (vna .. idx)
                            local isObj = (type(itemVal) == 'userdata' or type(itemVal) == 'table')
                            enqueue(p2, nm2, itemVal, isObj and 'Object' or 'Value',
                                    currentDepth + 1, true)
                        end
                    end
                end
            end
        end

        w = w + 1
    end

    -- Path rendering. A positive identifier test, not a "contains a special
    -- character" test: the old class missed '(' ')' '[' ']' '-', so
    -- getComponent(0) became .getComponent(0), which is a call, not a field.
    local function luaStr(s)
        s = s:gsub('\\', '\\\\'):gsub('"', '\\"')
             :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        return '"' .. s .. '"'
    end

    for i = 1, #plt do
        local pi = plt[i]
        local pathArr = pi.path2

		for y = 2, #pathArr do
			local py = pathArr[y]

			if py:match('^%[%d+%]$') then
				-- pre-formatted array index: [0]
				pathArr[y] = py

			elseif py:match('^[%a_][%w_]*%b()%[%d+%]$') then
				-- call followed by index: getPropertyList(x)[0]
				pathArr[y] = '.' .. py

			elseif py:match('^[%a_][%w_]*%b()$') then
				-- call expression: getComponent(0)
				pathArr[y] = '.' .. py

			elseif py:match('^[%a_][%w_]*$') then
				-- ordinary field name
				pathArr[y] = '.' .. py

			else
				-- genuine string key
				pathArr[y] = '[' .. luaStr(py) .. ']'
			end
		end

        local ptj = { type = pi.type, path = table.concat(pathArr, '') }
        if pi.val ~= nil then ptj.value = pi.val end
        pltFinal[#pltFinal + 1] = ptj
    end

    return pltFinal
end