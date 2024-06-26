local function bubbleSort(a, asc) -- for descending order, asc=false
  local n=#a
  local swapped = false
  if asc~=false then
	  repeat
			swapped = false
			for i=2, n do
			  if a[i-1] > a[i] then
				a[i-1],a[i] = a[i],a[i-1]
				swapped = true
			  end
			end
	  until (swapped==false)
  else
		repeat
			swapped = false
			for i=2, n do
			  if a[i-1] < a[i] then
				a[i-1],a[i] = a[i],a[i-1]
				swapped = true
			  end
			end
	  until (swapped==false)
  end
end

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
			else
				 n=k..'(…)'
				 n2=vna..'.'..n
			end
			return {n,n2}
	end
	local plt={}
	local pltFinal={}
	local out={}
	local mt,gmtb,vc --,cb,cr,plw

	local vn,vna,act_vn_Name='','',false

	local vnf=load("return ".. vn)
	local vnb,vnr=pcall(vnf)
	if vnr==nil then
		vn='…'
	   vna='(…)'
	   act_vn_Name=false;
	else
		vn=v.Name
		vna=vn
		act_vn_Name=true
	end
	--local w=0
	local p={}
	local p2={}

		--[[while true do --FULL DEPTH LOOP!
		if w>0 then
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
						local np=deepcopy(p)
						table.insert(np,nm)
								--[[if w>0 then nm2=nm end]]
						local np2=deepcopy(p2)
						table.insert(np2,nm2)
						table.insert(plt,{path2=np2,path=np, data=pli,  val=nil, type='Component'})
					end
			end
		local mtv=function() return getComponents(v) end
		local mtvb,mtvr=pcall(mtv)

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

							local np=deepcopy(p)
							table.insert(np,nm)
							local np2=deepcopy(p2)
									--[[if w>0 then nm2=nm end]]
							table.insert(np2,nm2)
							table.insert(plt,{path2=np2,path=np, data=pli,val=val, type='Property'})
						end
				propertyList.destroy()
		end

		mtv=function() return getProperties(v) end
		mtvb,mtvr=pcall(mtv)
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

				local fnd=false
				local gcnt=function() return type(v.Count) end
				local gcntb,gcntr=pcall(mtv)
				if gcntb==true then
					if tycn=='number' then
						vc=v.Count
						fnd=true
					elseif type(v.Count.__get)=='function' and type(v.Count.__get())=='number'  then
						vc=v.Count.__get()
						fnd=true
					end
				end

				if fnd==false then
				gcnt=function() return type(v.count) end
				gcntb,gcntr=pcall(mtv)
				if gcntb==true then
						if tycn=='number' then
							vc=v.count
							fnd=true
						elseif type(v.count.__get)=='function' and type(v.count.__get())=='number'  then
							vc=v.count.__get()
							fnd=true
						end
					end
				end


				if fnd==true then
				   for i=0, vc-1 do
					   pltFinal[i]=v[i]
				   end
				end
				if type(v)=='table' then
					for key, value in pairs(v) do
						 pltFinal[key]=value
					end
				end

				--[[if act_vn_Name==true then
					local out={}
					out[vn]=pltFinal
					return out
				else]]
					if pairsLen(pltFinal)>0 then
						return pltFinal
					else
						return nil
					end
				--end
end

local function actualPrint(v,formatting,indent,do_tprint,typv)
	  if typv == "table" then
		if pairsLen(v)==0 then
			return formatting..'{}'
		else
			return formatting
		end
	  elseif typv == 'boolean' then
		return formatting .. tostring(v)
	  elseif typv == 'string' then
		local la, lb=string.find(v, "\n")
		if la==nil then
			return formatting .. '"'.. v ..'"'
		else
			return formatting .. '[['.. v ..']]'
		end
	  elseif typv == 'function' then
		return formatting .. 'function () … end'
	  else
		return formatting .. tostring(v)
	  end
end

function tprint(tbl)
  local function do_tprint(tbl, indent,notTable,supressMeta) -- https://gist.github.com/ripter/4270799
        local formatting=''
        local mtv,mtvb,mtvr,typv,fOnce,initVal,kys3l
        local kys={{},{},{}}
        if notTable~=true then


		if tbl[0]~=nil then table.insert(kys[1],0) end
		for k, v in pairs(tbl) do
			if k~=0 then
				if type(k)=='number' then
					table.insert(kys[1],k)
				else
					table.insert(kys[2],k)
				end
			end
		end

		bubbleSort(kys[1])
		for j=1,#kys[1] do
			table.insert(kys[3],kys[1][j])
		end
		for j=1,#kys[2] do
			table.insert(kys[3],kys[2][j])
		end
else
                initVal=true
                for j=1,#tbl do
			table.insert(kys[3],j)
		end
end
		
		kys3l=#kys[3]
		if kys3l==0 and notTable~=true then
			 print(actualPrint(tbl,'',indent,do_tprint,'table'))
			 return
		end
		for j=1,kys3l do
			local k=kys[3][j]
			local v=tbl[k]
			typv=type(v)
			if notTable~=true then
		  formatting = string.rep("	", indent) .. k
			else
                        formatting = string.rep("	", indent) .. actualPrint(v,'',indent,do_tprint,typv)

                         end
			if supressMeta~=true and notTable==true then
				mtv=function() return getmetatable_formatted(v) end
				mtvb,mtvr=pcall(mtv)
				if mtvb==true and type(mtvr)=='table' then
					 print(actualPrint(mtvr,formatting,indent,do_tprint,type(mtvr))..': ')
                                          do_tprint(mtvr, indent+1,nil,true)
                                          fOnce=true

				  end
                        end

               if typv == "table" then
                             if fOnce~=true then
                              print(formatting .. ": ")
                              do_tprint(v, indent+1,nil,true)
                             end
		         elseif initVal~=true then
                   print(actualPrint(v,formatting .. ": ",indent,do_tprint,typv))
                 elseif mtvr==nil then
                   print(actualPrint(v,'',indent,do_tprint,typv))
                 end
	  end
  end
  local nt=false
  if type(tbl)~='table' then
     tbl={tbl}
     nt=true
  else

  end
  do_tprint(tbl,0,nt)
  print('\n')
end