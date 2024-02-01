function enumModuleSymbols()
	local m=enumModules()
	local m_az={}
	for k,v in pairs(m) do
		local ma=v.Address
		local vn=v.Name
		local vns=getModuleSize(vn)
		local mlb=ma+vns-1
		table.insert(m_az,{ma,mlb,vn})
	end
	local out={}
	for k,v in pairs(getMainSymbolList().getSymbolList()) do
		local md=nil
		
		for k1,v1 in pairs(m_az) do
			if v>=v1[1] and v<=v1[2] then
				md=v1[3]
			end
		end
		
		if md~=nil then --modules only
			table.insert(out,{ Address=v, HexAddress=string.format('%X',v), Name=k, ModuleName=md})
		end
		
	end
	
	table.sort(out, function(a, b) return a.Address < b.Address end)
	
	return out
end

local function table_filter(t,f)
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

local function table_map(t,f) -- Javascript port
	local out={}
	for k,v in pairs(t) do
		local tyk=type(k)
		local vm=f(v,k,t)
		if tyk=='number' then
			table.insert(out,vm)
		else
			 out[k]=vm
		end
	end
	return out
end