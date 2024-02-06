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

local function getmetatable_formatted(v)

	local proc=function(k,v,p,vna)
			local n,n2
			fp=function() return p[k] end
			fpb, fpr=pcall(fp)
			if fpr==nil then
				n='(…):'..k..'(…)'
				n2=n
				 n=k..'(…)'
				 n2=vna..'.'..n
			end
			return {n,n2}
	end
	local plt={}
	local pltFinal={}
	local out={}
	local mt, cb,cr,gmtb,plw,vc
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
	--local w=0
	local p={}
	local p2={}

		--[[while true do --FULL DEPTH LOOP!
		if w>0 then
			break
			plw=function() return plt[w] end
			cb,cr =pcall(plw)
			if cr==nil then
				break
			else
				v=cr['data']
				p=deepcopy(cr['path'])
				p2=deepcopy(cr['path2'])
			end
		end]]

		--if type(v)~='function' --[[and w==0]] then
			gmtb=function() return getmetatable(v) end
			cb,mt =pcall(gmtb)

			if type(mt)=='table' then
				local n
				for k0, v0 in pairs(mt) do
					--if string.sub(k0,1,2)~="__" then
						n=proc(k0,v0,v,vna)
						local np=deepcopy(p)
						table.insert(np,n[1])
						local np2=deepcopy(p2)
						table.insert(np2,n[2])
						table.insert(plt,{path2=np2,path=np, data=v0,  val=v0, type='Method'})
					--end
				end
			end
		--end

		local getComponents=function()
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
						local np=deepcopy(p)
						table.insert(np,nm)
								--[[if w>0 then nm2=nm end]]
						local np2=deepcopy(p2)
						table.insert(np2,nm2)
						table.insert(plt,{path2=np2,path=np, data=pli,  val=nil, type='Component'})
					end
			end
		cb,cr =pcall(getComponents)

			local getProperties=function()
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

							local np=deepcopy(p)
							table.insert(np,nm)
							local np2=deepcopy(p2)
									--[[if w>0 then nm2=nm end]]
							table.insert(np2,nm2)
							table.insert(plt,{path2=np2,path=np, data=pli,val=val, type='Property'})
						end
				propertyList.destroy()
		end
		cb,cr =pcall(getProperties)
		--w=w+1
	--end

	for i=1, #plt do
			local pi=plt[i]
			--local d=pi['data']
			local v=pi['val']
			local p=pi['path']
			local p2=pi['path2']

			local lp=#p
			for j=1, lp do
				local pj=p[j]
				if pltFinal[pj]==nil then
					if j==lp then
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
						pltFinal[pj]={type=pi['type'], path=table.concat(p2,'')}
						if v~=nil then
							pltFinal[pj].value=v
						end
					else
						pltFinal[pj]={}
					end
				end
			end
			end

									vc=nil
				if type(v.Count)=='number' then
					vc=v.Count
				elseif type(v.count)=='number' then
					vc=v.count
				end

				if vc~=nil then
				   for i=0, vc-1 do
					   pltFinal[i]=v[i]
				   end
				end

				--[[if act_vn_Name==true then
					local out={}
					out[vn]=pltFinal
					return out
				else]]
					return pltFinal
				--end
end

function tprint(tbl, indent)

	local function actualPrint(k,v,indent,notTable,do_tprint,zero,suppressMeta)
		local formatting=''
		local mtv
		if notTable~=true or zero==true then
			formatting = string.rep("	", indent) .. k .. ": "
		 end
		 local spm=nil
		 if suppressMeta~=true then
			local mtv=function() return getmetatable_formatted(v) end
			local mtvb,mtvr=pcall(mtv)
			if mtvb==true and type(mtvr)=='table' then
				local vs=tostring(v)
				local vnm= v.Name
						local vnf=load("return "..vnm)
						local vnb,vnr=pcall(vnf) 
				if vnr~=nil then vs=vnm end
				print(string.rep("	", indent) .. vs..':')
				v=mtvr
				spm=true
			end
		end
		  local typv=type(v)
		  if v == nil then
			print(formatting..'nil')
		  elseif typv == "table" then
			local ln=pairsLen(v)
			if ln<1 then
				print(formatting..'{}')
			else
				if spm~=true then
				   print(formatting)
				end
				do_tprint(v, indent+1,nil,true)
			end
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
			print(formatting .. 'function (…) … end')
		  else
			print(formatting .. tostring(v))
		  end

	end

	  local function do_tprint(tbl, indent,notTable,suppressMeta) -- https://gist.github.com/ripter/4270799
		if tbl==nil then
			actualPrint(nil,nil,indent,true,do_tprint,nil,suppressMeta)
			return
		elseif notTable==true then
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
			actualPrint(0,tbl[0],indent,nt,do_tprint,true,suppressMeta)
		end
		for k, v in pairs(tbl) do
			if k~=0 then
				actualPrint(k,v,indent,notTable,do_tprint,nil,suppressMeta)
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