local regs_n={'RAX','RBX','RCX','RDX','RDI','RSI','RBP','RSP','R8','R9','R10','R11','R12','R13','R14','R15','XMM0','XMM1','XMM2','XMM3','XMM4','XMM5','XMM6','XMM7','XMM8','XMM9','XMM10','XMM11','XMM12','XMM13','XMM14','XMM15','FP0','FP1','FP2','FP3','FP4','FP5','FP6','FP7'}
local rl=#regs_n
local abp=nil

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

local function getLenNilTable(n)
	local out={}
	if n>0 then
		for i = 1, n do
			table.insert(out,nil)
		end
	end
	return out
end

local regs=getLenNilTable(rl)

local function dumpRegisters()
	local c=false
	for i = 1, rl do
		local ri=regs_n[i]
                local riv=regs[i]
                if riv ~= nil then
					if c==false then
						print('Last registers at attached point (' .. string.format('%X',abp) .. ') before this break: ')
						c=true
					end
					print(ri .. ': ' .. riv)
                end
	end
        print('')
end

local function removeAttachedBp()
	debug_removeBreakpoint(abp) 
	abp=nil
	regs =getLenNilTable(rl)
end

local function attachBp(a)
	if abp ~=nil then
		removeAttachedBp()
	end
	abp=a
	debug_setBreakpoint(a)
end

function debugger_onBreakpoint()
if abp ~=nil then
		if RIP==abp then
			debug_getContext(true)
			local regsV={RAX,RBX,RCX,RDX,RDI,RSI,RBP,RSP,R8,R9,R10,R11,R12,R13,R14,R15}
			
			local rx=string.format('%016X',regsV[1])
			local rxb=hexToAOB(rx)
			rx=rx .. ' (' .. table.concat(rxb," ") ..')' 
			regs[1]=rx
			
			for i=2, 16 do
				rx=string.format('%016X',regsV[i])
				rxb=hexToAOB(rx)
				rx=rx .. ' (' .. table.concat(rxb," ") ..')' 
				regs[i]=rx
			end
			
			local regsVF={}
			
			for i=0, 15 do
				table.insert(regsVF,debug_getXMMPointer(i))
			end

			local decByteString = table.concat(readBytesLocal(regsVF[1],16,true), ' ')
			local hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs[17]=hexByteString
			
			for i=2, 16 do
				decByteString = table.concat(readBytesLocal(regsVF[i],16,true), ' ')
				hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
				regs[i+16]=hexByteString
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
				regs[32+i]=hexByteString
			end

			debug_continueFromBreakpoint(co_run)
			else
				 dumpRegisters()
		end
	end
end

attachBpLog={
	attachBp=attachBp,
	dumpRegisters=dumpRegisters,
	removeAttachedBp=removeAttachedBp
}
