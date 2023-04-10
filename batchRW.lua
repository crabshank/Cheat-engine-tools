local timer
local lprog=false;
local timer_attach={['accessed']={}}
local addr_stack=nil
local rets_lookup={}
local modulesList={}
local bps={}

local function isInModule(address,address_hex,name) -- https://github.com/cheat-engine/cheat-engine/issues/205 (mgrinzPlayer)
	for i=1, #modulesList do
	local v=modulesList[i]
		if address>=v.Address and address<=(v.Address+v.Size) then
			return {true,v.Name..'+'..string.format('%X',address-v.Address),v.Name}
		end
	end
	return {false,address_hex}
end

local function reverseHex(h)
	local rht={}
	local sl=string.len(h)
	for i=sl, 1, -2 do
		table.insert(rht,string.sub(h,i-1,i))
	end
	return table.concat(rht,'')
end

local function tableLen(t)
  local count = 0
  for _ in pairs(t) do count = count + 1 end
  return count
end

local function printAddrs()
      local al = getAddressList()
      print('All attachable addresses:')
      for i = 0, al.Count - 1 do
          local mr = al.getMemoryRecord(i)
		  if mr ~= nil and mr.type<11 then --See defines.lua for "<11"
			  local ma=mr.CurrentAddress
			  local mhx=string.format('%X',ma)
			  print('Index: ' .. i ..'\nDescription: ' .. mr.description .. '\nValue: ' .. mr.value .. '\nAddress: ' .. mhx .. '\n')
		 end
     end
end

local function detachAll()
	for i = 1, #bps do
		local b=bps[i]
		debug_removeBreakpoint(b[1])
	end
	bps={}
end

local function do_attach(s,z,onWrite,col,t,alist,alc)
		for i = 1, #bps do
			local b=bps[i]
			debug_removeBreakpoint(b[1])
		end
		bps={}
		if z==nil then
			z=1
		elseif (type(z)~='number') or (z<1) then
			print('Argument "z", if defined, must be >=1')
			return
		end
		local al=alist

		if alist~=nil or al==nil then
			al = getAddressList()
			alc=al.Count
		elseif alc==nil then
			alc=al.Count
		end
		
		local trg=bptAccess		
		if t~=true then
			print('Attached to addresses:')
		end
		local ed=false
		local si=0
		local sic=s
		local errCount=0
		local colr=65535
		local xclc={}
		if col~=nil then
			if type(col)=='table' then
				colr=tonumber(reverseHex(col[1]),16)
				xclc[string.format('%d',colr)]=true
				local colL=#col
				if colL>1 then
					for i = 2, colL do
						xclc[string.format('%d',tonumber(reverseHex(col[i]),16))]=true
					end
				end
			else
				xclc[string.format('%d',reverseHex(col))]=true
			end
		else
			xclc['65535']=true
		end

		while ed==false do
			local mr = al.getMemoryRecord(sic)
				local attThis=true 
				
				local ma,mhx
				if mr~=nil then
					ma=mr.CurrentAddress
					mhx=string.format('%X',ma)
				end
				if (mr == nil) or (t==true and timer_attach.accessed[mhx]~=nil) then
					attThis=false
					errCount=errCount+1
				end
				local scol=string.format('%d',mr.Color)
				 if attThis==true and mr.type<11 and (t~=true or (xclc[scol]==nil and t==true) ) then --See defines.lua for "<11"	
							local md=mr.description
							local tb={ma,mhx,mr,md,sic}
							table.insert(bps,tb)
							if t~=true then
								if md=='' then
									print(mhx .. ' (#' .. sic .. ')')
								else
									print(md .. ' - ' .. mhx .. ' (#' .. sic .. ')')
								end
							end
							si=si+1
				elseif mr~=nil and xclc[scol]==true and t==true then
					timer_attach.accessed[mhx]=ma
					errCount=errCount+1
				else
					errCount=errCount+1
				end
						
				sic=sic+1
				if errCount>=alc-1 and t==true then
					ed=true
				elseif t~=true and ( (sic >=al.Count) or (si==z) ) then
					ed=true
				elseif t==true and si<z and sic >=al.Count then
					sic=0
				elseif t==true and si==z then
					ed=true
				end
		end
		if t~=true or timer_attach.s_mult==1 then
			if t~=true then
				print('')
			end
			if onWrite==true then
				print('Written to addresses:')
			else
				print('Read addresses:')
			end
		end
		
		for i = 1, #bps do
			local b=bps[i]
			debug_setBreakpoint(b[1], 1, trg, bpmInt3, function()
						debug_getContext(true)
						b[3].Color=colr --yellow
						local lst=getPreviousOpcode(RIP)
						local dst = disassemble(lst)
						local extraField, instruction, bytes, address = splitDisassembledString(dst)
						local a = getNameFromAddress(address) or ''
						local pa=''
						local bx=string.format('%X',b[1])
						local lstx=string.format('%X',lst)
						timer_attach.accessed[bx]=b[1]
						if a=='' then
							pa=lstx
						else
							pa=lstx .. ' ( ' .. a .. ' )'
						end
						local prinfo=string.format('%s:\t%s  -  %s }', pa, bytes, instruction)
						if b[4]=='' then
								print(b[2] .. ' (#' .. b[5] .. ')\t{ '..prinfo)
							else
								print(b[4] .. ' - ' .. b[2] .. ' (#' .. b[5] .. ')\t{ '..prinfo)
							end
						debug_removeBreakpoint(b[1])
			end)
		end
end

local function attach(s,z,onWrite,col)
	if timer~=nil then
		timer.destroy()
	end
	do_attach(s,z,onWrite,col)
end

local function end_loop()
	if timer~=nil then
		timer.destroy()
	end
	lprog=false
	print('Address list loop ended!')
	detachAll()
end

local function add(f,t,s,n)
	local fn, tn
	local bse='base'
	local nn=1
	if s~=nil and type(s)=='string' and bse~='' then
		bse=s
	end
	if n~=nil and type(n)=='number' then
		nn=n
	end
	if type(f)=='string' then
		fn=getAddress(f)
	else
		fn=f
	end
	if type(t)=='number' then
		if t<1 then
			print("Argument 't' must be >=1")
			return
		else
			tn=t
		end
	else
		print("Argument 't' must be >=1")
		return
	end
	local al = getAddressList()
	
	for i=fn, fn+tn-1, nn do
		local rec = al.createMemoryRecord()
		rec.setAddress(i)
		local d=i-fn;
		local sgn='+'
		if i<fn then
			sgn='-'
		end
		local hx=string.format('%s%s%X',bse,sgn,d)
		rec.setDescription(hx)
		--rec.ShowAsHex=true
		rec.Type=0
	end
	
end

local function keepCol(c)
		local keepc={}
		if c~=nil then
			if type(c)=='table' then
					for i = 1, #c do
						keepc[string.format('%d',tonumber(reverseHex(c[i]),16))]=true
					end
			else
				keepc[string.format('%d',reverseHex(c))]=true
			end
		else
			keepc['65535']=true
		end

	local al = getAddressList()
	local vt={}
	  for i = 0, al.Count - 1 do
		  local mr = al.getMemoryRecord(i)
		  local scol=string.format('%d',mr.Color)
		  if mr ~= nil and mr.Type<11 and keepc[scol]==nil then --See defines.lua for "<11"
			  table.insert(vt,mr)
		 end
	 end
	  for i = 1, #vt do
		  vt[i].destroy()
	 end
end

local function attach_loop(z,t,onWrite,col)
	timer_attach={['accessed']={}}
	if timer~=nil then
		end_loop()
	end
	timer = createTimer(getMainForm())
	timer.Interval = t
	timer_attach.s_mult=0
	timer_attach.z=z
	timer_attach.onWrite=onWrite
	print('\nLooping through address list...')
	local ot
	ot = function(timer)
		if lprog==false then
			lprog=true
			local al=getAddressList()
			if al~=nil then
				local alc=al.Count
				if alc<=z then
					end_loop()
					print('\nAttached to remaining entries:')
					attach(0,z,onWrite,col)
					return
				end
				local taal=tableLen(timer_attach.accessed)
				if alc-taal<=z then
					end_loop()
					print('\nAttached to remaining entries:')
					attach(0,z,onWrite,col)
				elseif taal<alc then
					local za=timer_attach.z
					local s=timer_attach.s_mult*za
					timer_attach.s_mult=timer_attach.s_mult+1
					local mod_s =math.fmod(s,alc)
					do_attach(mod_s,za,timer_attach.onWrite,col,true,al,alc)
				else
					end_loop()
				end
			end
			lprog=false
		end
	end
	timer.OnTimer=ot
end

local function end_stack()
	if addr_stack~=nil then
		debug_removeBreakpoint(addr_stack)
local t2={}

for key, value in pairs(rets_lookup) do
		table.insert(t2,{['Symbolic address']=value['Symbolic_address'],['Address']=key,['Count']=value['count'],['RSP+… ']=value['RSP+…']})
	end
	
	table.sort( t2, function(a, b) return a['Count'] > b['Count'] end )
		tprint(t2)
	end
end

local function stack(d,b,m)

	if addr_stack~=nil then
		end_stack()
	end

	local tyd=type(d)
	if tyd=='string' then
		addr_stack=getAddress(d)
	elseif tyd=='number' then
		addr_stack=d
	else
		print("Argument 'd' must be a number or string")
	end
	rets_lookup={}
	modulesList={}
	
	local modulesTable= enumModules()
  for i,v in pairs(modulesTable) do
	if v.Name==m or m==nil or m=='' then
		local tm={
			['Size']=getModuleSize(v.Name),
			['Name']=v.Name,
			['Address']=v.Address
		}
		table.insert(modulesList,tm)
	end
  end
	
	debug_setBreakpoint(addr_stack, 1, bptExecute, bpmDebugRegister, function()
		debug_getContext(true)
		local bp=math.max(RBP-7,RSP)
		if b~=nil and b>=0 then
			bp=math.min(RSP+b,bp)
		end
		--local p=1
		local f=0
		local fs='0'
		for i=RSP, bp do
			local d=readQword(i)
			local dx=string.format('%X',d)
			local isRet=isInModule(d,dx,m)
			if isRet[1]==true then
				if rets_lookup[dx]==nil then
					rets_lookup[dx]={}
					rets_lookup[dx]['count']=1
					rets_lookup[dx]['address_dec']=d
					rets_lookup[dx]['Symbolic_address']=isRet[2]
					rets_lookup[dx]['RSP+…']={}
					rets_lookup[dx]['RSP+…'][fs]=1
				else
					rets_lookup[dx]['count']=rets_lookup[dx]['count']+1
					rets_lookup[dx]['RSP+…'][fs]=rets_lookup[dx]['RSP+…'][fs]+1
				end
				--p=p+1
			end
			f=f+1
			fs=tostring(f)
		end
	end)

end

batchRW={
	attach=attach,
	attach_loop=attach_loop,
	end_loop=end_loop,
	printAddrs=printAddrs,
	detachAll=detachAll,
	add=add,
	keepCol=keepCol,
	end_stack=end_stack,
	stack=stack
}