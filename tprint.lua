local function trim_str(s)
	return string.match(s,'^()%s*$') and '' or string.match(s,'^%s*(.*%S)')
end

local function pairsLen(t)
	local c=0
	for key, value in pairs(t) do
		c=c+1
	end
	return c
end

local function get_subtable(t, strt, ed)
  local out = {}

  for i =strt, ed do
    table.insert(out,t[i])
  end

  return out
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

local function userdata_table(v)
			local pltFinal={}

			local plt={}
                        local vn=v.Name
						local vna=vn
						local act_vn_Name=true
                        if type(vn)~='string' or trim_str(vn)=='' then
                           vn='…'
						   vna='(…)'
						   act_vn_Name=false;
						end
			local propertyList=getPropertyList(v)
			if propertyList~=nil then
			local plc=propertyList.Count
			if plc>0 then
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
						       nm=string.format('getPropertyList(%s)[%d]',vna,i)
						       nm2=nm
						end
						table.insert(plt,{path2={nm2}, path={nm}, data=pli,val=val,type='Property'})
					end
			end
			propertyList.destroy()
			end

				if v~=nil and v.getComponentCount~=nil then
			local plc=v.getComponentCount()
				if plc>0 then
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
								 nm=pli_nm
								 nm2=vna..'.'..pli_nm
							else
								nm=string.format('(%s).getComponent(%d)',vn,i)
								nm2=nm
							end

							table.insert(plt,{path2={nm2}, path={nm}, data=pli, val=nil,type='Component'})
					end
				end
				end


				--End of 1st round!
				local cnt=1
				while cnt<=#plt do
					local pi=plt[cnt]
					local v=pi['data']
					local p=deepcopy(pi['path'])
					local p2=deepcopy(pi['path2'])


		local propertyList=getPropertyList(v)
			if propertyList~=nil then
				local plc=propertyList.Count
			if plc>0 then
					for i=0, plc-1 do
						local pli=propertyList[i]
						local val=getProperty(v,pli)
						if type(val)=='userdata' then
							val=nil
						end
						local typ=type(pli)
						  local pli_nm=pli.Name
						local nm=''
						if typ=='string' and trim_str(pli)~='' then
							nm=pli
						elseif type(pli_nm)=='string' and trim_str(pli_nm)~='' then
							nm=pli_nm
						else
							nm=string.format('getPropertyList(%s)[%d]',vn,i)
						end
						local np=deepcopy(p)
						table.insert(np,nm)
						local np2=deepcopy(p2)
						table.insert(np2,nm)
						table.insert(plt,{path2=np2,path=np, data=pli,val=val, type='Property'})
					end
			end
			propertyList.destroy()
			end

				if v~=nil and v.getComponentCount~=nil then
			local plc=v.getComponentCount()
				if plc>0 then
					for i=0, plc-1 do
							local pli=v.getComponent(i)
							local typ=type(pli)
							local pli_nm=pli.Name
							local nm=''
							if typ=='string' and trim_str(pli)~='' then
								nm=pli
							elseif type(pli_nm)=='string' and trim_str(pli_nm)~='' then
								 nm=pli.Name
							else
								nm=string.format('getComponent(%d)',i)
							end
						local np=deepcopy(p)
						table.insert(np,nm)
						local np2=deepcopy(p2)
						table.insert(np2,nm)
						table.insert(plt,{path2=np2,path=np, data=pli,  val=nil, type='Component'})
					end
				end
				end
					cnt=cnt+1
				end
				
				for i=1, #plt do
					local pi=plt[i]
					--local d=pi['data']
					local v=pi['val']
					local p=pi['path']
					local p2=pi['path2']

					local runEl=pltFinal
					local lp=#p
					for j=1, lp do
						local pj=p[j]
						if runEl[pj]==nil then
							if j==lp then
								runEl[pj]={type=pi['type'], path=table.concat(p2,'.')}
								if v~=nil then
									runEl[pj].value=v
								end
							else
								runEl[pj]={}
							end
						end
						runEl=runEl[pj]
					end
					
				end
				local pltRet=pltFinal
				if act_vn_Name==true then
					local out={}
					out[vn]=pltFinal
					return out
				else
					return pltFinal
				end
end

function tprint(tbl, indent)

	local function actualPrint(k,v,indent,notTable,do_tprint,zero)
		local formatting=''
			
		if notTable~=true or zero==true then
			formatting = string.rep("	", indent) .. k .. ": "
		 end
		  local typv=type(v)
		  if typv == "table" then
			local ln=pairsLen(v)
			if ln<1 then
				print(formatting..'{}')
			else
				print(formatting)
				do_tprint(v, indent+1)
			end
		  elseif typv == 'userdata' then
			print(formatting)
			do_tprint(userdata_table(v),indent+1)
		  elseif typv == 'boolean' then
			print(formatting .. tostring(v))
		  elseif typv == 'string' then
			local la, lb=string.find(v, "\n")
			if la==nil then
				print(formatting .. '"'.. v ..'"')
			else
				print(formatting .. '[['.. v ..']]')
			end
		  elseif typv == 'function' then
			print(formatting .. 'function () … end')
		  else
			print(formatting .. tostring(v))
		  end
	end

  local function do_tprint(tbl, indent,notTable) -- https://gist.github.com/ripter/4270799
	if notTable==true then
		tbl={tbl}
		indent = 0
	else
		if not indent then indent = 0 end
	end
	if tbl[0]~=nil then
		local nt=false
		if type(tbl[0])~=table then
			nt=true
		end
		actualPrint(0,tbl[0],indent,nt,do_tprint,true)
	end
	for k, v in pairs(tbl) do
		if k~=0 then
			actualPrint(k,v,indent,notTable,do_tprint)
		end
	end
  end

  local notTable=false
  local tyb=type(tbl)
  if tyb~='table' then
	notTable=true
  end

  do_tprint(tbl,indent,notTable)
  print('\n')
end
