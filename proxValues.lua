local ress={}
local boundedRes={{-1,0}}
local narrow_err=true

local function resetAllResults()
	ress={}
	boundedRes={{-1,0}}
	narrow_err=true
end

local function addMemScan()
		local ms=getCurrentMemscan()
		--table.insert(mss,ms)

		local fl=ms.FoundList
		--table.insert(fls,fl)

		table.insert(ress,{})
		local currRes=#ress
		local base = ms.isHexadecimal and 16 or nil
		local len_fl=fl.Count
		for i = 0, len_fl-1 do
			local addr=fl.getAddress(i)
			local val=fl.getValue(i)
			local addrConv=tonumber(addr,16)
			--local valConv= tonumber(val,base)
			--ress[currRes][i+1]={Address=addr, Value=val, addressConv=addrConv, valueConv=valConv, ix=i+1}
			ress[currRes][i+1]={Address=addr, Value=val, addressConv=addrConv, ix=i+1}
		end

	table.sort( ress[currRes], function(a, b) return a.addressConv < b.addressConv end ) -- Converted results array now sorted by address (ascending); "ix" all jumbled
	print('Set of results #'..currRes .. ' added!')
end

local function removeResult(i) --Remove i-th element from results table
	table.remove(ress,i)
	narrow_err=true
end

local function printFiltered()
	if #boundedRes>=2 then
		local brl=#boundedRes
		print( brl-1 .. ' matching results (within ' .. boundedRes[1][1] .. ' bytes): ')
		for i = 2, brl do --iterate over boundedRes
			local t = {}
			local d=boundedRes[i].data
			local dle=#d
			t[1]=d[1].Address .. ' (' .. d[1].Value .. ')'
			if dle >= 2 then
				for k = 2, dle do --iterate over boundedRes.data
					t[k]= ' || ' .. d[k].Address .. ' (' .. d[k].Value .. ')'
				end
			end

			local a = table.concat(t)
			print(a)
		end
	else
		print('No matching results')
	end
end

local function narrowDown() --m is the same as the first Round
	local alrdyProc=boundedRes[1][2]
	local rl=#ress
	if rl <= alrdyProc then
		print("Must have more results than already processed")
		return
	end
	if narrow_err==true then
		print("Do a full scan!")
		return
	end
	local m=boundedRes[1][1]
	local bndOut={{m, rl}}
	
			for i=alrdyProc+1, rl do --process ones not already done
				local cir = ress[i]
				for j=1, #cir do
					for k=2, #boundedRes do
						local cj,bk=cir[j],boundedRes[k]
						local mn,mx,cjac,ib,ob=bk.min,bk.max,cj.addressConv,false,false
						local new_min=bk.max-m
						local new_max=bk.min+m
						if cjac>=bk.min and cjac<=bk.max then
							ib=true
						end
						if ib==false then
							if cjac<bk.min and cjac>=new_min then
								mn=cjac
								ob=true
							else if cjac>bk.max and cjac<=new_max then
								mx=cjac
								ob=true
							end
						end
					if ib==true or ob==true then
						local nd=bk.data
						table.insert(nd,cj)
						local nb ={min=mn, max=mx, data=nd}
						table.insert(bndOut,nb)
					end
					if cjac > bk.max+m then
						k=#boundedRes --EARLY TERMINATE
					end
				end
			end
		end
	end
		boundedRes=bndOut
		 printFiltered()
end

local function firstScan(m,narrowDwn)

	if m < 0 or m==nil then
		print("Argument must be a positive integer")
		return
	end
	if m < #ress-1 then
		print("Argument must be >= number of results compared")
		return
	end
	if boundedRes[1][1]==m and boundedRes[1][2]==#ress then
		print("Already printed results!")
		return
	end
	if #ress < 2 then
		print("Must have added at least 2 memscan results!")
		return
	end
	if narrow_err==true then
		narrow_err=false
	end
	
	local tempBndRes={{m,2}}
	
	table.sort( ress, function(a, b) return #a < #b end ) --sort ress asc. order
	
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

					if dfa<=m then
						if cad[1]>cad[2] then
									mn=cad[2]
									mx=cad[1]
						end
							local b={min=mn, max=mx,data={ci,cj}}
							table.insert(tempBndRes,b)
						else if df>m then
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
	if #ress==2 then b=false end
	firstScan(m,b)
	if b==false then
		printFiltered()
	end
end

proxValues={
	resetAllResults=resetAllResults,
	addMemScan=addMemScan,
	removeResult=removeResult,
	printFiltered=printFiltered,
	narrowDown=narrowDown,
	fullScan=fullScan
}
