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

local function attach(s,z,onWrite)
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
		local al = getAddressList()
		local trg=bptAccess		
		print('Attached to addresses:')
		local ed=false
		local si=0
		local sic=s
		while ed==false do
			local mr = al.getMemoryRecord(sic)
				 if mr ~= nil and mr.type<11 then --See defines.lua for "<11"
							local ma=mr.CurrentAddress
							local mhx=string.format('%X',ma)
							local md=mr.description
							local t={ma,mhx,mr,md,sic}
							table.insert(bps,t)
							if md=='' then
								print(mhx .. ' (#' .. sic .. ')')
							else
								print(md .. ' - ' .. mhx .. ' (#' .. sic .. ')')
							end
							si=si+1
				end
				sic=sic+1
				if (sic ==al.Count) or (si==z) then
					ed=true
				end
		end
		print('')
		if onWrite==true then
			print('Written to addresses:')
		else
			print('Read addresses:')
		end
		
		for i = 1, #bps do
			local b=bps[i]
			debug_setBreakpoint(b[1], 1, trg, bpmInt3, function()
						b[3].Color=65535 --yellow
						if b[4]=='' then
								print(b[2] .. ' (#' .. b[5] .. ')')
							else
								print(b[4] .. ' - ' .. b[2] .. ' (#' .. b[5] .. ')')
							end
						debug_removeBreakpoint(b[1])
			end)
		end
end

batchRW={
	attach=attach,
	printAddrs=printAddrs,
	detachAll=detachAll
}