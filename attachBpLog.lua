local regs = {['RAX']=nil,['RBX']=nil,['RCX']=nil,['RDX']=nil,['RDI']=nil,['RSI']=nil,['RBP']=nil,['RSP']=nil,['R8']=nil,['R9']=nil,['R10']=nil,['R11']=nil,['R12']=nil,['R13']=nil,['R14']=nil,['R15']=nil,['XMM0']=nil,['XMM1']=nil,['XMM2']=nil,['XMM3']=nil,['XMM4']=nil,['XMM5']=nil,['XMM6']=nil,['XMM7']=nil,['XMM8']=nil,['XMM9']=nil,['XMM10']=nil,['XMM11']=nil,['XMM12']=nil,['XMM13']=nil,['XMM14']=nil,['XMM15']=nil}

local regs_n={'RAX','RBX','RCX','RDX','RDI','RSI','RBP','RSP','R8','R9','R10','R11','R12','R13','R14','R15','XMM0','XMM1','XMM2','XMM3','XMM4','XMM5','XMM6','XMM7','XMM8','XMM9','XMM10','XMM11','XMM12','XMM13','XMM14','XMM15'}

local abp=nil

local function dumpRegisters()
	local c=false
	for i = 1, 33 do
		local ri=regs_n[i]
                local riv=regs[ri]
                if riv ~= nil then
					if c==false then
						print('Last registers at attached point (' .. string.format('%X',abp) .. ') before this break: ')
						c=true
					end
					print(ri .. ': ' .. regs[ri])
                end
	end
        print('')
end

local function attachBp(a)
	if abp ~=nil then
		removeAttachedBp()
	end
	abp=a
	debug_setBreakpoint(a)
end

local function removeAttachedBp()
	debug_removeBreakpoint(abp) 
	abp=nil
	regs = {['RAX']=nil,['RBX']=nil,['RCX']=nil,['RDX']=nil,['RDI']=nil,['RSI']=nil,['RBP']=nil,['RSP']=nil,['R8']=nil,['R9']=nil,['R10']=nil,['R11']=nil,['R12']=nil,['R13']=nil,['R14']=nil,['R15']=nil,['XMM0']=nil,['XMM1']=nil,['XMM2']=nil,['XMM3']=nil,['XMM4']=nil,['XMM5']=nil,['XMM6']=nil,['XMM7']=nil,['XMM8']=nil,['XMM9']=nil,['XMM10']=nil,['XMM11']=nil,['XMM12']=nil,['XMM13']=nil,['XMM14']=nil,['XMM15']=nil}
end

function debugger_onBreakpoint()
if abp ~=nil then
		if RIP==abp then
			debug_getContext(true)
			local rx=string.format('%016X',RAX)
			regs['RAX']=rx
			rx=string.format('%016X',RBX)
			regs['RBX']=rx
			rx=string.format('%016X',RCX)
			regs['RCX']=rx
			rx=string.format('%016X',RDX)
			regs['RDX']=rx
			rx=string.format('%016X',RDI)
			regs['RDI']=rx
			rx=string.format('%016X',RSI)
			regs['RSI']=rx
			rx=string.format('%016X',RBP)
			regs['RBP']=rx
			rx=string.format('%016X',RSP)
			regs['RSP']=rx
			rx=string.format('%016X',RIP)
			regs['RIP']=rx
			rx=string.format('%016X',R8)
			regs['R8']=rx
			rx=string.format('%016X',R9)
			regs['R9']=rx
			rx=string.format('%016X',R10)
			regs['R10']=rx
			rx=string.format('%016X',R11)
			regs['R11']=rx
			rx=string.format('%016X',R12)
			regs['R12']=rx
			rx=string.format('%016X',R13)
			regs['R13']=rx
			rx=string.format('%016X',R14)
			regs['R14']=rx
			rx=string.format('%016X',R15)
			regs['R15']=rx

			local decByteString = table.concat(readBytesLocal(debug_getXMMPointer(0),16,true), ' ')
			local hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM0']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(1),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM1']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(2),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM2']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(3),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM3']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(4),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM4']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(5),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM5']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(6),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM6']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(7),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM7']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(8),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM8']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(9),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM9']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(10),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM10']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(11),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM11']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(12),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM12']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(13),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM13']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(14),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM14']=hexByteString

			decByteString = table.concat(readBytesLocal(debug_getXMMPointer(15),16,true), ' ')
			hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
			regs['XMM15']=hexByteString

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