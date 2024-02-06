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

function full_internal(v)

	local proc=function(k,v,p,vna)
			local n2
			fp=function() return p[k] end
			fpb, fpr=pcall(fp)
			if fpr==nil then
				n2='(…):'..k..'(…)'
			else
				 n2=vna..'.'..k..'(…)'
			end
			return n2
	end
	local plt={}
	local pltFinal={}
	local out={}
	local mt, cb,cr,gmtb,plw,vc,tyv,ptyp,getCond
	local vn=v.Name
	local vna=vn
	local act_vn_Name=true
	local vnf=load("return ".. vn)
	local vnb,vnr=pcall(vnf)
	if vnr==nil then
		vn='…'
	   vna='(…)'
	   act_vn_Name=false;
	end
	local w=0
	local p2={}

		while true do --FULL DEPTH LOOP!
		if w>0 then
			plw=function() return plt[w] end
			cb,cr =pcall(plw)

			if cr==nil then
				break
			else
				v=cr['data']
                ptyp=cr['type']
				p2=deepcopy(cr['path2'])
			end

		end
		getCond=false
		if ptyp=='Component' or ptyp==nil then
			getCond=true
		end
        tyv=type(v)
		if tyv~='function' then
			gmtb=function() return getmetatable(v) end
			cb,mt =pcall(gmtb)

			if type(mt)=='table' then
				local n
				for k0, v0 in pairs(mt) do
					if string.sub(k0,1,2)~="__" then
						if w>0 then 
							n=k0
						else
							n=proc(k0,v0,v,vna)
						end
						local np2=deepcopy(p2)
						table.insert(np2,n)
						table.insert(plt,{path2=np2, data=v0,  val=v0, type='Method'})
					end
				end
			end
		end

		local getComponents=function(v)
						local plc=v.getComponentCount()
					for i=0, plc-1 do
							local pli=v.getComponent(i)
							local typ=type(pli)
							local pli_nm=pli.Name
							local nm=''
														local nm2=''
							if typ=='string' and trim_str(pli)~='' then
								nm=pli
																nm2=vna..'.'..pli
							elseif type(pli_nm)=='string' and trim_str(pli_nm)~='' then
								 nm=pli.Name
																 nm2=vna..'.'..pli_nm
							else
								nm=string.format('getComponent(%d)',i)
																nm2=nm
							end
						if w>0 then nm2=nm end
						local np2=deepcopy(p2)
						table.insert(np2,nm2)
						table.insert(plt,{path2=np2, data=pli,  val=nil, type='Component'})
					end
			end
		        if getCond==true then getComponents(v) end

			local getProperties=function(v)
				  local propertyList=getPropertyList(v)
				local plc=propertyList.Count
						for i=0, plc-1 do
							local pli=propertyList[i]
							local val=getProperty(v,pli)
							if type(val)=='userdata' then
								val=nil
							end
							local typ=type(pli)
							  local pli_nm=pli.Name
							local nm=''
														local nm2=''
							if typ=='string' and trim_str(pli)~='' then
								nm=pli
																nm2=vna..'.'..pli
							elseif type(pli_nm)=='string' and trim_str(pli_nm)~='' then
								nm=pli_nm
																nm2=vna..'.'..pli_nm
							else
								nm=string.format('getPropertyList(%s)[%d]',vn,i)
																nm2=nm
														end

							local np2=deepcopy(p2)
							if w>0 then nm2=nm end
							table.insert(np2,nm2)
							table.insert(plt,{path2=np2, data=pli,val=val, type='Property'})
						end
				propertyList.destroy()
		end
                  if getCond==true then getProperties(v) end
		w=w+1
	end

	for i=1, #plt do
			local pi=plt[i]
			--local d=pi['data']
			local vp=pi['val']
			local p2=pi['path2']

			for y=2,#p2 do
				local py=p2[y]
				local sf1, sf2=string.find(py,'[%s%.\'\"]+')
				if sf1==nil then
					p2[y]="."..py
				else
					local sf3, sf4=string.find(py,'"')
					local smk='"'
					if sf3~=nil then
						smk="'"
						py=string.gsub(py, "'", "\\'")
					else
						py=string.gsub(py, '"', '\\"')
					end
					p2[y]='['..smk..py..smk..']'
				end
			end
                        local pj=table.concat(p2,'')
						local ptj={type=pi['type'], path=table.concat(p2,'')}
                        if vp~=nil then ptj.value=vp end
						table.insert(pltFinal,ptj)
		end

				vc=nil
				if type(v.Count)=='number' then
					vc=v.Count
				elseif type(v.count)=='number' then
					vc=v.count
				end

				if vc~=nil then
				   for i=0, vc-1 do
					   table.insert(pltFinal,{value=vp[i], type='Value', path=i})
				   end
				end

				return pltFinal
end
