local ress={}
local ress_comp={['rsl']=0,['res']={},['filt']={}}
local boundedResParams={-1,0,false}
local boundedRes={}
local jmpList={}
local narrow_err=true

local function tprint(tbl, indent)
  local function do_tprint(tbl, indent) -- https://gist.github.com/ripter/4270799
	if not indent then indent = 0 end
	for k, v in pairs(tbl) do
	  formatting = string.rep("	", indent) .. k .. ": "
	  local typv=type(v)
	  if typv == "table" then
		print(formatting)
		do_tprint(v, indent+1)
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
  end
  do_tprint(tbl,indent)
  print('\n')
end

local function resetAllResults()
	ress={}
	boundedResParams={-1,0,false}
	boundedRes={}
	narrow_err=true
end

local function addMemScan()
		local ms=getCurrentMemscan()
		local fl=ms.FoundList
		table.insert(ress,{})
		local currRes=#ress
		local base = ms.isHexadecimal and 16 or nil
		local len_fl=fl.Count
		for i = 0, len_fl-1 do
			local addr=fl.getAddress(i)
			local val=fl.getValue(i)
			local addrConv=tonumber(addr,16)
			ress[currRes][i+1]={Address=addr, Value=val, addressConv=addrConv, ix=i+1}
		end

	table.sort( ress[currRes], function(a, b) return a.addressConv < b.addressConv end ) -- Converted results array now sorted by address (ascending); "ix" all jumbled
	print('Set of results #'..currRes .. ' added!')
end

local function removeResult(i) --Remove i-th element from results table
	table.remove(ress,i)
	narrow_err=true
end

local function printFiltered(m,n)		
	if #boundedRes>=1 then
		local brl=#boundedRes
		local ags=2
		if m==nil then
		   ags=0
		elseif n==nil then
		   ags=1
		end
		
		local cnt=1;
		jmpList={}
		local lns={}
		for i = brl, 1, -1 do --iterate over boundedRes
			local t = {}
			local bri=boundedRes[i]
			local d=bri.data
			local r=bri.range
			local dle=#d
			if (ags==0) or (ags==1 and r<=m) or (ags==2 and r>=m and r<=n) then
					local mn=d[1].addressConv;
					t[1]=d[1].Address .. ' (' .. d[1].Value .. ')'
					cnt=cnt+1
					if dle >= 2 then
						for k = 2, dle do --iterate over boundedRes.data
							if d[k].addressConv<mn then
								mn=d[k].addressConv
							end
							t[k]= ' || ' .. d[k].Address .. ' (' .. d[k].Value .. ')'
						end
						t[dle+1]=' 〈Range: ' .. boundedRes[i].range .. ' bytes〉'
					end
					
					local a = table.concat(t)
					table.insert(lns,a)
					table.insert(jmpList,mn)
			end
		end
		local l_lns=#lns
		for i=1, l_lns do
			print('#'..(l_lns-i+1)..':   '..lns[i])
		end
	else
		print('No matching results')
	end
end

local function sortBoundedRes()
	table.sort( boundedRes, function(a, b)
		return a.range < b.range 
	end)
end

local function filterByRange(n)
   local brt={}
   local brl=#boundedRes
   for i=1, brl do
      local bri=boundedRes[i]
      if bri.range<=n then
         table.insert(brt,boundedRes[i])
      else
         i=brl --Early terminate, as sorted by range
      end
   end
end

local function narrowDown(n) --m is the same as the first round, unless argument specified
	local alrdyProc=boundedResParams[2]
	local rl=#ress
	if rl <= alrdyProc then
		print("Must have more results than already processed")
		return
	end
	if narrow_err==true then
		print("Do a full scan!")
		return
	end
	
	local m=boundedResParams[1]
	local unlim=boundedResParams[3]
	if n~=nil then
   if (unlim==false) and (n>=m) then
	      print('Argument must be <'..m)
	      return
	   end
	   if (n < #ress-1) then
		print("Argument must be >= number of results compared (>=" .. (#ress-1) .. ")")
	     return
   	end
	      unlim=false
	      m=n
	      filterByRange(n)
	end
	
	boundedResParams={m, rl,unlim}
	local bndOut={}
	
			for i=alrdyProc+1, rl do --process ones not already done
				local cir = ress[i]
				for j=1, #cir do
					for k=1, #boundedRes do
						local cj,bk=cir[j],boundedRes[k]
						local mn,mx,cjac,ib,ob=bk.min,bk.max,cj.addressConv,false,false
						local new_min=bk.max-m
						local new_max=bk.min+m
						if cjac>=bk.min and cjac<=bk.max then
							ib=true
						end
						if ib==false then
							if cjac<bk.min and (cjac>=new_min or unlim==true) then
								mn=cjac
								ob=true
							else if cjac>bk.max and (cjac<=new_max or unlim==true) then
								mx=cjac
								ob=true
							end
						end
					if ib==true or ob==true then
						local nd=bk.data
						table.insert(nd,cj)
						local rnge=mx-mn
						local nb ={min=mn, max=mx, range=rnge, data=nd}
						table.insert(bndOut,nb)
					end
					if (cjac > bk.max+m) and (unlim==false) then
						k=#boundedRes --EARLY TERMINATE
					end
				end
			end
		end
	end
		boundedRes=bndOut
		sortBoundedRes()
		printFiltered()
end

local function firstScan(m,narrowDwn,unlim)
	local rl=#ress
	if (m < 1 or m==nil) and (unlim==false) then
		print("Argument must be a positive integer >=1")
		return
	end
	if (m < rl-1) and (unlim==false) then
		print("Argument must be >= number of results compared (>=" .. (rl1) .. ")")
		return
	end
	if boundedResParams[1]==m and boundedResParams[2]==rl and boundedResParams[3]==unlim then
		print("Already printed results!")
		return
	end
	if rl < 2 then
		print("Must have added at least 2 memscan results!")
		return
	end
	if narrow_err==true then
		narrow_err=false
	end
	
	boundedResParams={m,2,unlim}
	tempBndRes={}
	
	table.sort( ress, function(a, b) return #a < #b end ) --sort ress asc. order of their lengths
	
	local firstResEl=ress[1]
	
	--First round
	for i=1, #firstResEl do --each result from this list
		local ci=firstResEl[i]
		local currResEl=ress[2]
		for j=1, #currResEl do --each result from this list
					local cj=currResEl[j]
					local cad={ci.addressConv, cj.addressConv}
					local df=cad[2]-cad[1]
					local mn,mx=cad[1],cad[2]
					local dfa=math.abs(df)

					if (dfa<=m) or (unlim==true) then
						if cad[1]>cad[2] then
									mn=cad[2]
									mx=cad[1]
						end
							local b={min=mn, max=mx, range=dfa,data={ci,cj}}
							table.insert(tempBndRes,b)
						else if (df>m) and (unlim==false) then
							j=#currResEl
						end
					end

		end
	end
	boundedRes=tempBndRes
-- End of first round
	if narrowDwn==true then
		narrowDown()
	end
end

local function fullScan(m) -- m is limit (Absolute value)
	local b=true
	local unlim=false
	if #ress==2 then b=false end
	if m==nil then
		m=0
		unlim=true
	end
	firstScan(m,b,unlim)
	if b==false then -- if no narrow down
		sortBoundedRes()
		printFiltered()
	end
end

local function tbl_pair_len(t)
	local c=0
	for k,v in pairs(t) do -- iterate over addresses (k) || v is the table for the address
		c=c+1
	end
	return c
end

local function tbl_include(t,n,l)
	local g=l
	if l==nil then 
		g=#t
	end
	for i=1, g do
		if t[i]==n then
			return i
		end
	end
	return nil
end

local function compare(t,r)
	-- e.g. t={{1,1},{2,0}}
	local rsl=#ress
	if rsl<2 then
		print('There must be at least 2 sets of scan results added!')
		return
	end
	local tb={}
	if type(t[1])=='table' and type(t[1][1])=='table' then
		tb=t
	else
		table.insert(tb,t)
	end
	
	if tbl_pair_len(ress_comp['res'])==0 or ress_comp['rsl']~=rsl then
		r=true
	end
	
	if r==true and rsl>1 then
		ress_comp={['rsl']=rsl,['res']={},['filt']={}}
		for i=1, rsl do --each result from this list
		local currResEl=ress[i]
		local crl=#currResEl
		if crl>0 then
				for j=1, crl do --each result from this list
							local cj=currResEl[j]
							local cja=cj.Address
							if ress_comp['res'][cja]==nil then -- table of which addresses appear in which set of results
								ress_comp['res'][cja]={i}
							else
								table.insert(ress_comp['res'][cja],i)
							end
				end
			end
		end
	else
		ress_comp['filt']={}
	end
	
	for i=1, #tb do
		local ti=tb[i]
		local n=ti[1]
		local b=ti[2] -- 0/1/2/3 ->? false/true/exclusively in/exclusively not in

		for k,v in pairs(ress_comp['res']) do -- iterate over addresses (k) || v is the table for the address
			local lv=#v
			local tinc=tbl_include(v,n,lv)
			if (tinc==nil and b==0) or (tinc~=nil and b==1) or (tinc~=nil and lv==1 and b==2) or (tinc==nil and lv==(rsl-1) and b==3) then
				local tf={}
				tf.Address=k
				tf.sets=table.concat(v,', ')
				table.insert(ress_comp['filt'],tf)
			end
		end
		tprint(ress_comp['filt'])
	end
end

local function jump(i)
	local k=#jmpList-i+1
	if jmpList[k]~=nil then
		getMemoryViewForm().HexadecimalView.Address=jmpList[k]
	end
end

proxValues={
	resetAllResults=resetAllResults,
	addMemScan=addMemScan,
	compare=compare,
	removeResult=removeResult,
	printFiltered=printFiltered,
	narrowDown=narrowDown,
	fullScan=fullScan,
	jump=jump
}
