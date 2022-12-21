local regs_n={'RAX','RBX','RCX','RDX','RDI','RSI','RBP','RSP','R8','R9','R10','R11','R12','R13','R14','R15','XMM0','XMM1','XMM2','XMM3','XMM4','XMM5','XMM6','XMM7','XMM8','XMM9','XMM10','XMM11','XMM12','XMM13','XMM14','XMM15','FP0','FP1','FP2','FP3','FP4','FP5','FP6','FP7'}
local rl=#regs_n
local abp={}

local function hexToAOB(str)
	local sl=string.len(str)
	local k=1
	local out={}
	for i = 1, sl do
		local ri=sl + 1 - k
		local ri2=ri-1
	  table.insert(out,string.sub(str, ri2,ri) )
		k=k+2
		if k>sl then
			break
		end
	end
	return out
end

local function getLenTable(n,v)
	local out={}
	if n>0 then
		for i = 1, n do
			table.insert(out,v)
		end
	end
	return out
end

local function identicalRegs(k)
		local ak=abp[k]
		local sme=true
		for i = 1, rl do
			if ak.regs[i]~=ak.regsLastDisp[i] then
				sme=false
				break
			end
		end
		return sme
end

local function dumpDiffRegs(k)
	local c=false
	local ak=abp[k]
	for i = 1, rl do
		local ri=regs_n[i]
                local riv=ak.regs[i]
                local rivl=ak.regsLastDisp[i]
                if riv ~= nil then
					if c==false then
						print('Changed registers at attached point (' .. string.format('%X',ak.address) .. ') since last break: ')
						c=true
					end
					if riv~=rivl then
						print(ri .. ': ' .. riv .. ' [Δ]')
					else 
						print(ri .. ': ' .. riv)
					end
                end
	end
	if c==true then
			 print('')
	end
end

local function printAttached()
		local abpl=#abp
		if abpl>0 then
			print('Attached breakpoints: ')
			for  k = 1, abpl do
				local ak=abp[k]
				print(k .. ': ' .. string.format('%X',ak.address))
			end
			print('')
		end
end

local function dumpAllRegisters()
	for  k = 1, #abp do
		local c=false
		local ak=abp[k]
		for i = 1, rl do
			local ri=regs_n[i]
					local riv=ak.regs[i]
					if riv ~= nil then
						if c==false then
							print('Last registers at attached point (' .. string.format('%X',ak.address) .. ') before this break: ')
							c=true
						end
						print(ri .. ': ' .. riv)
					end
		end
		if c==true then
			print('')
		end
	end
end

local function dumpRegisters_k(k)
	local c=false
	local ak=abp[k]
	for i = 1, rl do
		local ri=regs_n[i]
                local riv=ak.regs[i]
                if riv ~= nil then
					if c==false then
						print('Last registers at attached point (' .. string.format('%X',ak.address) .. ') before this break: ')
						c=true
					end
					print(ri .. ': ' .. riv)
                end
	end
	if c==true then
				   print('')
	end
end

local function dumpRegisters(k)
	if k==nil then 
		dumpAllRegisters()
	else
		 dumpRegisters_k(k)
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

local function removeAttachedBp(i,b)
	if b==true then
		debug_removeBreakpoint(abp[i].address)
		abp=rem_abp(i,true)
	else 
		debug_removeBreakpoint(i)
		abp=rem_abp(i)
	end
	for k=1, #abp do
		abp[k].forcePrint=true
	end
	printAttached()
end

local function attachBp(a)
	abp=rem_abp(a)
	for k=1, #abp do
		abp[k].forcePrint=true
	end
	table.insert(abp,{['address']=a,['regs']=getLenTable(rl), ['regsLastDisp']=getLenTable(rl),['rgc']=0, ['forcePrint']=true})
	debug_setBreakpoint(a)
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

local function set_regsLastDisp(k)
	local ak=abp[k]
	for t=1, rl do
		ak.regsLastDisp[t]=ak.regs[t]
	end
	ak.rgc=ak.rgc+1
end

local function onBp()
local abpl=#abp
if abpl >0 then
	local ix=get_abp_el(RIP)
		if ix>=0 then
			local abpx=abp[ix]
			
			debug_getContext(true)
			local regsV={RAX,RBX,RCX,RDX,RDI,RSI,RBP,RSP,R8,R9,R10,R11,R12,R13,R14,R15}
			
			local rx=string.format('%016X',regsV[1])
			local rxb=hexToAOB(rx)
			rx=rx .. ' (' .. table.concat(rxb," ") ..')' 
			abpx.regs[1]=rx
			
			for i=2, 16 do
				rx=string.format('%016X',regsV[i])
				rxb=hexToAOB(rx)
				rx=rx .. ' (' .. table.concat(rxb," ") ..')' 
				abpx.regs[i]=rx
			end
			
			local regsVF={}
			
			for i=0, 15 do
				table.insert(regsVF,debug_getXMMPointer(i))
			end

			local decByteString = table.concat(readBytesLocal(regsVF[1],16,true), ' ')
			local hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			abpx.regs[17]=hexByteString
			
			for i=2, 16 do
				decByteString = table.concat(readBytesLocal(regsVF[i],16,true), ' ')
				hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
				abpx.regs[i+16]=hexByteString
			end
			
			local regsFP={FP0,FP1,FP2,FP3,FP4,FP5,FP6,FP7}
			for i=1, 8 do
				local fpt={}
				local cfp=regsFP[i];
				for k=1, 10 do
					table.insert(fpt,cfp[k])
				end
				decByteString = table.concat(fpt, ' ')
				hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
				abpx.regs[32+i]=hexByteString
			end
			
			debug_continueFromBreakpoint(co_run)
			else

					for k=1, abpl do
						local ak=abp[k]
						if ak.forcePrint==false and ak.rgc~=0 then
							local sameRegs=identicalRegs(k)
							if sameRegs==false then
								dumpDiffRegs(k)
								set_regsLastDisp(k)
							end
						end
					end
				
				for k=1, abpl do
					local ak=abp[k]
					if ak.forcePrint==true or ak.rgc==0 then
						dumpRegisters(k)
						set_regsLastDisp(k)
						ak.forcePrint=false
					end
				end
				
		end
	end
end

function debugger_onBreakpoint()
	onBp()
end

attachBpLog={
	attachBp=attachBp,
	dumpRegisters=dumpRegisters,
	removeAttachedBp=removeAttachedBp,
	printAttached=printAttached
}
