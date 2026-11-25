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

function full_internal(v, maxDepth)
    local methodsOnce = true
    local md, depthLimit = tonumber(maxDepth), 0
    if md and md == md and md > 0 and md ~= math.huge then
        depthLimit = math.floor(md)
    end

    local loadstr  = loadstring or load
    local queue    = {}
    local out      = {}
    local visited  = {}
    local metaDone = {}

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

        local function formatSegment(seg)
            if seg:match('^%[%d+%]$') then
                return seg
            elseif seg:match('^[%a_][%w_]*%b()%[%d+%]$') then
                return '.' .. seg
            elseif seg:match('^[%a_][%w_]*%b()$') then
                return '.' .. seg
            elseif seg:match('^[%a_][%w_]*$') then
                return '.' .. seg
            else
                return '[' .. luaStr(seg) .. ']'
            end
        end

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

            local function emitOrEnqueue(basePath, seg, val, kind, depth, recurse, isRootChild)
                if not allowed(depth) then return end

                local fullPath = isRootChild and seg or (basePath .. formatSegment(seg))

                out[#out + 1] = {
                    value = val,
                    path  = fullPath,
                    type  = kind--[[,
                    depth = depth]]
                }

                if recurse and allowed(depth + 1) then
                    local ty = type(val)
                    if (ty == 'userdata' or ty == 'table') and not markVisited(val) then
                        queue[#queue + 1] = {
                            data  = val,
                            path  = fullPath,
                            depth = depth,
                        }
                    end
                end
            end

            local currentPath, currentDepth, w = '', 0, 0

            while true do
                local isRoot = (w == 0)
                if not isRoot then
                    local cr = queue[w]
                    if cr == nil then break end
                    queue[w] = nil
                    v = cr.data
                    currentPath = cr.path
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

                    -- 1. Metatable methods and fields
                    if allowed(childDepth) then
                        local cb, mt = pcall(getmetatable, v)
                        if cb and type(mt) == 'table' then
                            local isRepeatMeta = methodsOnce and metaDone[mt]
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

                                            if not (isRepeatMeta and type(v0) == 'function') then
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

                                                    if not (isRepeatMeta and kind == 'Method (Function)') then
                                                        local n = isRoot and (vna .. '.' .. k0) or k0
                                                        emitOrEnqueue(currentPath, n, shown, kind,
                                                        childDepth, false, isRoot)
                                                    end
                                                end
                                            end
                                        end
                                    end
                                end
                            end

                            -- 2. Lua table keys
                            if ty == 'table' then
                                for k, val in pairs(v) do
                                    local keyStr = tostring(k)
                                    local nm2 = isRoot and (vna .. '.' .. keyStr) or keyStr
                                    noteChild(val)
                                    emitOrEnqueue(currentPath, nm2, val, kindOfValue(val),
                                    childDepth, true, isRoot)
                                end
                            end

                            -- 3. Userdata inspection
                            if ty == 'userdata' then
                                -- 3a. Child components (always by getComponent(i) index)
                                local okCount, plc = pcall(function() return v.getComponentCount() end)
                                    if okCount and type(plc) == 'number' and plc > 0 then
                                        for i = 0, plc - 1 do
                                            local okComp, pli = pcall(function() return v.getComponent(i) end)
                                                if okComp and pli ~= nil then
                                                    local src = string.format('getComponent(%d)', i)
                                                    local nm2 = isRoot and (vna .. '.' .. src) or src
                                                    noteChild(pli)
                                                    emitOrEnqueue(currentPath, nm2, pli, 'Component',
                                                    childDepth, true, isRoot)
                                                end
                                            end
                                        end

                                        -- 3a-bis. Child controls (ControlCount / getControl(i))
                                        local okCtrlCnt, ctrlCount = pcall(function() return v.ControlCount end)
                                            if not okCtrlCnt or type(ctrlCount) ~= 'number' then
                                                okCtrlCnt, ctrlCount = pcall(function() return v.getControlCount() end)
                                                end
                                                if okCtrlCnt and type(ctrlCount) == 'number'
                                                and ctrlCount > 0 then
                                                    for i = 0, ctrlCount - 1 do
                                                        local okCtrl, ctrl = pcall(function() return v.getControl(i) end)
                                                            if okCtrl and ctrl ~= nil and not seenChild[ctrl] then
                                                                local src = string.format('getControl(%d)', i)
                                                                local nm2 = isRoot and (vna .. '.' .. src) or src
                                                                noteChild(ctrl)
                                                                emitOrEnqueue(currentPath, nm2, ctrl, 'Control',
                                                                childDepth, true, isRoot)
                                                            end
                                                        end
                                                    end

                                                    -- 3b. Published properties (Owner/Parent non-recursive)
                                                    local seenPropOwner, seenPropParent = false, false
                                                    local okPL, propertyList = pcall(getPropertyList, v)
                                                    if okPL and propertyList ~= nil then
                                                        local okC, propCount = pcall(function() return propertyList.Count end)
                                                            if okC and type(propCount) == 'number'
                                                            and propCount > 0 then
                                                                for i = 0, propCount - 1 do
                                                                    local okI, pli = pcall(function() return propertyList[i] end)
                                                                        if okI and type(pli) == 'string' then
                                                                            if pli == 'Owner' then seenPropOwner = true end
                                                                            if pli == 'Parent' then seenPropParent = true end

                                                                            local okV, val = pcall(function() return v[pli] end)
                                                                                if not okV then val = nil end
                                                                                local nm2 = isRoot and (vna .. '.' .. pli) or pli
                                                                                local shouldRecurse = (pli ~= 'Parent' and pli ~= 'Owner')
                                                                                if shouldRecurse then noteChild(val) end
                                                                                emitOrEnqueue(currentPath, nm2, val, kindOfValue(val),
                                                                                childDepth, shouldRecurse, isRoot)
                                                                            end
                                                                        end
                                                                    end
                                                                    pcall(function() propertyList.destroy() end)
                                                                    end

                                                                    -- Fallback for Owner / Parent via C getters
                                                                    if allowed(childDepth) then
                                                                        if not seenPropOwner then
                                                                            local okOw, ow = pcall(function() return v.Owner end)
                                                                                if okOw and ow ~= nil then
                                                                                    local nm2 = isRoot and (vna .. '.Owner') or 'Owner'
                                                                                    emitOrEnqueue(currentPath, nm2, ow, 'Property',
                                                                                    childDepth, false, isRoot)
                                                                                end
                                                                            end
                                                                            if not seenPropParent then
                                                                                local okPa, pa = pcall(function() return v.Parent end)
                                                                                    if okPa and pa ~= nil then
                                                                                        local nm2 = isRoot and (vna .. '.Parent') or 'Parent'
                                                                                        emitOrEnqueue(currentPath, nm2, pa, 'Property',
                                                                                        childDepth, false, isRoot)
                                                                                    end
                                                                                end
                                                                            end
                                                                            -- 3c. Indexed collections
                                                                            local okVc, vc = pcall(function() return v.Count or v.count end)
                                                                                if okVc and type(vc) == 'number' and vc > 0 then
                                                                                    for i = 0, vc - 1 do
                                                                                        local okItem, itemVal = pcall(function() return v[i] end)
                                                                                            if okItem and itemVal ~= nil and not seenChild[itemVal] then
                                                                                                noteChild(itemVal)
                                                                                                local idx = string.format('[%d]', i)
                                                                                                local nm2 = isRoot and (vna .. idx) or idx
                                                                                                emitOrEnqueue(currentPath, nm2, itemVal, 'Value (' .. idx .. ')',
                                                                                                childDepth, true, isRoot)
                                                                                            end
                                                                                        end
                                                                                    end
                                                                                end
                                                                            end
                                                                            w = w + 1
                                                                        end
                                                                        return out
                                                                    end