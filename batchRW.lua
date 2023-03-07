local timer
local lprog=false;
local timer_attach={['accessed']={}}

local bps={}

function tableLen(t)
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
		if col~=nil then
			colr=tonumber(col,16)
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
				 if attThis==true and mr.type<11 and (t~=true or (mr.Color~=colr and t==true) ) then --See defines.lua for "<11"	
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
				elseif mr~=nil and mr.Color==colr and t==true then
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
						b[3].Color=colr --yellow
						local lst=getPreviousOpcode(RIP)
						local dst = disassemble(lst)
						local extraField, opcode, bytes, address = splitDisassembledString(dst)
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
						local prinfo=string.format('%s:\t%s  -  %s }', pa, bytes, opcode)
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
		local hx=string.format('bse%s%X',sgn,d)
		rec.setDescription(hx)
		rec.ShowAsHex=true
		rec.Type=0
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

batchRW={
	attach=attach,
	attach_loop=attach_loop,
	end_loop=end_loop,
	printAddrs=printAddrs,
	detachAll=detachAll,
	add=add
}