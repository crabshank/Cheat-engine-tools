local abp={}

local function hexToAOB(str)
	local sl=string.len(str)
	local out={}
	for i = sl, 1, -2 do
		local i2=i-1
		local ss=''
		if i2==0 then
			ss='0' .. string.sub(str, i,i)
		else
			ss=string.sub(str, i2,i) 
		end
		table.insert(out,ss)
	end
	return out
end

local function printAttached()
		local abpl=#abp
		if abpl>0 then
			print('Attached breakpoints: ')
			for  k = 1, abpl do
				local ak=abp[k]
				print(k .. ': ' .. ak['address_hex'])
			end
			print('')
		end
end

local function dumpRegisters(k)
	local c=false
	local ak=abp[k]
	local riv=ak.regs
	local rivl=#riv
		print('regs length = ' .. rivl)
	 if rivl >0 then
		for i = 1, rivl do
			if c==false then
				print( ak['calc'] ..' logged at ' .. ak['address_hex'] .. ' (' .. rivl .. ' hits):')
				c=true
			end
			print(riv[i])
		end
		if c==true then
					   print('')
		end
	end
end

local function rem_abp(i,b)
	local out={}
	if b==true then
		for k=1, #abp do
			if k~=i then
				table.insert(out,abp[k])
			end
		end
	else
		for k=1, #abp do
			local ak=abp[k]
			if ak.address~=i then
				table.insert(out,ak)
			end
		end
	end
	return out
end

local function removeAttached(i,b)
	local abpl=#abp
	if b==true then
		debug_removeBreakpoint(abp[i].address)
		abp=rem_abp(i,true)
	elseif i==nil then
		for k=1, abpl do
			debug_removeBreakpoint(abp[1].address)
			abp=rem_abp(1,true)
		end
	else
		debug_removeBreakpoint(i)
		abp=rem_abp(i)
	end
	abpl=#abp
	if abpl>0 then
		printAttached()
	end
end

local function stop()
	local abpl=#abp
	if abpl>0 then
		print('All logs:')
		for  k = 1, abpl do
			dumpRegisters(k)
		end
		print('')
	end
	removeAttached()
end

local function get_abp_el(a)
	local ix=-1
	for k=1, #abp do
			if abp[k].address==a then
				ix=k
				break
			end
	end
	return ix
end

local function onBp()

	local abpl=#abp
if abpl >0 then
	local ix=get_abp_el(RIP)
		if ix>=0 then
			local abpx=abp[ix]
			local abpxc=abpx['calc']

			debug_getContext(true)

			local clc={} 
			if abpx['c_type']=='table' then
				for j=1, #abpxc do
					table.insert(clc,abpxc[j])
				end
			else
				table.insert(clc,abpxc)
			end

			for j=1, #clc do
					local func= load("return function() return ".. clc[j] .." end")
					local b,r=pcall(func())
					if abpx['ptr']==true then
						local rb=r+abpx['bh']
						local rf=r+abpx['fw']
						local rg=rf-rb+1
						local decByteString = table.concat(readBytes(rb,rg,true), ' ')
						local hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
						table.insert(abpx.regs,hexByteString)
					else
						if type(r)=='table' then
							local rx=table.concat(r, ' '):gsub('%S+',function (c) return string.format('%02X',c) end)
							table.insert(abpx.regs,rx)
						else
							local rx=string.format('%016X',r)
							local rxb=hexToAOB(rx)
							rxbt=table.concat(rxb," ") 
							table.insert(abpx.regs,rxbt)
						end
					end
					
					if #abpx.regs==1 then
						print('Breakpoint at ' .. abpx['address_hex'] .. ' hit!') 
					end
			end
					
		end
	end
			debug_continueFromBreakpoint(co_run)
end

local function attachLpAddr(a,c,p,bh,fw)
	abp=rem_abp(a)
	table.insert(abp,{['address']=a,['address_hex']=string.format('%X',a),['regs']={},['ptr']=p,['calc']=c,['c_type']=type(c),['bh']=bh,['fw']=fw})
	debug_setBreakpoint(a,onBp)
end

local function attach(t,c,p,bh,fw)
	if bh~=nil and bh>=0 then
		print('Argument "bh", if specified, must be <0')
		return
	end
	if fw~=nil and fw<=0 then
		print('Argument "fw", if specified, must be >0')
		return
	end
	local a=t
	if type(t)=='table' then
		for j=1, #t do
			attachLpAddr(a[j],c,p,bh,fw)
		end
	else
		attachLpAddr(a,c,p,bh,fw)
	end

end

logpoint={
	attach=attach,
	dumpRegisters=dumpRegisters,
	removeAttached=removeAttached,
	stop=stop,
	printAttached=printAttached
}
