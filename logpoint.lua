local abp={}
local stopped=false
local print=print
local str_match = string.match
local function trim_str(s)
	return str_match(s,'^()%s*$') and '' or str_match(s,'^%s*(.*%S)')
end
local upperc=string.upper

local R8D_bak, R8W_bak, R8B_bak, R8L_bak, R9D_bak, R9W_bak, R9B_bak, R9L_bak, R10D_bak, R10W_bak, R10B_bak, R10L_bak, R11D_bak, R11W_bak, R11B_bak, R11L_bak, R12D_bak, R12W_bak, R12B_bak,  R12L_bak, R13D_bak, R13W_bak, R13B_bak, R13L_bak, R14D_bak, R14W_bak, R14B_bak, R14L_bak, R15D_bak, R15W_bak, R15B_bak,  R15L_bak, SIL_bak, DIL_bak, BPL_bak, SPL_bak, AX_bak, AL_bak, AH_bak, BX_bak, BL_bak, BH_bak, CX_bak, CL_bak, CH_bak, DX_bak, DL_bak, DH_bak, SI_bak, DI_bak, BP_bak, SP_bak

local function backupGlobals()
	R8D_bak=R8D
	R8W_bak=R8W
	R8B_bak=R8B
	R8L_bak=R8L
	R9D_bak=R9D
	R9W_bak=R9W
	R9B_bak=R9B
	R9L_bak=R9L
	R10D_bak=R10D
	R10W_bak=R10W
	R10B_bak=R10B
	R10L_bak=R10L
	R11D_bak=R11D
	R11W_bak=R11W
	R11B_bak=R11B
	R11L_bak=R11L
	R12D_bak=R12D
	R12W_bak=R12W
	R12B_bak=R12B
	R12L_bak=R12L
	R13D_bak=R13D
	R13W_bak=R13W
	R13B_bak=R13B
	R13L_bak=R13L
	R14D_bak=R14D
	R14W_bak=R14W
	R14B_bak=R14B
	R14L_bak=R14L
	R15D_bak=R15D
	R15W_bak=R15W
	R15B_bak=R15B
	R15L_bak=R15L
	SIL_bak=SIL
	DIL_bak=DIL
	BPL_bak=BPL
	SPL_bak=SPL
	AX_bak=AX
	AL_bak=AL
	AH_bak=AH
	BX_bak=BX
	BL_bak=BL
	BH_bak=BH
	CX_bak=CX
	CL_bak=CL
	CH_bak=CH
	DX_bak=DX
	DL_bak=DL
	DH_bak=DH
	SI_bak=SI
	DI_bak=DI
	BP_bak=BP
	SP_bak=SP
end

local function restoreGlobals()
	R8D=R8D_bak
	R8W=R8W_bak
	R8B=R8B_bak
	R8L=R8L_bak
	R9D=R9D_bak
	R9W=R9W_bak
	R9B=R9B_bak
	R9L=R9L_bak
	R10D=R10D_bak
	R10W=R10W_bak
	R10B=R10B_bak
	R10L=R10L_bak
	R11D=R11D_bak
	R11W=R11W_bak
	R11B=R11B_bak
	R11L=R11L_bak
	R12D=R12D_bak
	R12W=R12W_bak
	R12B=R12B_bak
	R12L=R12L_bak
	R13D=R13D_bak
	R13W=R13W_bak
	R13B=R13B_bak
	R13L=R13L_bak
	R14D=R14D_bak
	R14W=R14W_bak
	R14B=R14B_bak
	R14L=R14L_bak
	R15D=R15D_bak
	R15W=R15W_bak
	R15B=R15B_bak
	R15L=R15L_bak
	SIL=SIL_bak
	DIL=DIL_bak
	BPL=BPL_bak
	SPL=SPL_bak
	AX=AX_bak
	AL=AL_bak
	AH=AH_bak
	BX=BX_bak
	BL=BL_bak
	BH=BH_bak
	CX=CX_bak
	CL=CL_bak
	CH=CH_bak
	DX=DX_bak
	DL=DL_bak
	DH=DH_bak
	SI=SI_bak
	DI=DI_bak
	BP=BP_bak
	SP=SP_bak
end

local function getSubRegDecBytes(x,g,a,b,n)
	local xl=string.len(x)
    local out=''
	local out1=x
	local cl=g*2
	local pl= xl-cl
	local xl1=xl
	if pl<0 then
	    xl1=cl
	    out1=''
	    for i = 1, cl do
	        local k=pl+i
	        local p=''
	        if k<1 then
	            p='0'
	       else
	           p=string.sub(x, k,k) 
	        end
	        out1=out1 .. p
	    end
	elseif pl>0 then
	    out1=''
	    for i = cl+pl, 1+pl, -2 do
	        out1= string.sub(x,i-1,i) .. out1
	    end
	end

    for i=b*2, a*2, -2 do
	   out=string.sub(out1,i-1,i) .. out
	end
	if n==true then
		return tonumber(out,16)
	else
		  return out
	end
end

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
	local ks={#abp}
	if k~=nil then 
		ks[1]=k
	end
		for j=1, #ks do
			local ak=abp[j]
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

local function stop(pr)
	if pr==true and stopped==false then
		local abpl=#abp
		if abpl>0 then
			print('All logs:')
			for  k = 1, abpl do
				dumpRegisters(k)
			end
			print('')
		end
	end
	stopped=true
	restoreGlobals()
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
	local chk=false
	local abpx=0
	local ar={}
	local fres={}
	local abpl=#abp
	if abpl >0 then
		local ix=get_abp_el(RIP)
			if ix>=0 then
				abpx=abp[ix]
				local abpxc=abpx['calc']

				debug_getContext(true)
				
				backupGlobals()
				
				local r8g=getSubRegDecBytes(string.format("%X", R8), 8,1,8)
				local r9g=getSubRegDecBytes(string.format("%X", R9),8,1,8)
				local r10g=getSubRegDecBytes(string.format("%X", R10),8,1,8)
				local r11g=getSubRegDecBytes(string.format("%X", R11),8,1,8)
				local r12g=getSubRegDecBytes(string.format("%X", R12),8,1,8)
				local r13g=getSubRegDecBytes(string.format("%X", R13),8,1,8)
				local r14g=getSubRegDecBytes(string.format("%X", R14),8,1,8)
				local r15g=getSubRegDecBytes(string.format("%X", R15),8,1,8)
				
				-- EXTRA SUB-REGISTERS AVAILABLE:
				
				R8D=getSubRegDecBytes(r8g,8,5,8,true) --bottom 4 bytes (5,6,7,8)
				R8W=getSubRegDecBytes(r8g,8,7,8,true) --bottom 2 bytes (7,8)
				R8B=getSubRegDecBytes(r8g,8,8,8,true) --bottom byte (8)
				R8L=R8B
				R9D=getSubRegDecBytes(r9g,8,5,8,true)
				R9W=getSubRegDecBytes(r9g,8,7,8,true)
				R9B=getSubRegDecBytes(r9g,8,8,8,true)
				R9L=R9B
				R10D=getSubRegDecBytes(r10g,8,5,8,true)
				R10W=getSubRegDecBytes(r10g,8,7,8,true)
				R10B=getSubRegDecBytes(r10g,8,8,8,true)
				R10L=R10B
				R11D=getSubRegDecBytes(r11g,8,5,8,true)
				R11W=getSubRegDecBytes(r11g,8,7,8,true)
				R11B=getSubRegDecBytes(r11g,8,8,8,true)
				R11L=R11B
				R12D=getSubRegDecBytes(r12g,8,5,8,true)
				R12W=getSubRegDecBytes(r12g,8,7,8,true)
				R12B=getSubRegDecBytes(r12g,8,8,8,true)
				R12L=R12B
				R13D=getSubRegDecBytes(r13g,8,5,8,true)
				R13W=getSubRegDecBytes(r13g,8,7,8,true)
				R13B=getSubRegDecBytes(r13g,8,8,8,true)
				R13L=R13B
				R14D=getSubRegDecBytes(r14g,8,5,8,true)
				R14W=getSubRegDecBytes(r14g,8,7,8,true)
				R14B=getSubRegDecBytes(r14g,8,8,8,true)
				R14L=R14B
				R15D=getSubRegDecBytes(r15g,8,5,8,true)
				R15W=getSubRegDecBytes(r15g,8,7,8,true)
				R15B=getSubRegDecBytes(r15g,8,8,8,true)
				R15L=R15B
				
				SIL=getSubRegDecBytes(ESI,4,4,4,true)
				DIL=getSubRegDecBytes(EDI,4,4,4,true)
				BPL=getSubRegDecBytes(EBP,4,4,4,true)
				SPL=getSubRegDecBytes(ESP,4,4,4,true)

				AX=getSubRegDecBytes(EAX,4,3,4,true) 
				AL=getSubRegDecBytes(EAX,4,4,4,true) 
				AH=getSubRegDecBytes(EAX,4,3,3,true) 
				
				BX=getSubRegDecBytes(EBX,4,3,4,true) 
				BL=getSubRegDecBytes(EBX,4,4,4,true) 
				BH=getSubRegDecBytes(EBX,4,3,3,true) 
				
				CX=getSubRegDecBytes(ECX,4,3,4,true) 
				CL=getSubRegDecBytes(ECX,4,4,4,true) 
				CH=getSubRegDecBytes(ECX,4,3,3,true) 
				
				DX=getSubRegDecBytes(EDX,4,3,4,true) 
				DL=getSubRegDecBytes(EDX,4,4,4,true) 
				DH=getSubRegDecBytes(EDX,4,3,3,true) 
				
				SI=getSubRegDecBytes(ESI,4,3,4,true)
				DI=getSubRegDecBytes(EDI,4,3,4,true)
				BP=getSubRegDecBytes(EBP,4,3,4,true)
				SP=getSubRegDecBytes(ESP,4,3,4,true)
				
				-- EXTRA SUB-REGISTERS

				local clc={} 
				if abpx['c_type']=='table' then
					for j=1, #abpxc do
						table.insert(clc,upperc(abpxc[j]))
					end
				else
					table.insert(clc,upperc(abpxc))
				end
			
			ar=abpx.regs
				for j=1, #clc do
						local func= load("return function() return ".. clc[j] .." end")
						local b,r=pcall(func())
						restoreGlobals()
						if abpx['ptr']==true then
							local rb=r+abpx['bh']
							local rf=r+abpx['fw']
							local rg=rf-rb+1
							local byt=readBytes(rb,rg,true)
							if type(byt) =='table' then
								local decByteString = table.concat(byt, ' ')
								local hexByteString = decByteString:gsub('%S+',function (c) return string.format('%02X',c) end)
								table.insert(ar,hexByteString)
								table.insert(fres,hexByteString)
								chk=true
							end
						else
							if type(r)=='table' then
								local rx=table.concat(r, ' '):gsub('%S+',function (c) return string.format('%02X',c) end)
								table.insert(ar,rx)
								table.insert(fres,rx)
								chk=true
							else
								local rx=string.format('%X',r)
								local rxb=hexToAOB(rx)
								rxbt=table.concat(rxb," ") 
								table.insert(ar,rxbt)
								table.insert(fres,rxbt)
								chk=true
							end
						end
						
						if #abpx.regs==1 then
							print('Breakpoint at ' .. abpx['address_hex'] .. ' hit!') 
						end
				end

			end
	end
							local bpst=abpx['bpst']
							local brl=#bpst
							if chk==true and brl>0 then
								local fnd=false
								local frl=#fres
								for k=1, frl do
									for i=1, brl do
										if str_match(fres[k], bpst[i]) then 
											fnd=true
											i=brl
											k=frl
										end
									end
								end
								
								if fnd==false then
									debug_continueFromBreakpoint(co_run)
								else
									return 1
								end		
							else
								debug_continueFromBreakpoint(co_run)
							end
							
			
end

local function attachLpAddr(a,c,p,bh,fw,bpst)
	abp=rem_abp(a)
	table.insert(abp,{['address']=a,['address_hex']=string.format('%X',a),['regs']={},['ptr']=p,['calc']=c,['c_type']=type(c),['bh']=bh,['fw']=fw,['bpst']=bpst})
	debug_setBreakpoint(a,onBp)
end

local function attach(...)
   local args = {...}
   for i,v in ipairs(args) do
		if type(v)~='table' then
			print('Arguments to this function are tables!')
			return
		end
		
		local a=v[1]
		if type(a)=='string' then
			a=getAddress(a)
		end
		local c=v[2]
		local p=v[3]
		local bh=v[4]
		local fw=v[5]
		local bpt=v[6]

		if type(c)~='string' and type(c)~='table' then
			print('Argument "c", must be specified!')
			return
		end
				
		if bh~=nil and bh>0 then
			print('Argument "bh", in table #'..i..', if specified, must be <=0')
			return
		end
		
		if fw~=nil and fw<0 then
			print('Argument "fw", in table #'..i..', if specified, must be >=0')
			return
		end
		tybt=type(bpt)
		if bpt~=nil and ((tybt=='table' and #bpt<1) or (tybt~='string' and tybt~='table')) then
			print('Argument "bpt", if specified, must be a string or a table of strings')
			return
		end
		local bpst={}
		if bpt~=nil then
			if tybt=='string' then
				table.insert(bpst,upperc(trim_str(bpt)))
			else
				for i=1, #bpt do
					table.insert(bpst,upperc(trim_str(bpt[i])))
				end
			end
		end
		--removeAttached()
		stopped=false
		attachLpAddr(a,c,p,bh,fw,bpst)
	end
end

function debugger_onBreakpoint()
	print('BP!')
end

logpoint={
	attach=attach,
	dumpRegisters=dumpRegisters,
	removeAttached=removeAttached,
	stop=stop,
	printAttached=printAttached
}
