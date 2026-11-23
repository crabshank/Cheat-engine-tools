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

function full_internal(rootObj, onRow, opts)
	local stream = (type(onRow) == 'function')
	local rows
	if not stream then rows = {} end
	local nrows = 0

	local methodCache = nil
	if type(opts) == 'table' and opts.methodsOnce then methodCache = {} end

	-- Every row goes through here and is either handed on or stored. Paths are
	-- rendered ONCE, as strings, when the row is made: there is no per-row array
	-- of path segments to copy, and no second "final" copy of the whole list.
	local function emit(kind, path, value)
		nrows = nrows + 1
		if stream then
			onRow(kind, path, value)
		else
			local r = { type = kind, path = path }
			if value ~= nil then r.value = value end
			rows[nrows] = r
		end
	end

	local visited = {}          -- keyed by the OBJECT, not by tostring(obj)

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
	local vna = '(…)'
	local okN, nm = pcall(rawIndex, rootObj, 'Name')
	if okN and type(nm) == 'string' and nm:match('^[%a_][%w_]*$') then
		local f = load('return ' .. nm)
		if f then
			local okR, r = pcall(f)
			if okR and r == rootObj then vna = nm end
		end
	end

	local function proc(k, p)
		local ks = tostring(k)
		local ok, v = pcall(rawIndex, p, k)
		if not ok or v == nil then
			return '(…):' .. ks .. '(…)'
		end
		return vna .. '.' .. ks .. '(…)'
	end

	-- Breadth-first work list, as two arrays per LEVEL rather than one record per
	-- row. Only objects that still have to be expanded are queued; leaf rows and
	-- metatable rows are emitted immediately and never stored. A finished level
	-- is dropped whole.
	local nd, np, nn = {}, {}, 0

	-- One child row; queues the child for expansion the first time it is seen.
	local function child(parentPath, name, val, kind)
		local path
		if parentPath == nil then path = name else path = parentPath .. seg(name) end
		local tv = type(val)
		if tv == 'userdata' or tv == 'table' then
			if not markVisited(val) then
				nn = nn + 1
				nd[nn] = val
				np[nn] = path
			end
			emit(kind, path, tostring(val))
		else
			emit(kind, path, val)
		end
	end

	-- Children already emitted for THIS node, so the component walk and the
	-- indexed walk cannot produce the same row twice.
	local seenChild
	local function noteChild(o)
		local ty = type(o)
		if ty == 'userdata' or ty == 'table' then seenChild[o] = true end
	end

	local function expand(v, parentPath)
		local isRoot = (parentPath == nil)
		local ty = type(v)
		if ty ~= 'userdata' and ty ~= 'table' then return end
		seenChild = {}

		-- 1. Metatable methods and fields. CE/LCL metatables commonly place
		--    methods in __index, so walk both, deduplicated.
		local cb, mt = pcall(getmetatable, v)
		if cb and type(mt) == 'table' then
			local sources = { mt }
			local okIx, ix = pcall(rawIndex, mt, '__index')
			if okIx and type(ix) == 'table' then sources[2] = ix end

			local known = nil
			if methodCache then
				known = methodCache[mt]
				if not known then known = {}; methodCache[mt] = known end
			end

			local seenKey = {}
			for si = 1, #sources do
				for k0, v0 in pairs(sources[si]) do
					if type(k0) == 'string'
					   and not (k0:byte(1) == 95 and k0:byte(2) == 95)   -- '__'
					   and not seenKey[k0] then
						seenKey[k0] = true
						if not (known and known[k0]) then
							local n = isRoot and proc(k0, v) or k0

							-- ClassName / Caption / AnchorSideLeft etc. sit in the
							-- metatable as descriptor tables. v[k0] runs __index
							-- and yields the actual value. Only tried for
							-- non-scalars, and never for '__' keys.
							local shown, kind = v0, 'Method'
							local tv0 = type(v0)
							if tv0 == 'table' or tv0 == 'userdata' or tv0 == 'function' then
								local okp, got = pcall(rawIndex, v, k0)
								if okp and got ~= nil then
									shown = got
									kind = (type(got) == 'function') and 'Method' or 'Property'
								end
							end

							emit(kind, isRoot and n or (parentPath .. seg(n)), shown)
							if known and kind == 'Method' then known[k0] = true end
						end
					end
				end
			end
		end

		-- 2. Lua table keys.
		if ty == 'table' then
			for k, val in pairs(v) do
				local keyStr = tostring(k)
				local nm2 = isRoot and (vna .. '.' .. keyStr) or keyStr
				local tv = type(val)
				local isObj = (tv == 'userdata' or tv == 'table')
				noteChild(val)
				child(parentPath, nm2, val, isObj and 'Object' or 'Property')
			end
		end

		-- 3. Userdata inspection.
		if ty == 'userdata' then
			-- 3a. Child components.
			local okCount, plc = pcall(callMethod, v, 'getComponentCount')
			if okCount and type(plc) == 'number' then
				for i = 0, plc - 1 do
					local okComp, pli = pcall(callMethod, v, 'getComponent', i)
					if okComp and pli ~= nil then
						local okName, pli_nm = pcall(rawIndex, pli, 'Name')
						local nm2src
						if okName and type(pli_nm) == 'string' and trim_str(pli_nm) ~= '' then
							nm2src = trim_str(pli_nm)
						else
							nm2src = string.format('getComponent(%d)', i)
						end
						local nm2 = isRoot and (vna .. '.' .. nm2src) or nm2src
						noteChild(pli)
						child(parentPath, nm2, pli, 'Component')
					end
				end
			end

			-- 3b. Published properties. Every member access is guarded:
			--     getPropertyList may be absent, and its result may not have
			--     .Count, integer indexing, or .destroy().
			local okPL, propertyList = pcall(getPropertyList, v)
			if okPL and propertyList ~= nil then
				local okC, propCount = pcall(rawIndex, propertyList, 'Count')
				if okC and type(propCount) == 'number' then
					for i = 0, propCount - 1 do
						local okI, pli = pcall(rawIndex, propertyList, i)
						if okI and type(pli) == 'string'
						   and pli ~= 'Parent' and pli ~= 'Owner' then
							local okV, val = pcall(rawIndex, v, pli)
							if not okV then val = nil end
							local nm2 = isRoot and (vna .. '.' .. pli) or pli
							local tv = type(val)
							local isObj = (tv == 'userdata' or tv == 'table')
							noteChild(val)
							child(parentPath, nm2, val, isObj and 'Object' or 'Property')
						end
					end
				end
				-- Reached even when the loop above raised or was skipped.
				pcall(callMethod, propertyList, 'destroy')
			end

			-- 3c. Indexed collections. Skips anything 3a/3b already emitted.
			local okVc, vc = pcall(function() return v.Count or v.count end)
			if okVc and type(vc) == 'number' then
				for i = 0, vc - 1 do
					local okItem, itemVal = pcall(rawIndex, v, i)
					if okItem and itemVal ~= nil and not seenChild[itemVal] then
						noteChild(itemVal)
						local idx = string.format('[%d]', i)
						-- At root level the object prefix must be kept, otherwise
						-- the whole path is just "[0]".
						local nm2 = isRoot and (vna .. idx) or idx
						local tv = type(itemVal)
						local isObj = (tv == 'userdata' or tv == 'table')
						child(parentPath, nm2, itemVal, isObj and 'Object' or 'Value')
					end
				end
			end
		end

		seenChild = nil
	end

	markVisited(rootObj)
	expand(rootObj, nil)

	while nn > 0 do
		local ld, lp, n = nd, np, nn
		nd, np, nn = {}, {}, 0                 -- children found now form the next level
		for i = 1, n do
			local v, p = ld[i], lp[i]
			ld[i], lp[i] = nil, nil            -- release as we go
			expand(v, p)
		end
	end

	if stream then return nrows end
	return rows
end