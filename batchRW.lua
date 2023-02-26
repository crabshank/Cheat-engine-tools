local timer
local timer_attach={['accessed']={}}

local bps={}

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

local function do_attach(s,z,onWrite,t,alist)
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
		if alist~=nil then
			al = getAddressList()
		end
		local trg=bptAccess		
		if t~=true then
			print('Attached to addresses:')
		end
		local ed=false
		local si=0
		local sic=s
		local errCount=0
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
				end
				 if attThis==true and mr.type<11 then --See defines.lua for "<11"	
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
				else
					errCount=errCount+1
				end
						
				sic=sic+1
				if errCount==z and t==true then
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
						b[3].Color=65535 --yellow
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

local function attach(s,z,onWrite)
	timer.destroy()
	do_attach(s,z,onWrite)
end

local function end_loop()
	timer.destroy()
	print('Address list loop ended!')
	detachAll()
end

local function attach_loop(z,t,onWrite)
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
	timer.OnTimer = function(timer)
		local al=getAddressList()
		if al~=nil then
			local alc=al.Count
			if #timer_attach.accessed<alc then
				local al=getAddressList()
				local alc=al.Count
				local za=timer_attach.z
				local s=timer_attach.s_mult*za
				timer_attach.s_mult=timer_attach.s_mult+1
				local mod_s =math.fmod(s,alc)
				do_attach(mod_s,za,timer_attach.onWrite,true,al)
			else
				end_loop()
			end
		end
	end
end

batchRW={
	attach=attach,
	attach_loop=attach_loop,
	end_loop=end_loop,
	printAddrs=printAddrs,
	detachAll=detachAll
}