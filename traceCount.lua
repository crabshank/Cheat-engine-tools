local frm = getMemoryViewForm()
frm.hv = frm.DisassemblerView
frm.hx=frm.HexadecimalView

local trace_w={nil,nil} --form,label

local print=print
local string=string
local upperc=string.upper
local string_gmatch=string.gmatch
local string_match=string.match
local string_find=string.find

local condBpProg=false
local condBpAddr={}
local condBpVals={['str']={},['num']={},['opc']={},['bf']=nil}

local present_r_last_lookup={}
local present_m_last_lookup={}
local present_mem_last_lookup={}
local currModule=nil
local currRegsAddr=nil
local jmpFirst=false

local midTrace=false

local findWriteStepOver=nil
local findWriteBp=false
local findWriteLastWasCall=false
local findWriteStart=nil
local findWriteEnd=nil
local findWriteFirst=nil
local findWriteAttached={}
local findWriteToAttach={}
local findWriteLookup={}
local findWriteLookup_step={}
local findWriteAobs={}
local findWriteStackBps={}
local findWritePatts={}
local findWriteModules=nil
local findWriteWasPatt=false
local modulesList_findWrite={}
local lastAddr_findWrite={}

local findWriteAlreadyStep={}

local rw_trace=0

local function getSymbolNameFromAddress(a, outBoth)
    local out = {getNameFromAddress(a, true, true, true, true), getNameFromAddress(a, true, true, false)} --[1]= preferred
    local su1, su2 = string.find(out[1], "[\128-\255]") -- non-ascii?

    if su1~=nil then
        local o2=out[2]
        out[2]=out[1]
        out[1]=o2
    end

    if outBoth~=true then
        if out[1]==nil or out[1]=="" then
            return string.format("%X", a)
        end
        return out[1]
    else
        local hxv = ""
        if out[1]==nil or out[1]=="" then
            hxv = string.format("%X", a)
            out[1]=hxv
        end
        if out[2]==nil or out[2]=="" then
            if hxv=="" then
                out[2]=string.format("%X", a)
            else
                out[2]=hxv
            end
        end
        return {out[1], out[2]}
    end
end

local function s_pluralise(c,t)
	if c~=1 then
		return t..'s'
	else
		return t
	end
end

local function isInModule(address,address_hex,list) -- https://github.com/cheat-engine/cheat-engine/issues/205 (mgrinzPlayer)
	for i=1, #list do
	local v=list[i]
		if address>=v.Address and address<=v.lastByte then
			local inc=v.Included
			local ofs=address-v.Address
			local ofsNm=''
			if ofs>0 then
				ofsNm=v.Name..'+'..string.format('%X',ofs)
			else
				ofsNm=v.Name
			end
			return {inc,ofsNm,v.Name}
		end
	end
	return {false,address_hex}
end

local function spaceSep_int(b)
	local g=''
	if b<0 then
	   g='-'
	   b=math.abs(b)
	end
	local n=tostring(b)
	local l=#n
	local c=l
	local out={}
	if l>3 then
	   while c>0 do
			 local a=math.max(1,c-2)
			 table.insert(out,1,n:sub(a,c))
			 c=c-3
	   end
	   return g..table.concat(out,' ')
	else
		return g..n
	end
end

local function sameTable(t1,t2)
	local t1l, t2l= #t1, #t2
	if t1l~=t2l then
		return false
	else
		for i=1, t1l do
			if t1[i]~=t2[i] then
					return false
			end
		end
		return true
	end
end

local function alloc(name,size,module_name)
  local scrp=''
  if module_name==nil or module_name=='' then
      scrp=string.format('alloc(%s,%d)\nregistersymbol(%s)',name,size,name)
  else
      scrp=string.format('alloc(%s,%d,%s)\nregistersymbol(%s)',name,size,module_name,name)
  end
  autoAssemble(scrp)
  return getAddress(name)
end

local function dealloc(name)
  local scrp=string.format('dealloc(%s)\nunregistersymbol(%s)',name,name)
  autoAssemble(scrp)
end

local function getModuleName(address) -- https://github.com/cheat-engine/cheat-engine/issues/205 (mgrinzPlayer)
  local modulesTable,size = enumModules(),0
  for i,v in pairs(modulesTable) do
      size = getModuleSize(v.Name)
      if address>=v.Address and address<(v.Address+size) then
        return v.Name
      end
  end
  return string.format('%X',address)
end

local function trim_str(s)
	return string_match(s,'^()%s*$') and '' or string_match(s,'^%s*(.*%S)')
end

local function space_fix(s)
	local s2 = s:gsub("%s+", " ")
	return trim_str(s2)
end

local function str_allPosPlain(s,p)
	local t={}
	local c=1
	local brk=false
	while brk==false do
		  local fa,fb=string_find(s,p,c,true)
		  if fa~=nil then
			c=fa+1
			table.insert(t,{fa,fb})
		  else
			brk=true
		  end
	end
	return t
end

local function tableToAOB(t)
	local out={['aob']={}}
	for i=1, #t do
		local hx=string.format('%02X',t[i])
		table.insert(out['aob'],hx)
	end
	return out
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

    	local fnz=false
	local b2=b*2
	for i=a*2, b2, 2 do
		local sb=string.sub(out1,i-1,i)
		if fnz==false and (sb~='00' or i==b2) then
			fnz=true
		end
		if fnz==true then
			out=out..sb
		end
	end

	if n==true then
		return {['dec']=tonumber(out,16), ['aob']=hexToAOB(out), ['hex']=out}
	else
		  return out
	end
end

local registers={}

registers['get_regs']={}

registers['alt_names']={
	['R10B']='R10L',
	['R11B']='R11L',
	['R12B']='R12L',
	['R13B']='R13L',
	['R14B']='R14L',
	['R15B']='R15L',
	['FP0']='ST(0)',
	['FP1']='ST(1)',
	['FP2']='ST(2)',
	['FP3']='ST(3)',
	['FP4']='ST(4)',
	['FP5']='ST(5)',
	['FP6']='ST(6)',
	['FP7']='ST(7)',
	['R8B']='R8L',
	['R9B']='R9L'
}

registers['list_regs']={
	{'XMM10',16},
	{'XMM11',16},
	{'XMM12',16},
	{'XMM13',16},
	{'XMM14',16},
	{'XMM15',16},
	{'XMM0',16},
	{'XMM1',16},
	{'XMM2',16},
	{'XMM3',16},
	{'XMM4',16},
	{'XMM5',16},
	{'XMM6',16},
	{'XMM7',16},
	{'XMM8',16},
	{'XMM9',16},
	{'R10D',4},
	{'R10W',2},
	{'R10B',1},
	{'R11D',4},
	{'R11W',2},
	{'R11B',1},
	{'R12D',4},
	{'R12W',2},
	{'R12B',1},
	{'R13D',4},
	{'R13W',2},
	{'R13B',1},
	{'R14D',4},
	{'R14W',2},
	{'R14B',1},
	{'R15D',4},
	{'R15W',2},
	{'R15B',1},
	{'RAX',8},
	{'RBX',8},
	{'RCX',8},
	{'RDX',8},
	{'RDI',8},
	{'RSI',8},
	{'RBP',8},
	{'RSP',8},
	{'R10',8},
	{'R11',8},
	{'R12',8},
	{'R13',8},
	{'R14',8},
	{'R15',8},
	{'EAX',4},
	{'EBX',4},
	{'ECX',4},
	{'EDX',4},
	{'EDI',4},
	{'ESI',4},
	{'EBP',4},
	{'ESP',4},
	{'EIP',4},
	{'FP0',10},
	{'FP1',10},
	{'FP2',10},
	{'FP3',10},
	{'FP4',10},
	{'FP5',10},
	{'FP6',10},
	{'FP7',10},
	{'R8D',4},
	{'R8W',2},
	{'R8B',1},
	{'R9D',4},
	{'R9W',2},
	{'R9B',1},
	{'SIL',1},
	{'DIL',1},
	{'BPL',1},
	{'SPL',1},
	{'R8',8},
	{'R9',8},
	{'AX',2},
	{'AL',1},
	{'AH',1},
	{'BX',2},
	{'BL',1},
	{'BH',1},
	{'CX',2},
	{'CL',1},
	{'CH',1},
	{'DX',2},
	{'DL',1},
	{'DH',1},
	{'SI',2},
	{'DI',2},
	{'BP',2},
	{'SP',2},
	{'IP',2}
}

registers['disp_aob']={
	['XMM10']=true,
	['XMM11']=true,
	['XMM12']=true,
	['XMM13']=true,
	['XMM14']=true,
	['XMM15']=true,
	['XMM0']=true,
	['XMM1']=true,
	['XMM2']=true,
	['XMM3']=true,
	['XMM4']=true,
	['XMM5']=true,
	['XMM6']=true,
	['XMM7']=true,
	['XMM8']=true,
	['XMM9']=true,
	['FP0']=true,
	['FP1']=true,
	['FP2']=true,
	['FP3']=true,
	['FP4']=true,
	['FP5']=true,
	['FP6']=true,
	['FP7']=true
}

registers['regs']={}

registers['regs_args']={
	['R8D']='R8G',
	['R8W']='R8G',
	['R8B']='R8G',
	['R8L']='R8G',
	['R9D']='R9G',
	['R9W']='R9G',
	['R9B']='R9G',
	['R9L']='R9G',
	['R10D']='R10G',
	['R10W']='R10G',
	['R10B']='R10G',
	['R10L']='R10G',
	['R11D']='R11G',
	['R11W']='R11G',
	['R11B']='R11G',
	['R11L']='R11G',
	['R12D']='R12G',
	['R12W']='R12G',
	['R12B']='R12G',
	['R12L']='R12G',
	['R13D']='R13G',
	['R13W']='R13G',
	['R13B']='R13G',
	['R13L']='R13G',
	['R14D']='R14G',
	['R14W']='R14G',
	['R14B']='R14G',
	['R14L']='R14G',
	['R15D']='R15G',
	['R15W']='R15G',
	['R15B']='R15G',
	['R15L']='R15G',
	['SIL']='ESI_X',
	['DIL']='EDI_X',
	['BPL']='EBP_X',
	['SPL']='ESP_X',
	['IP']='EIP_X',
	['AX']='EAX_X',
	['AL']='EAX_X',
	['AH']='EAX_X',
	['BX']='EBX_X',
	['BL']='EBX_X',
	['BH']='EBX_X',
	['CX']='ECX_X',
	['CL']='ECX_X',
	['CH']='ECX_X',
	['DX']='EDX_X',
	['DL']='EDX_X',
	['DH']='EDX_X',
	['SI']='ESI_X',
	['DI']='EDI_X',
	['BP']='EBP_X',
	['SP']='ESP_X',
	['FP0']='FP0',
	['FP1']='FP1',
	['FP2']='FP2',
	['FP3']='FP3',
	['FP4']='FP4',
	['FP5']='FP5',
	['FP6']='FP6',
	['FP7']='FP7',
	['XMM0']='XMM0',
	['XMM1']='XMM1',
	['XMM2']='XMM2',
	['XMM3']='XMM3',
	['XMM4']='XMM4',
	['XMM5']='XMM5',
	['XMM6']='XMM6',
	['XMM7']='XMM7',
	['XMM8']='XMM8',
	['XMM9']='XMM9',
	['XMM10']='XMM10',
	['XMM11']='XMM11',
	['XMM12']='XMM12',
	['XMM13']='XMM13',
	['XMM14']='XMM14',
	['XMM15']='XMM15'
}

registers['get_regs']['FP0']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['FP1']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['FP2']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['FP3']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['FP4']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['FP5']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['FP6']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['FP7']=function(FP)
	return tableToAOB(FP)
end

registers['get_regs']['XMM0']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM1']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM2']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM3']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM4']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM5']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM6']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM7']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM8']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM9']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM10']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM11']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM12']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM13']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM14']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['XMM15']=function(XMM)
	return tableToAOB(XMM)
end

registers['get_regs']['R8D']=function(R8G)
	return getSubRegDecBytes(R8G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R8W']=function(R8G)
	return getSubRegDecBytes(R8G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R8B']=function(R8G)
	return getSubRegDecBytes(R8G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R8L']=function(R8G)
	return registers['get_regs']['R8B'](R8G)
end]]

registers['get_regs']['R9D']=function(R9G)
	return getSubRegDecBytes(R9G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R9W']=function(R9G)
	return getSubRegDecBytes(R9G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R9B']=function(R9G)
	return getSubRegDecBytes(R9G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R9L']=function(R9G)
	return registers['get_regs']['R9B'](R9G)
end]]

registers['get_regs']['R10D']=function(R10G)
	return getSubRegDecBytes(R10G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R10W']=function(R10G)
	return getSubRegDecBytes(R10G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R10B']=function(R10G)
	return getSubRegDecBytes(R10G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R10L']=function(R10G)
	return registers['get_regs']['R10B'](R10G)
end]]

registers['get_regs']['R11D']=function(R11G)
	return getSubRegDecBytes(R11G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R11W']=function(R11G)
	return getSubRegDecBytes(R11G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R11B']=function(R11G)
	return getSubRegDecBytes(R11G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R11L']=function(R11G)
	return registers['get_regs']['R11B'](R11G)
end]]

registers['get_regs']['R12D']=function(R12G)
	return getSubRegDecBytes(R12G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R12W']=function(R12G)
	return getSubRegDecBytes(R12G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R12B']=function(R12G)
	return getSubRegDecBytes(R12G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R12L']=function(R12G)
	return registers['get_regs']['R12B'](R12G)
end]]

registers['get_regs']['R13D']=function(R13G)
	return getSubRegDecBytes(R13G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R13W']=function(R13G)
	return getSubRegDecBytes(R13G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R13B']=function(R13G)
	return getSubRegDecBytes(R13G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R13L']=function(R13G)
	return registers['get_regs']['R13B'](R13G)
end]]

registers['get_regs']['R14D']=function(R14G)
	return getSubRegDecBytes(R14G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R14W']=function(R14G)
	return getSubRegDecBytes(R14G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R14B']=function(R14G)
	return getSubRegDecBytes(R14G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R14L']=function(R14G)
	return registers['get_regs']['R14B'](R14G)
end]]

registers['get_regs']['R15D']=function(R15G)
	return getSubRegDecBytes(R15G,8,5,8,true) --bottom 4 bytes (5,6,7,8)
end

registers['get_regs']['R15W']=function(R15G)
	return getSubRegDecBytes(R15G,8,7,8,true) --bottom 2 bytes (7,8)
end

registers['get_regs']['R15B']=function(R15G)
	return getSubRegDecBytes(R15G,8,8,8,true) --bottom byte (8)
end

--[[registers['get_regs']['R15L']=function(R15G)
	return registers['get_regs']['R15B'](R15G)
end]]

registers['get_regs']['SIL']=function(ESI_X)
	return getSubRegDecBytes(ESI_X,4,4,4,true)
end

registers['get_regs']['DIL']=function(EDI_X)
	return getSubRegDecBytes(EDI_X,4,4,4,true)
end

registers['get_regs']['BPL']=function(EBP_X)
	return getSubRegDecBytes(EBP_X,4,4,4,true)
end

registers['get_regs']['SPL']=function(ESP_X)
	return getSubRegDecBytes(ESP_X,4,4,4,true)
end

registers['get_regs']['AX']=function(EAX_X)
	return getSubRegDecBytes(EAX_X,4,3,4,true)
end

registers['get_regs']['AL']=function(EAX_X)
	return getSubRegDecBytes(EAX_X,4,4,4,true)
end

registers['get_regs']['AH']=function(EAX_X)
	return getSubRegDecBytes(EAX_X,4,3,3,true)
end

registers['get_regs']['BX']=function(EBX_X)
	return getSubRegDecBytes(EBX_X,4,3,4,true)
end

registers['get_regs']['BL']=function(EBX_X)
	return getSubRegDecBytes(EBX_X,4,4,4,true)
end

registers['get_regs']['BH']=function(EBX_X)
	return getSubRegDecBytes(EBX_X,4,3,3,true)
end

registers['get_regs']['CX']=function(ECX_X)
	return getSubRegDecBytes(ECX_X,4,3,4,true)
end

registers['get_regs']['CL']=function(ECX_X)
	return getSubRegDecBytes(ECX_X,4,4,4,true)
end

registers['get_regs']['CH']=function(ECX_X)
	return getSubRegDecBytes(ECX_X,4,3,3,true)
end

registers['get_regs']['DX']=function(EDX_X)
	return getSubRegDecBytes(EDX_X,4,3,4,true)
end

registers['get_regs']['DL']=function(EDX_X)
	return getSubRegDecBytes(EDX_X,4,4,4,true)
end

registers['get_regs']['DH']=function(EDX_X)
	return getSubRegDecBytes(EDX_X,4,3,3,true)
end

registers['get_regs']['SI']=function(ESI_X)
	return getSubRegDecBytes(ESI_X,4,3,4,true)
end

registers['get_regs']['DI']=function(EDI_X)
	return getSubRegDecBytes(EDI_X,4,3,4,true)
end

registers['get_regs']['BP']=function(EBP_X)
	return getSubRegDecBytes(EBP_X,4,3,4,true)
end

registers['get_regs']['SP']=function(ESP_X)
	return getSubRegDecBytes(ESP_X,4,3,4,true)
end

registers['get_regs']['IP']=function(EIP_X)
	return getSubRegDecBytes(EIP_X,4,4,4,true)
end

local function tprint(tbl, indent)
  local function do_tprint(tbl, indent) -- https://gist.github.com/ripter/4270799
	if not indent then indent = 0 end
	for k, v in pairs(tbl) do
	  formatting = string.rep("	", indent) .. k .. ": "
	  local typv=type(v)
	  if typv == "table" then
		print(formatting)
		do_tprint(v, indent+1)
	  elseif typv == 'boolean' then
		print(formatting .. tostring(v))
	  elseif typv == 'string' then
		local la, lb=string_find(v, "\n")
		if la==nil then
			print(formatting .. '"'.. v ..'"')
		else
			print(formatting .. '[['.. v ..']]')
		end
	  elseif typv == 'function' then
		print(formatting .. 'function () … end')
	  else
		print(formatting .. tostring(v))
	  end
	end
  end
  do_tprint(tbl,indent)
  print('\n')
end

local function deepcopy(orig)
	local orig_type = type(orig)
	local copy
	if orig_type == 'table' then
		copy = {}
		for orig_key, orig_value in next, orig, nil do
			copy[deepcopy(orig_key)] = deepcopy(orig_value)
		end
		setmetatable(copy, deepcopy(getmetatable(orig)))
	else -- number, string, boolean, etc
		copy = orig
	end
	return copy
end

local function setupFWstack()
	for j=findWriteStackBps[1], findWriteStackBps[2] do
						table.insert(findWriteAttached,j) --store attached indexes of findWriteToAttach!
						--print(string.format('%X added!',findWriteToAttach[j])) --DEBUG
						debug_setBreakpoint(findWriteToAttach[j],1,bptExecute,function()
								debug_getContext()
								local RIPx=string.format('%X',RIP)
								--print(RIPx.. ' hit!')
								for i=1, #findWriteAobs do
									local ai=findWriteAobs[i]
									local rCnt=0
									local res=AOBScan(ai,"",0)
									if res~=nil then
										rCnt= res.Count
									end
									if rCnt>0 then -- aob found!
										--print('AOB found!')
										for k=1, #findWriteAttached do
											local ix= findWriteAttached[k]
											local ak=findWriteToAttach[ix]
											if ak~=nil then
												debug_removeBreakpoint(ak)
												--print(string.format('%X removed!',ak)) --DEBUG
											end
										end
										findWriteAttached={}
										print( string.format("'%s' was written to memory between: '%s' and '%s'",ai,lastAddr_findWrite[2],isInModule(RIP,RIPx,modulesList_findWrite)[2] ))
										break
									else -- aob not found!
										--print('aob not found!') --DEBUG
										local lix=findWriteLookup[RIPx]
										for k=1, #findWriteAttached do
											local ix= findWriteAttached[k]
											local ak=findWriteToAttach[ix]
											if ak~=nil then
												debug_removeBreakpoint(ak)
												--print(string.format('%X removed!',ak)) --DEBUG
											end
										end
										findWriteAttached={}
										findWriteStackBps={lix+1,math.min(lix+4,#findWriteToAttach)}
										setupFWstack()
										lastAddr_findWrite={RIP,isInModule(RIP,RIPx,modulesList_findWrite)[2]}
									end
									if res~=nil then
										res.destroy()
									end
							end
				end)
	end
end

local count=0
local instRep=nil
local hits={}
local hits_lookup={}
local mem_accs_lookup={}
local mem_accs_sorted={}
local hits_deref={}
local hits_deref_lookup={}
local currTraceDss={}
local st={}
local hp={}
local prog=false
local first=false
local abp={}
local hpp={}
local stp=0
local trace_info=''
local forceSave=''
local sio=''
local traceModules={}
local condTraceModules={}

local rw_lookup={0,{}}

local mri_skip=false
local mri_isCall=true
local mrc_retAdr=nil

local mri_skipCond=false
local mri_isCallCond=true
local mrc_retAdrCond=nil

local stopTraceEnd=false
local lite_stopTraceEnd=false

local liteAddr=0
local liteAbp={}
local liteIx=1
local liteCount=0
local liteBp=false

local liteFirst=true
local liteStepOver=0 --0/1/2 - into/over/into but over when executed before
local liteForceStepOver=false
local liteTrace={}
local liteTrace_lookup={}
local liteFormattedCount={}
local liteRep=nil

local function string_arr(s)
	local spl={}
	local sl=string.len(s)
	for i=1, sl do
		table.insert(spl,string.sub(s,i,i))
	end
	return spl
end

local function plainSplitKeep(str,ptrn) -- coronalabs.com | https://stackoverflow.com/a/19263313
	local out = {}
	local strt_pos = 1
	local sp_start, sp_end = string_find(str, ptrn, strt_pos,true)

	while sp_start do
		local sa=string.sub(str, strt_pos, sp_start-1)
		if sa~='' then
			table.insert( out, sa )
		end
		table.insert( out, string.sub(str, sp_start, sp_end) )
		strt_pos = sp_end + 1
		sp_start, sp_end = string_find(str, ptrn, strt_pos,true)
	end

	local sl=string.sub( str, strt_pos )
	if sl~='' then
		table.insert( out,sl  )
	end
	return out
end

local function plainReplace(s,r,w,n)
	local spl=plainSplitKeep(s,r,true)
	local c=1
	local is_n=false
	if type(n)=='number' and n>0 then
		is_n=true
	end
	for i=1, #spl do
		if spl[i]==r then
			if is_n and c==n then
				spl[i]=w
				break
			elseif is_n==false then
				spl[i]=w
			end
			c=c+1
		end
	end
	return table.concat(spl,'')
end

local function get_subtable(t, strt, ed)
  local out = {}

  for i =strt, ed do
    table.insert(out,t[i])
  end

  return out
end

local function get_substring_tbl(t, strt, ed)
	local ss=get_subtable(t, strt, ed)
	return table.concat(ss,'')
end

local function strPatCeption(s,t,og)
	local str, stt --str gets searched (STRING!), stt is an array of the output (TABLE!)
	local tys=type(s)
	local ty_og=type(og)
	
	if tys=='string' then
		str=s
	elseif tys=='table' then
		str=table.concat(s,'')
	else
		return {}
	end
	
	if ty_og=='string' then
		stt=string_arr(og)
	elseif ty_og=='table' then
		stt=og
	elseif og==nil then
		if tys=='string' then
			stt=string_arr(s)
		elseif tys=='table' then
			stt=s
		else
			return {}
		end
	end
	
	local fnds={}
	for i=1, #t do
		local ti=t[i]
		local fnd_i={'',{},{}}
		
		if i==1 then
			local fa,fb=string_find(str,ti)
			if fa==nil then
				break
			else
				for j=fa, fb do
					table.insert(fnd_i[2],stt[j])
					table.insert(fnd_i[3],j)
				end
				fnd_i[1]=table.concat(fnd_i[2],'')
				table.insert(fnds,fnd_i)
			end
		else
			local lst=i-1
			local flst=fnds[lst]
			local flst_st=flst[3][1]
			local fa,fb=string_find(flst[1],ti)
			if fa==nil then
				break
			else
				for j=fa, fb do
					local j2=flst_st+j-1
					table.insert(fnd_i[2],stt[j2])
					table.insert(fnd_i[3],j2)
				end
				fnd_i[1]=table.concat(fnd_i[2],'')
				table.insert(fnds,fnd_i)
		end
		end
	end
	return fnds
end

local function getAccessed(instruction,instruction_upper)
	--if instruction_upper==nil then 1st argument is uppercase already
	local t={}
    local allOB={}
	local instruction_arr=string_arr(instruction)
	local instruction_arr_upper
	if instruction_upper==nil then
		instruction_arr_upper=deepcopy(instruction_arr)
	else
		 instruction_arr_upper=string_arr(instruction_upper)
	end
    for i=1, #instruction_arr_upper do
        if instruction_arr_upper[i] =='[' then
            table.insert(allOB,i)
        end
    end
    local aobl=#allOB
    if aobl==0 then return t end
	local instruction_arr_run=deepcopy(instruction_arr_upper)
	local brack={}
    
	local ptm='%s+PTR[^%[]*'
	local mtc='%[%s*[^%]]+%s*%]' -- [...]
	local mtc2='[^%[%]]+' -- [(...)]
	local pts={'BYTE'..ptm..mtc,'XMMWORD'..ptm..mtc,'YMMWORD'..ptm..mtc,'ZMMWORD'..ptm..mtc,'DQWORD'..ptm..mtc,'DWORD'..ptm..mtc,'QWORD'..ptm..mtc,'TWORD'..ptm..mtc,'OWORD'..ptm..mtc,'YWORD'..ptm..mtc,'ZWORD'..ptm..mtc,'WORD'..ptm..mtc,mtc}
	local ptsz={1,16,32,64,16,4,8,10,16,32,64,2,0}
	for i=1, #pts do
        if #brack==aobl then return t end
		local pi=pts[i]
		local sf=strPatCeption(instruction_arr_run,{pi,mtc,mtc2},instruction_arr)
		if #sf>0 then
			local sf1=sf[1]
            local sf3=sf[3]
			local sf3_3=sf3[3]
			local cpos=sf1[3]
			for j=1, #cpos do
				local cpsj=cpos[j]
                if instruction_arr_run[ cpsj ]=='[' then
                    table.insert(brack,cpsj)
                end
				instruction_arr_run[ cpsj ]=' ' -- REPLACE WITH SPACES!
			end
			table.insert(t,{  sf3[1], sf[2][1], { sf3_3[1], sf3_3[#sf3_3]},sf1[1],ptsz[i] })
		end
	end

	return t -- {  --[[ just the bracket contents (string) ]] , { --[[ full syntax "[...]" string ]] }, {start, end}, ptr size syntax, ptr size }
end

local function attach(a,c,z,s,n)
	debug_removeBreakpoint(addr)
	local tyc=type(c)
	local tyct=false
	if tyc=='table' then
		tyct=true
	end
	if ( tyct==false and (c==nil or c<=0) ) then
			print('Argument "c" must be >0, or a table')
			return
	end
	if a==nil then
		print('Argument "a" must be specified')
		return
	end
	if type(n)=='string' and n~=nil and n~='' then
		forceSave=n
	else
		forceSave=''
	end
	local tya=type(a)
	if tya=='number' then
		local addr_hx=string.format('%X',a)
		abp={{a,addr_hx}}
	elseif tya=='string' then
		local as=getAddress(a)
		local addr_hx=string.format('%X',as)
		abp={{as,addr_hx}}
	else
			abp={}
			for i=1, #a do
				if type(a[i])=='string' then
					local as=getAddress(a[i])
					table.insert(abp, {as,string.format('%X',as)} )
				else
					table.insert(abp,{a[i],string.format('%X',a[i])})
				end
			end
	end
	stopTraceEnd=false
	if z==true then
		stopTraceEnd=true
	end
	hits={}
	hits_lookup={}
	hits_deref={}
	hits_deref_lookup={}
	mem_accs_lookup={}
	mem_accs_sorted={}
	hp={}
	hpp={}
	currTraceDss={}
	present_r_last_lookup={}
	present_m_last_lookup={}
	present_mem_last_lookup={}
	mri_skip=false
	mri_isCall=true
	mrc_retAdr=nil
	
	if tyct==true then
		if type(c[2])=='number' and c[2]>=0 then
			count=c[2]
		else
			count=nil
		end
		instRep=getAddress(c[1])
	else
		instRep=nil
		count=c
	end
	
	local tys=type(s)
	
	stp=0
	sio='step into'
	if s==true then
		stp=1
		sio='step over previously run instructions'
	elseif (tys=='string' and s~='') or (tys=='table' and #s>0) then
		stp=2
		sio='step into specified modules'
		
		traceModules={}
		local lms={}
		if tys=='string' then 
			lms[s]=true
		elseif tys=='table' then
			for k=1, #s do
				lms[ s[k] ]=true
			end
		end
		
		local modulesTable= enumModules()
		for i,v in pairs(modulesTable) do
			if lms[v.Name]==true then
				local sz=getModuleSize(v.Name)
				local tm={
					['Size']=sz,
					['Name']=v.Name,
					['lastByte']=v.Address+sz-1,
					['Address']=v.Address
				}
				table.insert(traceModules,tm)
			end 
		end
	end
	
	condBpProg=false
	rw_trace=0
	prog=true
	first=true
	debug_setBreakpoint(abp[1][1], 1, bptExecute)
	midTrace=true
end

local function get_disassembly(hi,i)
	local hisx=string.format('%X',hi)
	local h=hp[hisx]

	local hdi=hits_deref[i]
	--local hdi_dss=hdi['disassembly']
	local hdi_dss_m=hdi['mem_accesses']
	local extraField = hdi_dss_m['extraField']
	local instruction = hdi_dss_m['instruction']
	local bytes = hdi_dss_m['bytes']
	local address = hdi_dss_m['address']
	local pa = hdi_dss_m['address_string']
	local prinfo_cnt = hdi_dss_m['prinfo_cnt']
	local prinfo = hdi_dss_m['prinfo']

	if i==1 or h==nil then
		h={1,hi,hisx,prinfo,pa,bytes,instruction,extraField,prinfo_cnt}
	elseif h~=nil then
		h={(h[1]+1),hi,hisx,prinfo,pa,bytes,instruction,extraField,prinfo_cnt}
	end
	hp[hisx]=h --overwritten

	return { ['order']=i, ['count']=h[1], ['address']=h[2], ['address_hex_str']=h[3], ['prinfo']=h[4], ['prinfo_cnt']=h[9], ['address_str']=h[5], ['bytes']=h[6], ['instruction']=h[7], ['extraField']=h[8] }

end

local function printHits(m,p,n,l,f,t)
	if m~=nil and (type(m)~='number' or (m<0 or m>1)) then
		print('Argument "m", if specified, must be a number between 0 and 1')
		return
	end

	if n~=nil and type(n)~='string' then
		print('Argument "n" , if specified, must be a string')
		return
	end

	local stn=currTraceDss
	if n~=nil and n~='' then
		stn=st[n]
	end

	local stnp=stn[3] -- table of disassembled addresses, sorted by count
	local stl=#stnp

	if m==1 then
		stnp=stn[7] -- table of disassembled addresses
		stl=#stnp
		if f~=nil and (type(f)~='number' or (f<1 or f>stl)) then
			print('Argument "f", if specified, must be a number between 0 and ' .. stl)
			return
		end

		if t~=nil and (type(t)~='number' or (t<1 or t>stl)) then
			print('Argument "t", if specified, must be a number between 0 and ' .. stl)
			return
		end

		if (f~=nil and t~=nil) and f>t then
			print('Argument "f" cannot be greater than argument "t"')
			return
		end


	end

	local stl=#stnp

	local pt={}

	if m==1 then
		--Print by orders
		if f==nil then
			f=1
		end

		if t==nil then
			t=stl
		end
			
		local pth=nil
		if p~=nil and p~=''  then
				pth=io.open(p,'w')
				print('Saving trace…')
		end
		
		for i=f, t do
			local stn2i=stnp[i]
			if stn2i['isJump']==true then
				table.insert(pt,'\n')
			end
			table.insert(pt,'#')
			table.insert(pt,i)
			table.insert(pt,' (')
			table.insert(pt,stn2i['count'])
			table.insert(pt, '):\t' )
			table.insert(pt,stn2i['mem_accesses']['prinfo'])
			local ptct=table.concat(pt)
			if pth~=nil then
				pth:write(ptct..'\n')
			else
				print(ptct)
			end
			pt={}
		end
		
		-- ADD MEMORY ACCESS INDEX
		local ms=stn[10] --Sorted memory accesses
		local msl=#ms --Sorted memory accesses
		
		if msl>0 then
			for s=0, msl do
				local ptct=''
				if s==0 then
					 ptct='\n\nMemory accesses index:'
				else
					local mss=ms[s]
					 ptct=string.format('[ %s ]: %s',mss.hex,table.concat(mss.ixs,', '))
				end
				if pth~=nil then
						pth:write(ptct..'\n')
				else
						print(ptct)
				end
			end
		end
		
		if pth~=nil then
				print('Trace saved!')
		end
	else
		-- Print by count
		local lm=1
		if l~=nil then
			lm=l
		end
		local stn3=stn[3] -- table of disassembled addresses, sorted by count
		local ic=1
		local stlstl=#stn3
		for i=1, stlstl do
			local stn3i=stnp[i]
			local stn3ic=stn3i['count']
			if stn3ic>=lm then
				table.insert(pt,'#')
				table.insert(pt,ic)
				table.insert(pt,' (')
				table.insert(pt,stn3ic)
				table.insert(pt, '):\t' )
				table.insert(pt,stn3i['prinfo_cnt'])
				local ptct=table.concat(pt)
				if pth~=nil then
					pth:write(ptct..'\n')
				else
					print(ptct)
				end
				pt={}
				ic=ic+1
			end
		end
		if pth~=nil then
			print('Trace saved!')
			io.close(pth)
		end
	end
end

local function doSave(n,c)
	if type(n)~='string' or n=='' then
		print('Argument "n" must be specified and be a non-empty string')
		return
	end

	if c==true then
		st[n]=currTraceCmp
		--currTraceCmp={}
		print("Comparison trace saved as '" .. n .. "'")
	elseif #currTraceDss >0 then
		st[n]=currTraceDss
		print("Current trace saved as '" .. n .. "'")
	end
end

local function save(n)
	doSave(n,false)
end

local function saveTrace()
	local ds={}
	hp={}
	local hl=#hits
	for i=1, hl do
		local d=get_disassembly(hits[i],i)
		table.insert(ds,d)
	end

	local hpp={}
	local hpp_a={}
	for i=1, #ds do
		local dsi=ds[i]
		local hxp=hpp_a[dsi['address_hex_str']]
		if hxp==nil then
			hpp_a[dsi['address_hex_str']]={dsi,dsi['order']}
		else
			hpp_a[dsi['address_hex_str']][1]=dsi
			table.insert(hpp_a[dsi['address_hex_str']],dsi['order'])
		end
	end

	for key, value in pairs(hpp_a) do
		table.insert(hpp,value[1])
	end
	
	
	mem_accs_sorted={}
	for key, value in pairs(mem_accs_lookup) do
			table.insert(mem_accs_sorted,value)
	end
	if #mem_accs_sorted>0 then
		table.sort( mem_accs_sorted, function(a, b) return a['dec'] < b['dec'] end ) -- Mem accesses table sorted (ascending);
	end
	
	table.sort( hpp, function(a, b) return a['count'] < b['count'] end ) -- Converted results array now sorted by count (ascending);
	local addr_hx=abp[1][2]
	if count==hl then
		trace_info=addr_hx .. ', ' .. count .. ' steps, ' .. sio
	else
		trace_info=addr_hx .. ', ' .. hl .. ' steps (' .. count .. ' specified),' .. sio
	end
	currTraceDss={hits, ds, hpp, trace_info, hp, hpp_a, hits_deref, hits_deref_lookup,hits_lookup,mem_accs_sorted}
end

local function runStop(b,adx)
	if trace_w[1]~=nil then
		trace_w[1].close()
	end
	midTrace=false
	if condBpProg==true then
		condBpProg=false
		if condBpAddr~= nil and #condBpAddr>0 then
			debug_removeBreakpoint(condBpAddr[1][1])
			condBpAddr={}
		end
		return
	end
	rw_trace=0
	prog=false
	liteBp=false
	if abp~= nil and #abp>0 then
			debug_removeBreakpoint(abp[1][1])
	end
	saveTrace()
	if b==true then
		print('Trace count limit reached')
	elseif b==false then
		print('Specified address ( '..adx..' ) executed!')
	else
		print('Trace ended')
	end
	if forceSave ~='' then
		save(forceSave)
	end
end

local function stop()
	runStop()
end

local function saved()
	for key, value in pairs(st) do
		print("'" .. key .. "' - " .. value[4])
	end
end

local function query(a, s, n)
	local ta={}
	local qt={}
	local typa=type(a)
	if typa=='table' then
			for i=1, #a do
				if type(a[i])=='string' then
					local as=getAddress(a[i])
					table.insert(ta, as)
				else
					table.insert(ta, a[i])
				end
			end
	elseif typa=='string' then
		ta={getAddress(a)}
	elseif typa=='number' then
		ta={a}
	end

	if n==nil then
		qt=currTraceDss
	elseif type(n)~='string' or n=='' then
		print('Argument "n", if specified, must be a non-empty string')
		return
	else
		qt=st[n]
	end
	-- qt={hits, ds, hpp, trace_info, hp, hpp_a, hits_deref, hits_deref_lookup,hits_lookup}
	if s==true then -- accesses
		for i=1, #ta do
			local res={}
			local tai=ta[i]
			local taix=string.format("%X",ta[i])
			--local h_drf=qt[7]
			local h_drf_lk=qt[8] --hits_deref_lookup
			local acs=h_drf_lk[taix]
			if acs~=nil then
				for k=1, #acs do
					table.insert(res,acs[k]['index'])
				end
			end
			if #res>0 then
				local sng='times'
				local ixs='indexes'
				local c=#res
				if c==1 then
					sng='time'
					ixs='index'
				end
				print('Address ' .. taix .. ' read/written to ' .. c .. ' ' .. sng .. ', and present at '..ixs..': ' .. table.concat(res,', '))
			else
				print('Address ' .. taix .. ' not read/written to')
			end
		end
	else -- hits
		for i=1, #ta do
			local hxa=string.format('%X',ta[i])
			local pt={}
			local rcs=qt[9][hxa]
			if rcs~=nil then
				for k=1, #rcs[2] do
					table.insert(pt,rcs[2][k])
				end
			end
			if #pt>0 then
				local sng='times'
				local ixs='indexes'
				local c=#pt
				if c==1 then
					sng='time'
					ixs='index'
				end
				print('Address ' .. hxa .. ' hit ' .. c .. ' ' .. sng .. ', and present at '..ixs..': ' .. table.concat(pt,', '))
			else
				print('Address ' .. hxa .. ' not hit')
			end
		end
	end

end

local function compare(...) -- variadic, trace names
	local args={...}
	if #args<3 then
			print("Must have at least 3 arguments")
			return
	end
	local cmpt=''
	local traces={}
	for key, value in ipairs(args) do
		if key>1 then
			local stv=st[value]
			if stv==nil then
				print("'".. value .. "' is not a saved trace name")
				return
			end
			if key==2 then
				cmpt=cmpt .. " - COMPARISON: '" .. value .. "' with:"
			elseif key==3 then
				cmpt=cmpt .. " '" .. value .. "'"
			else
				cmpt=cmpt .. " , '" .. value .. "'"
			end
			table.insert(traces,stv)
		else
			if value=='' or type(value)~='string' then
				print("First argument must be a non-empty string")
				return
			end
		end
	end

	local mts={}
	local nhp={}
	local t0a=traces[1][5] -- unique addresses
	local trc=#traces
	for i=1, #t0a do -- loop over 1st arg's addresses
		local mtc=true
		for k=2, trc do -- loop over rest of args' addresses
			local tak=traces[k][5]
				if tak[t0a[i]]==nil then
					mtc=false
					k=trc -- EARLY TERMINATE
				end
			end
			if mtc==true then -- match!
				mts[t0a[i]]=true --table of matching addresses
				table.insert(nhp,t0a[i])
			end
		end

			currTraceCmp=deepcopy(currTraceDss)
			currTraceCmp[1]={} -- hits not relevant
			currTraceCmp[5]=nhp
			currTraceCmp[4]=currTraceCmp[4] .. cmpt
			for i=2, 3 do
				local tb={}
				local tt=currTraceCmp[i]
				for k=1, #tt do
					if mts[tt[k]['address_hex_str']]==true then
						table.insert(tb,tt[k])
					end
				end
				tt=tb
			end
			doSave(args[1],true)

end

local function delete(n)

	if n==nil then
		st={}
		print("All saved traces deleted")
	elseif type(n)~='string' or n=='' then
		print('Argument "n", if specified, must be a non-empty string')
		return
	else
		st[n]=nil
		print("Saved trace '" .. n .. "' deleted")
	end
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

local function litePrint(fileName)
	local lgf=#liteFormattedCount 
	if fileName~=nil then
		local fileHdl=io.open(fileName,'w')
		print('Saving trace…')
		for i=1, lgf do
			local lfi=liteFormattedCount[i]
			fileHdl:write(liteFormattedCount[i]..'\n')
		end
		fileHdl:close()
		print('Trace saved!')
	else
		for i=1, lgf do
			local lfi=liteFormattedCount[i]
			print(lfi)
		end
	end
end

local function getLiteCounts()
	local ltl=#liteTrace
	local block_nums={}
	local byNumBlocks={}
	local countInts={}
	local cb=1
	local liteTrace_tix={}
	for i=1, ltl do
		local ti=liteTrace[i]
		local tix=string.format('%X',ti)
		table.insert(liteTrace_tix,tix)
		local isJump=false
		table.insert(block_nums,cb)
		if countInts[tix]==nil then
			countInts[tix]=1
		else
			countInts[tix]=countInts[tix]+1
		end
		if i>1 then
			local last_addr=liteTrace[i-1]
			local nextInst_addr=getInstructionSize(last_addr)+last_addr
			if ti~=nextInst_addr then
				isJump=true				
				if countInts[ liteTrace_tix[i-1] ] ~= countInts[tix] then
					cb=cb+1
					block_nums[#block_nums]=cb
				end
			end
		end

		
		if byNumBlocks[cb]==nil then
			local cnt={countInts[tix]}
			byNumBlocks[cb]={{tix},cnt,cnt,{i},{i},{ti},{isJump}}
		else
			table.insert(byNumBlocks[cb][1],tix)
			table.insert(byNumBlocks[cb][3],countInts[tix])
			table.insert(byNumBlocks[cb][4],i)
			table.insert(byNumBlocks[cb][5],i)
			table.insert(byNumBlocks[cb][6],ti)
			table.insert(byNumBlocks[cb][7],isJump)
		end
	end --eol

	local loop_run={byNumBlocks[1]} -- {{ loop_table_x, first_block_numbers, last_block_numbers, first_occ_numbers, last_occ_numbers, loop_table },...}

	for i=2, #byNumBlocks do
		local lst=loop_run[#loop_run]
		local nbi=byNumBlocks[i]
		if sameTable(lst[1],nbi[1])==true then
			loop_run[#loop_run][3]=nbi[2]
			loop_run[#loop_run][5]=nbi[4]
		else
			table.insert(loop_run,nbi)
		end
	end --eol
	
	local traceText_tbl={}
	local lrl=#loop_run
	for i=1, lrl do
		local li=loop_run[i]
		local lir=li[6]
		local lirx=li[1]
		local lic1=li[2]
		local lic2=li[3]
		local lio1=li[4]
		local lio2=li[5]
		local li7=li[7]
		for k=1, #lir do --loop over RIPs
			local cr=lir[k] --current RIP
			local tix=lirx[k]
			local dsti=disassemble(cr)
			local extraField, instruction, bytes, address=splitDisassembledString(dsti)
			
			local a = getSymbolNameFromAddress(cr,true)
			local pa=tix
			if a[1]==a[2] then
				if a[1]~=tix then
					pa=tix .. ' [ ' .. a[1] .. ' ]'
				end
			else
				if a[1]~=tix and a[2]~=tix then
					pa=tix .. string.format(' [ %s (%s) ]',a[1],a[2])
				elseif a[1]~=tix and a[2]==tix then
					pa=tix .. ' [ ' .. a[1] .. ' ]'
				elseif a[1]==tix and a[2]~=tix then
					pa=tix .. ' [ ' .. a[2] .. ' ]'
				end
			end
			
			local prinfo=string.format('%s:\t%s  -  %s', pa, bytes, instruction)

			if extraField~='' then
				prinfo=prinfo .. ' ( ' .. extraField .. ' )'
			end

			local ncs=''
			local lic1k=lic1[k]
			local lic2k=lic2[k]
			if lic1k==lic2k then
				ncs='('..lic1k..')'
			else
				ncs='('..lic1k..'-'..lic2k..')'
			end

			local ncln=''
			local lio1k=lio1[k]
			local lio2k=lio2[k]
			if lio1k==lio2k then
				ncln='#'..lio1k
			else
				ncln='#'..lio1k..' - #'..lio2k
			end

			local out_str=''
			if li7[k]==true then
					out_str='\n'
				end
			out_str=out_str..'%s %s:\t%s'
			local ostf=string.format(out_str,ncln,ncs,prinfo)
			table.insert(traceText_tbl,ostf)
		end

	end
	return traceText_tbl --return trace text
end --eof

local function jumpMemOnly(addr)
	local dst = disassemble(addr)
	local extraField, instruction, bytes, address = splitDisassembledString(dst)
	local instruction_rb=string_match(instruction,'[^%s]+%s*(.*)')
	local instruction_r=upperc(instruction_rb)
	local m=getAccessed(instruction_rb,instruction_r)
	
	for i=#m, 1, -1 do
		local mi=m[i]
		local mi1=mi[1]
		local n=tonumber(mi1,16)
		if n~=nil then
			frm.hx.address=n
			break
		end
	end

end

local function jumpMem(addr)
	debug_getContext(true)
	registers['regs']['R8G']=getSubRegDecBytes(string.format("%X", R8), 8,1,8)
	registers['regs']['R9G']=getSubRegDecBytes(string.format("%X", R9), 8,1,8)
	registers['regs']['R10G']=getSubRegDecBytes(string.format("%X", R10), 8,1,8)
	registers['regs']['R11G']=getSubRegDecBytes(string.format("%X", R11), 8,1,8)
	registers['regs']['R12G']=getSubRegDecBytes(string.format("%X", R12), 8,1,8)
	registers['regs']['R13G']=getSubRegDecBytes(string.format("%X", R13), 8,1,8)
	registers['regs']['R14G']=getSubRegDecBytes(string.format("%X", R14), 8,1,8)
	registers['regs']['R15G']=getSubRegDecBytes(string.format("%X", R15), 8,1,8)
	registers['regs']['RAX']=RAX
	registers['regs']['RBX']=RBX
	registers['regs']['RCX']=RCX
	registers['regs']['RDX']=RDX
	registers['regs']['RDI']=RDI
	registers['regs']['RSI']=RSI
	registers['regs']['RBP']=RBP
	registers['regs']['RSP']=RSP
	registers['regs']['R8']=R8
	registers['regs']['R9']=R9
	registers['regs']['R10']=R10
	registers['regs']['R11']=R11
	registers['regs']['R12']=R12
	registers['regs']['R13']=R13
	registers['regs']['R14']=R14
	registers['regs']['R15']=R15
	registers['regs']['EAX']=EAX
	registers['regs']['EBX']=EBX
	registers['regs']['ECX']=ECX
	registers['regs']['EDX']=EDX
	registers['regs']['EDI']=EDI
	registers['regs']['ESI']=ESI
	registers['regs']['EBP']=EBP
	registers['regs']['ESP']=ESP
	registers['regs']['EIP']=EIP
	registers['regs']['ESI_X']=getSubRegDecBytes(string.format("%X", ESI), 4,1,4)
	registers['regs']['EDI_X']=getSubRegDecBytes(string.format("%X", EDI), 4,1,4)
	registers['regs']['EBP_X']=getSubRegDecBytes(string.format("%X", EBP), 4,1,4)
	registers['regs']['ESP_X']=getSubRegDecBytes(string.format("%X", ESP), 4,1,4)
	registers['regs']['EIP_X']=getSubRegDecBytes(string.format("%X", EIP), 4,1,4)
	registers['regs']['EAX_X']=getSubRegDecBytes(string.format("%X", EAX), 4,1,4)
	registers['regs']['EBX_X']=getSubRegDecBytes(string.format("%X", EBX), 4,1,4)
	registers['regs']['ECX_X']=getSubRegDecBytes(string.format("%X", ECX), 4,1,4)
	registers['regs']['EDX_X']=getSubRegDecBytes(string.format("%X", EDX), 4,1,4)
	registers['regs']['FP0']=FP0
	registers['regs']['FP1']=FP1
	registers['regs']['FP2']=FP2
	registers['regs']['FP3']=FP3
	registers['regs']['FP4']=FP4
	registers['regs']['FP5']=FP5
	registers['regs']['FP6']=FP6
	registers['regs']['FP7']=FP7
	registers['regs']['XMM0']=XMM0
	registers['regs']['XMM1']=XMM1
	registers['regs']['XMM2']=XMM2
	registers['regs']['XMM3']=XMM3
	registers['regs']['XMM4']=XMM4
	registers['regs']['XMM5']=XMM5
	registers['regs']['XMM6']=XMM6
	registers['regs']['XMM7']=XMM7
	registers['regs']['XMM8']=XMM8
	registers['regs']['XMM9']=XMM9
	registers['regs']['XMM10']=XMM10
	registers['regs']['XMM11']=XMM11
	registers['regs']['XMM12']=XMM12
	registers['regs']['XMM13']=XMM13
	registers['regs']['XMM14']=XMM14
	registers['regs']['XMM15']=XMM15


	local dst = disassemble(addr)
	local extraField, instruction, bytes, address = splitDisassembledString(dst)
	
				local mn=getModuleName(addr)
			if currModule==nil then
				currRegsAddr=alloc('traceCount_registers',1024,mn)
				currModule=mn
			elseif mn~=currModule then
				dealloc('traceCount_registers')
				currRegsAddr=alloc('traceCount_registers',1024,mn)
				currModule=mn
			end
			
			local rc=0

			writeString(currRegsAddr+( rc ),'RAX')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RAX)
			rc=rc+12
			
			writeString(currRegsAddr+( rc ),'RBX')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RBX)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RBX')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RBX)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RCX')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RCX)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RDX')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RDX)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RBX')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RBX)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RBP')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RBP)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RSI')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RSI)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RDI')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RDI)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'RSP')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),RSP)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'R8')
			writeBytes(currRegsAddr+( rc+2),0,0)
			writeQword(currRegsAddr+( rc+4 ),RSI)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'R9')
			writeBytes(currRegsAddr+( rc+2),0,0)
			writeQword(currRegsAddr+( rc+4 ),R9)
			rc=rc+12
					
			writeString(currRegsAddr+( rc ),'R10')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),R10)
			rc=rc+12
					
			writeString(currRegsAddr+( rc ),'R11')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),R11)
			rc=rc+12
					
			writeString(currRegsAddr+( rc ),'R12')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),R12)
			rc=rc+12
					
			writeString(currRegsAddr+( rc ),'R13')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),R13)
			rc=rc+12
					
			writeString(currRegsAddr+( rc ),'R14')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),R14)
			rc=rc+12
					
			writeString(currRegsAddr+( rc ),'R15')
			writeBytes(currRegsAddr+( rc+3),0)
			writeQword(currRegsAddr+( rc+4 ),R15)
			rc=rc+12
						
			writeString(currRegsAddr+( rc ),'XMM0')
			writeBytes(currRegsAddr+( rc+4 ),XMM0)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM1')
			writeBytes(currRegsAddr+( rc+4 ),XMM1)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM2')
			writeBytes(currRegsAddr+( rc+4 ),XMM2)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM3')
			writeBytes(currRegsAddr+( rc+4 ),XMM3)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM4')
			writeBytes(currRegsAddr+( rc+4 ),XMM4)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM5')
			writeBytes(currRegsAddr+( rc+4 ),XMM5)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM6')
			writeBytes(currRegsAddr+( rc+4 ),XMM6)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM7')
			writeBytes(currRegsAddr+( rc+4 ),XMM7)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM8')
			writeBytes(currRegsAddr+( rc+4 ),XMM8)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM9')
			writeBytes(currRegsAddr+( rc+4 ),XMM9)
			rc=rc+20
			
			writeString(currRegsAddr+( rc ),'XMM10')
			writeBytes(currRegsAddr+( rc+5),0,0,0)
			writeBytes(currRegsAddr+( rc+8 ),XMM10)
			rc=rc+24
			
			writeString(currRegsAddr+( rc ),'XMM11')
			writeBytes(currRegsAddr+( rc+5),0,0,0)
			writeBytes(currRegsAddr+( rc+8 ),XMM11)
			rc=rc+24
			
			writeString(currRegsAddr+( rc ),'XMM12')
			writeBytes(currRegsAddr+( rc+5),0,0,0)
			writeBytes(currRegsAddr+( rc+8 ),XMM12)
			rc=rc+24
			
			writeString(currRegsAddr+( rc ),'XMM13')
			writeBytes(currRegsAddr+( rc+5),0,0,0)
			writeBytes(currRegsAddr+( rc+8 ),XMM13)
			rc=rc+24
			
			writeString(currRegsAddr+( rc ),'XMM14')
			writeBytes(currRegsAddr+( rc+5),0,0,0)
			writeBytes(currRegsAddr+( rc+8 ),XMM14)
			rc=rc+24
			
			writeString(currRegsAddr+( rc ),'XMM15')
			writeBytes(currRegsAddr+( rc+5),0,0,0)
			writeBytes(currRegsAddr+( rc+8 ),XMM15)
			rc=rc+24
			
			writeString(currRegsAddr+( rc ),'FP0')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP0)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP1')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP1)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP1')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP1)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP2')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP2)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP3')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP3)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP4')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP4)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP5')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP5)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP6')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP6)
			rc=rc+14
			
			writeString(currRegsAddr+( rc ),'FP7')
			writeBytes(currRegsAddr+( rc+3),0)
			writeBytes(currRegsAddr+( rc+4 ),FP7)
			rc=rc+14
				
local instruction_rb=string_match(instruction,'[^%s]+%s*(.*)')
local instruction_r=upperc(instruction_rb)
	local s=deepcopy(instruction_r)  -- substitute register names for their spaces
	--local sd=instruction_r -- substitute register names for their decimals
	local present_r={}
	local present_r_lookup={}
	
	for i=1, #registers['list_regs'] do
		local regs_pos={}
		if string_find(s,'%u')~=nil then
			local fnd=false
			local ri=registers['list_regs'][i][1] --check for presence of register
			local ri_fnd=ri
			local ri_alt=registers['alt_names'][ri]
			local ri_pos=str_allPosPlain(s,ri)
			if ri~=ri_alt and ri_alt~=nil then
				local ri_alt_pos=str_allPosPlain(s,ri_alt)
				if #ri_pos>0 then
					fnd=true
					regs_pos=ri_pos
				elseif  #ri_alt_pos>0 then
					fnd=true
					ri_fnd=ri_alt
					regs_pos=ri_alt_pos
				end
			else
				if #ri_pos>0 then
					fnd=true
					regs_pos=ri_pos
				end
			end
			
			if  fnd==true then
				local rgs=registers['regs'][ri]
				local arg_n=registers['regs_args'][ri]
				local rg={}
				if arg_n~=nil then
					rg=registers['get_regs'][ri](registers['regs'][arg_n])
				else
					rg['dec']=rgs
					local hxr=string.format('%X',rgs)
					rg['hex']=hxr
				end
				s=plainReplace(s,ri_fnd,string.rep(' ',string.len(ri_fnd)))
				table.insert(present_r,{ri_fnd,rg,regs_pos,ri})
				present_r_lookup[ri_fnd]={#present_r,rg,regs_pos}
			end
		else
			break
		end
	end
		local prl=#present_r
		local asc_nr=getAccessed(s) -- get memory "[...]" syntax matches with spaces in place of registers
		--local asc_d=getAccessed(sd) -- get memory "[...]" syntax matches in decimal
		local asc=getAccessed(instruction_rb,instruction_r) -- get memory "[...]" syntax matches
		local ascl=#asc
		ja=ascl
		jb=1
		jc=-1
		if jmpFirst==true then
			local ja=1
			local jb=ascl
			local jc=1
		end
		local memJmp=false
		for i=ja, jb, jc do
			local ai=asc_nr[i]
			local sa=string_arr(s)
			local c=1
			local mtc_hex="%x+"
			local brk=false
			while brk==false do
				  local fa,fb=string_find(s,mtc_hex,c)
				  if fa~=nil then
					 sa[fa]='0x'..sa[fa]
					 c=fb+1
				  else
					  brk=true
				  end
			end
			
			local ai3=ai[3]  -- pos of syntax
			local ai3_1, ai3_2=ai3[1], ai3[2]
			
			for k=1, prl do --reintroduce decimal registers
				rk=present_r[k]
				local rkd=rk[2]['dec']
				local rk3=rk[3]
				local rk3l=#rk3
				if rkd~=nil and #rk3>0 then	
				for m=1, rk3l do
						rk3_1=rk3[m][1]
						rk3_2=rk3[m][2]
						if rk3_1>=ai3_1 and rk3_2<=ai3_2 then
							sa[ rk3_1 ]=rkd
								for j=rk3_1+1, rk3_2 do
									sa[j]=''
								end
						end
					end
				end
			end

			local a_dec=get_substring_tbl(sa,ai3_1,ai3_2)
			local func= load("return ".. a_dec)
			local b,r=pcall(func) -- r=calculated address

			if r~=nil and type(r)=='number' and math.tointeger (r)~=nil then
                frm.hx.address=r
				memJmp=true
				break
			end
		end

		if memJmp==false then
			frm.hx.address=currRegsAddr
		end
		return
end

local function setupWindow(c) -- c is remaining steps
	if trace_w[1]~=nil then
	 trace_w[1].close()
	end

	trace_w[1] = createForm()
	trace_w[1].Width = 334
	trace_w[1].Height =40
	trace_w[1].Position = 'poScreenCenter'
	trace_w[1].Color = '0x000000'
	trace_w[1].Caption = 'traceCount progress'
	trace_w[1].FormStyle = 'fsMDIForm'
	trace_w[1].DefaultMonitor = 'dmMainForm'
	trace_w[1].BorderStyle = 'bsSingle'

	trace_w[1].onClose=function()
		trace_w[2].destroy()
		trace_w[2]=nil
		trace_w[1].destroy()
		trace_w[1]=nil
	end

	trace_w[2]=createLabel(trace_w[1])
	trace_w[2].Left = 2
	trace_w[2].Top = 0
	trace_w[2].Font.size=17
	trace_w[2].Font.Color='0xffffff'
	trace_w[2].Color='0x000000'
	trace_w[2].Caption=spaceSep_int(c)..' '..s_pluralise(c,'step')..' remaining'
end

local function onLiteBp()

	debug_getContext()
	local ai1=0
	local ai1_hx=''
		if liteAbp[1]~=nil then
			ai1=liteAbp[1][1]
			ai1_hx=liteAbp[1][2]
		end
		if #liteAbp>1 and RIP==ai1 then
			print('Breakpoint at ' .. ai1_hx .. ' hit!')
			debug_removeBreakpoint(ai1)
			table.remove(liteAbp,1)
			debug_setBreakpoint(liteAbp[1][1], 1, bptExecute)
			debug_continueFromBreakpoint(co_run)
		else
				if liteFirst==true then
					if RIP==ai1 then
						debug_removeBreakpoint(ai1)
						liteFirst=false
						print('Breakpoint at ' .. ai1_hx .. ' hit!')
						if liteCount~=nil then
							setupWindow(liteCount)
						end
					else
						if debug_isBroken()==true then
							jumpMem(RIP)
						end
						return
					end
				end
				
				liteTrace[liteIx]=RIP

					if liteStepOver==2 then
						local RIPx=string.format("%X", RIP)
						if liteTrace_lookup[RIPx]==nil then
									local dss = disassemble(RIP)
									local extraField, instruction, bytes, address = splitDisassembledString(dss)
									local la,lb=string_find( instruction,"^%s*rep[^%s]*%s+")
									liteTrace_lookup[RIPx]={true,instruction,la}
						else --seen before
							if liteTrace_lookup[RIPx][3]==nil then
										liteForceStepOver=true
							end
						end
					end

				if liteCount~=nil then
					local ct1=liteCount-liteIx
					trace_w[2].Caption=spaceSep_int(ct1)..' '..s_pluralise(ct1,'step')..' remaining'
				end

				liteIx=liteIx+1

				local rpt=false
				if (liteRep~=nil and RIP==liteRep and liteIx>2) then
					rpt=true
				end
				
				local cnt_done=false
					if liteCount~=nil and liteIx>liteCount then
						cnt_done=true
					end
				
				if ( cnt_done==true or rpt==true ) then -- End of trace!
										liteBp=false
										midTrace=false
										if rpt==true then
											print('Specified address ( '..string.format('%X',RIP)..' ) executed!\n')
										else
											print('Trace count limit reached!\n')
										end
										if trace_w[1]~=nil then
											trace_w[1].close()
										end
										liteFormattedCount=getLiteCounts()
										if lite_stopTraceEnd==true then
											return 1
										else
											debug_continueFromBreakpoint(co_run) --END OF TRACE!
										end
				elseif liteStepOver==1 then --Step over
							if cnt_done==true then
								liteFormattedCount=getLiteCounts()
								if lite_stopTraceEnd==true then
									return 1
								else
									debug_continueFromBreakpoint(co_run) --END OF TRACE!
								end
							else
								debug_continueFromBreakpoint(co_stepover)
							end
				else --step into
							if cnt_done==true then
								liteFormattedCount=getLiteCounts()
								if lite_stopTraceEnd==true then
									return 1
								else
									debug_continueFromBreakpoint(co_run) --END OF TRACE!
								end
							else
									if liteForceStepOver==true then
										liteForceStepOver=false
										debug_continueFromBreakpoint(co_stepover)
									else
										debug_continueFromBreakpoint(co_stepinto)
									end
							end
				end
				
		end
end

local function lite(a,c,s,z)
	debug_removeBreakpoint(liteAddr)
	liteBp=false
	midTrace=false
	local tyc=type(c)
	local tyct=false
	if tyc=='table' then
		tyct=true
	end
	if ( tyct==false and (c==nil or c<=0) ) then
			print('Argument "c" must be >0, or a table')
			return
	end
	if a==nil then
		print('Argument "a" must be specified')
		return
	end

	local tya=type(a)
	if tya=='number' then
		local addr_hx=string.format('%X',a)
		liteAbp={{a,addr_hx}}
	elseif tya=='string' then
		local as=getAddress(a)
		local addr_hx=string.format('%X',as)
		liteAbp={{as,addr_hx}}
	else
			liteAbp={}
			for i=1, #a do
				if type(a[i])=='string' then
					local as=getAddress(a[i])
					table.insert(liteAbp, {as,string.format('%X',as)} )
				else
					table.insert(liteAbp,{a[i],string.format('%X',a[i])})
				end
			end
	end
	
	liteIx=1
	if tyct==true then
		if type(c[2])=='number' and c[2]>=0 then
			liteCount=c[2]
		else
			liteCount=nil
		end
		liteRep=getAddress(c[1])
	else
		liteRep=nil
		liteCount=c
	end
	
	lite_stopTraceEnd=false
	if z==true then
		lite_stopTraceEnd=true
	end
	liteBp=true
	liteFirst=true
	mri_skip=false
	mri_isCall=true
	mrc_retAdr=nil
	liteStepOver=0
	if s==1 or s==2 then
		liteStepOver=s
	end
	liteForceStepOver=false
	liteTrace={}
	liteTrace_lookup={}
	liteFormattedCount={}
	
	debug_setBreakpoint(liteAbp[1][1], 1, bptExecute)
	midTrace=true
end

local function onBp_rw_proc(addr)
				if abp[1]~=nil then
					ai1=abp[1][1]
					ai1_hx=abp[1][2]
				end
				
				debug_removeBreakpoint(ai1)
				print(ai1_hx .. ' accessed!')
				first=false
				--count=count-1
				setupWindow(count)
				trace_w[2].Caption=spaceSep_int(count)..' '..s_pluralise(count,'step')..' remaining'		

					table.insert(hits,addr)

					local ix=#hits
					local RIPx=string.format('%X',addr)
					local hit_no=1
					local hlk=hits_lookup[RIPx]
					local dst = disassemble(addr)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					local la,lb=string_find( instruction,"^%s*rep[^%s]*%s+")
					hits_lookup[RIPx]={hit_no,{ix},la}

					local deref={['hit_address']=RIPx}
					
				if stp==2 then
						mri_isCall=false
						if string_find(instruction,'^%s*call%s+')~=nil then
							mri_isCall=true
						end
				end

					--Get accessed memory addresses

					-- EXTRA SUB-REGISTERS

					local instruction_rb=string_match(instruction,'[^%s]+%s*(.*)')
					local instruction_r=upperc(instruction_rb)

					local s=instruction_r  -- substitute register names for their spaces
					
					for i=1, #registers['list_regs'] do
						local regs_pos={}
						if string_find(s,'%u')~=nil then
							local fnd=false
							local lri=registers['list_regs'][i] --check for presence of register
							local ri=lri[1] --check for presence of register
							local ri_fnd=ri
							local ri_alt=registers['alt_names'][ri]
							local ri_pos=str_allPosPlain(s,ri)
							if ri~=ri_alt and ri_alt~=nil then
								local ri_alt_pos=str_allPosPlain(s,ri_alt)
								if #ri_pos>0 then
									fnd=true
									regs_pos=ri_pos
								elseif  #ri_alt_pos>0 then
									fnd=true
									ri_fnd=ri_alt
									regs_pos=ri_alt_pos
								end
							else
								if #ri_pos>0 then
									fnd=true
									regs_pos=ri_pos
								end
							end
							
							if  fnd==true then
								s=plainReplace(s,ri_fnd,string.rep(' ',string.len(ri_fnd)))
								present_r_last_lookup[ ri_fnd ]={ri_fnd,rg,regs_pos,ri,true}
							end
						else
							break
						end
					end

								local m_acc={}
								
								local a = getSymbolNameFromAddress(addr,true)
								local pa=RIPx
								if a[1]==a[2] then
									if a[1]~=RIPx then
										pa=RIPx .. ' [ ' .. a[1] .. ' ]'
									end
								else
									if a[1]~=RIPx and a[2]~=RIPx then
										pa=RIPx .. string.format(' [ %s (%s) ]',a[1],a[2])
									elseif a[1]~=RIPx and a[2]==RIPx then
										pa=RIPx .. ' [ ' .. a[1] .. ' ]'
									elseif a[1]==RIPx and a[2]~=RIPx then
										pa=RIPx .. ' [ ' .. a[2] .. ' ]'
									end
								end

								local prinfo=string.format('%s:\t%s  -  %s', pa, bytes, instruction)

								local prinfo_cnt=deepcopy(prinfo)

								if extraField~='' then
									prinfo=prinfo .. ' ( ' .. extraField .. ' )'
								end
								m_acc['extraField']=extraField
								m_acc['instruction']=instruction
								m_acc['bytes']=bytes
								m_acc['address']=address
								m_acc['prinfo']=prinfo
								m_acc['prinfo_cnt']=prinfo_cnt
								m_acc['present_regs']=present_r
								
					deref['mem_accesses']=m_acc --List of accessed memory addresses; table of tables
					deref['dec_address']=addr
					deref['isJump']=false

					hits_deref[ix]=deref -- hits_deref is a table of tables (full local scope)
					deref['index']=ix

					hits_deref[ix]['count']=hit_no
end

local function onBp()

	debug_getContext(true)
	registers['regs']['R8G']=getSubRegDecBytes(string.format("%X", R8), 8,1,8)
	registers['regs']['R9G']=getSubRegDecBytes(string.format("%X", R9), 8,1,8)
	registers['regs']['R10G']=getSubRegDecBytes(string.format("%X", R10), 8,1,8)
	registers['regs']['R11G']=getSubRegDecBytes(string.format("%X", R11), 8,1,8)
	registers['regs']['R12G']=getSubRegDecBytes(string.format("%X", R12), 8,1,8)
	registers['regs']['R13G']=getSubRegDecBytes(string.format("%X", R13), 8,1,8)
	registers['regs']['R14G']=getSubRegDecBytes(string.format("%X", R14), 8,1,8)
	registers['regs']['R15G']=getSubRegDecBytes(string.format("%X", R15), 8,1,8)
	registers['regs']['RAX']=RAX
	registers['regs']['RBX']=RBX
	registers['regs']['RCX']=RCX
	registers['regs']['RDX']=RDX
	registers['regs']['RDI']=RDI
	registers['regs']['RSI']=RSI
	registers['regs']['RBP']=RBP
	registers['regs']['RSP']=RSP
	registers['regs']['R8']=R8
	registers['regs']['R9']=R9
	registers['regs']['R10']=R10
	registers['regs']['R11']=R11
	registers['regs']['R12']=R12
	registers['regs']['R13']=R13
	registers['regs']['R14']=R14
	registers['regs']['R15']=R15
	registers['regs']['RIP']=RIP
	registers['regs']['EAX']=EAX
	registers['regs']['EBX']=EBX
	registers['regs']['ECX']=ECX
	registers['regs']['EDX']=EDX
	registers['regs']['EDI']=EDI
	registers['regs']['ESI']=ESI
	registers['regs']['EBP']=EBP
	registers['regs']['ESP']=ESP
	registers['regs']['EIP']=EIP
	registers['regs']['ESI_X']=getSubRegDecBytes(string.format("%X", ESI), 4,1,4)
	registers['regs']['EDI_X']=getSubRegDecBytes(string.format("%X", EDI), 4,1,4)
	registers['regs']['EBP_X']=getSubRegDecBytes(string.format("%X", EBP), 4,1,4)
	registers['regs']['ESP_X']=getSubRegDecBytes(string.format("%X", ESP), 4,1,4)
	registers['regs']['EIP_X']=getSubRegDecBytes(string.format("%X", EIP), 4,1,4)
	registers['regs']['EAX_X']=getSubRegDecBytes(string.format("%X", EAX), 4,1,4)
	registers['regs']['EBX_X']=getSubRegDecBytes(string.format("%X", EBX), 4,1,4)
	registers['regs']['ECX_X']=getSubRegDecBytes(string.format("%X", ECX), 4,1,4)
	registers['regs']['EDX_X']=getSubRegDecBytes(string.format("%X", EDX), 4,1,4)
	registers['regs']['FP0']=FP0
	registers['regs']['FP1']=FP1
	registers['regs']['FP2']=FP2
	registers['regs']['FP3']=FP3
	registers['regs']['FP4']=FP4
	registers['regs']['FP5']=FP5
	registers['regs']['FP6']=FP6
	registers['regs']['FP7']=FP7
	registers['regs']['XMM0']=XMM0
	registers['regs']['XMM1']=XMM1
	registers['regs']['XMM2']=XMM2
	registers['regs']['XMM3']=XMM3
	registers['regs']['XMM4']=XMM4
	registers['regs']['XMM5']=XMM5
	registers['regs']['XMM6']=XMM6
	registers['regs']['XMM7']=XMM7
	registers['regs']['XMM8']=XMM8
	registers['regs']['XMM9']=XMM9
	registers['regs']['XMM10']=XMM10
	registers['regs']['XMM11']=XMM11
	registers['regs']['XMM12']=XMM12
	registers['regs']['XMM13']=XMM13
	registers['regs']['XMM14']=XMM14
	registers['regs']['XMM15']=XMM15
	
	local alreadyRun=false
	local ai1=0
	local ai1_hx=''
		if abp[1]~=nil then
			ai1=abp[1][1]
			ai1_hx=abp[1][2]
		end
		if #abp>1 and RIP==ai1 then
			print('Breakpoint at ' .. ai1_hx .. ' hit!')
			debug_removeBreakpoint(ai1)
			table.remove(abp,1)
			debug_setBreakpoint(abp[1][1], 1, bptExecute)
			debug_continueFromBreakpoint(co_run)
		else

				local runToRet=false
				local rpt=false
				local endTrace=false
				
				if first==true then
					if RIP==ai1 then
						debug_removeBreakpoint(ai1)
						first=false
						print('Breakpoint at ' .. ai1_hx .. ' hit!')
						if count~=nil then
							setupWindow(count-1)
						end
					else
						if debug_isBroken()==true then
							jumpMem(RIP)
						end
						return
					end
				else
					if (instRep~=nil and RIP==instRep) then
						rpt=true
					end
				end
				
			
			if count~=nil then
				count=count-1
				trace_w[2].Caption=spaceSep_int(count)..' '..s_pluralise(count,'step')..' remaining'		
				local cnt_done=false
					if count<1 then
						cnt_done=true
					end
					
					if rpt==true or cnt_done==true then
						endTrace=true
					end
				--if count>=0 then
					table.insert(hits,RIP)

					local ix=#hits
					local RIPx=string.format('%X',RIP)
					local hit_no=1
					local hlk=hits_lookup[RIPx]
					local dst = disassemble(RIP)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					if  hlk~= nil then
						if hlk[3]==nil then
							alreadyRun=true
						end
						hit_no=hlk[1]+1
						hlk[1]=hit_no
						table.insert(hits_lookup[RIPx][2],ix)
					else --nil
						local la,lb=string_find( instruction,"^%s*rep[^%s]*%s+")
						hits_lookup[RIPx]={hit_no,{ix},la}
					end

					local deref={['hit_address']=RIPx}
						
					if stp==2 then
						if mri_skip==true then
							debug_removeBreakpoint(mrc_retAdr)
							mri_skip=false
						end
						
						if mri_isCall==true then
							local outOfModules=true
								for j=1, #traceModules do
									local jm=traceModules[j]
									if RIP>=jm.Address and RIP<=jm.lastByte then
										outOfModules=false
										break
									end
								end
								
							if outOfModules==true then
								mrc_retAdr=readQword(RSP)
								runToRet=true
								mri_skip=true
								if endTrace==false then
									debug_setBreakpoint(mrc_retAdr, 1, bptExecute)
								end
								
							else
								mrc_retAdr=nil
								mri_skip=false
							end
						end
						
						mri_isCall=false
						if string_find(instruction,'^%s*call%s+')~=nil then
							mri_isCall=true
						end
				end
					
					--deref['disassembly']={instruction,address,bytes,extraField}
					--Get accessed memory addresses

					-- EXTRA SUB-REGISTERS

					local instruction_rb=string_match(instruction,'[^%s]+%s*(.*)')
					local instruction_r=upperc(instruction_rb)
					
					local s=deepcopy(instruction_r)  -- substitute register names for their spaces
					--local sd=instruction_r -- substitute register names for their decimals
					local present_r={}
					local present_r_lookup={}
					local maxRegSize=0
					for i=1, #registers['list_regs'] do
						local regs_pos={}
						if string_find(s,'%u')~=nil then
							local fnd=false
							local lri=registers['list_regs'][i] --check for presence of register
							local ri=lri[1] --check for presence of register
							local ri_fnd=ri
							local ri_alt=registers['alt_names'][ri]
							local ri_pos=str_allPosPlain(s,ri)
							if ri~=ri_alt and ri_alt~=nil then
								local ri_alt_pos=str_allPosPlain(s,ri_alt)
								if #ri_pos>0 then
									fnd=true
									regs_pos=ri_pos
								elseif  #ri_alt_pos>0 then
									fnd=true
									ri_fnd=ri_alt
									regs_pos=ri_alt_pos
								end
							else
								if #ri_pos>0 then
									fnd=true
									regs_pos=ri_pos
								end
							end
							
							if  fnd==true then
								local rgs=registers['regs'][ri]
								local arg_n=registers['regs_args'][ri]
								local mxr=lri[2]
								if mxr>maxRegSize then
									maxRegSize=mxr
								end
								local rg={}
								if arg_n~=nil then
									rg=registers['get_regs'][ri](registers['regs'][arg_n])
								else
									rg['dec']=rgs
									local hx=string.format('%X',rgs)								
									rg['hex']=hx
									rg['aob']=hexToAOB(hx)
								end
								s=plainReplace(s,ri_fnd,string.rep(' ',string.len(ri_fnd)))
								--[[if rg['dec']~=nil then
									sd=plainReplace(sd,ri_fnd,rg['dec'])
								end]]
								if rg['aob']~=nil then
									rg['aob_str']=table.concat(rg['aob'],' ')
								end
								table.insert(present_r,{ri_fnd,rg,regs_pos,ri})
								present_r_lookup[ri_fnd]={#present_r,rg,regs_pos}
							end
						else
							break
						end
					end
                    
                    if string_find(instruction_r,'ZMM%d+')~=nil and maxRegSize<64 then
                        maxRegSize=64
                    elseif string_find(instruction_r,'YMM%d+')~=nil and maxRegSize<32 then
                        maxRegSize=32
                    end
					
										local og_present_r=deepcopy(present_r)
					
					for key, value in pairs(present_r_last_lookup) do
						local rwt=false
						if value[5]==true then
							rwt=true
						end
						if present_r_lookup[key] == nil then
								local insrt=true
								local ri=value[4]
								local rgs=registers['regs'][ri]
								local arg_n=registers['regs_args'][ri]
								local rg={}
								if arg_n~=nil then
									rg=registers['get_regs'][ri](registers['regs'][arg_n])
								else
									rg['dec']=rgs
									local hx=string.format('%X',rgs)
									rg['hex']=hx
									rg['aob']=hexToAOB(hx)
								end
							if rg['aob']~=nil then
									rg['aob_str']=table.concat(rg['aob'],' ')
									if rwt==false and rg['aob_str']==value[2]['aob_str'] then
										insrt=false
									end
							end
							if insrt==true then
								table.insert(present_r,{value[1],rg,value[3],ri})
							end
						end
					end
						
					present_r_last_lookup={}

					local prl=#present_r
					
					for k=1, #og_present_r do --reintroduce decimal registers
						rk=og_present_r[k]
						present_r_last_lookup[ rk[1] ]=rk
					end

					local present_mem={}
					local present_mem_lookup={}
					
					local asc_nr=getAccessed(s) -- get memory "[...]" syntax matches with spaces in place of registers
					--local asc_d=getAccessed(sd) -- get memory "[...]" syntax matches in decimal
					local asc=getAccessed(instruction_rb,instruction_r) -- get memory "[...]" syntax matches
					local m_acc={}
					local reffed_instruction=instruction
					local accessed_addrs={}
					local maxPtrSize=0
					
					for i=1, #asc do -- get max ptr size
							local bz=asc[i][5]
							if bz>maxPtrSize then
								maxPtrSize=bz
							end
					end
					
					for i=1, #asc do
						local ai=asc_nr[i]
						local ais=asc[i]
						local sa=string_arr(s)
						local c=1
						local mtc_hex="%x+"
						local brk=false

						while brk==false do
							  local fa,fb=string_find(s,mtc_hex,c)
							  if fa~=nil then
								 sa[fa]='0x'..sa[fa]
								 c=fb+1
							  else
								  brk=true
							  end
						end
						
						local ai3=ai[3]  -- pos of syntax
						local ai3_1, ai3_2=ai3[1], ai3[2]
						
						for k=1, prl do --reintroduce decimal registers
							rk=present_r[k]
							local rkd=rk[2]['dec']
							local rk3=rk[3]
							local rk3l=#rk3
							if rkd~=nil and #rk3>0 then	
							for m=1, rk3l do
									rk3_1=rk3[m][1]
									rk3_2=rk3[m][2]
									if rk3_1>=ai3_1 and rk3_2<=ai3_2 then
										sa[ rk3_1 ]=rkd
											for j=rk3_1+1, rk3_2 do
												sa[j]=''
											end
									end
								end
							end
						end
				
						local a_dec=get_substring_tbl(sa,ai3_1,ai3_2)
						local func= load("return ".. a_dec)
						local b,r=pcall(func) -- r=calculated address

						if r~=nil and type(r)=='number' and math.tointeger (r)~=nil then				
							local rx=string.format('%X',r)
							table.insert(accessed_addrs,rx)
							local bz=ais[5]
							if bz==0 then -- No attached size
								if maxRegSize==0 then
									if maxPtrSize==0 then
										bz=1 -- No attached size, no max register size, no max ptr size
									else
										bz=maxPtrSize -- No attached size, no max register size, a max ptr size
									end
								else -- No attached size, a max register size
									bz=maxRegSize
								end
							end
							local byt=readBytes(r,bz,true)
							if byt~=nil then
								local raat={rx,r,bz,byt} -- {hex address, decmal address, ptr size, byte table}
								present_mem_lookup[rx]=raat
								table.insert(present_mem,raat)
								for x=r, r+bz-1 do
									local rxa=rx
									if x~=r then
										rxa=string.format('%X',x)
									end
									if mem_accs_lookup[rxa]==nil then
										local tml={}
										tml.dec=x
										tml.hex=rxa
										tml.ixs={string.format('#%d',ix)}
										mem_accs_lookup[rxa]=tml
									else
										table.insert(mem_accs_lookup[rxa].ixs,string.format('#%d',ix))
									end
								end
							end
							local fstx=asc[i][2]
							local brkt=asc[i][1]
							-- [2]= { --[[ full syntax "[...]" ]] }

								if brkt~=rx then
									local rep_with='[ '..brkt..' ('..rx..') ]'
									reffed_instruction=plainReplace(reffed_instruction,fstx,rep_with)
								else
									local rep_with='[ '..brkt..' ]'
									reffed_instruction=plainReplace(reffed_instruction,fstx,rep_with)
								end
						end
					end
					local og_present_mem=deepcopy(present_mem)
					
					for key, value in pairs(present_mem_last_lookup) do
						if present_mem_lookup[key] == nil then			
								local insrt=true
								local rd=value[2]
								local bzm=value[3]
								local byt=readBytes(rd,bzm,true)
								if byt~=nil then
									if sameTable(value[4],byt)==true then
										insrt=false
									end
								end
							
								if insrt==true then
									table.insert(present_mem,{key,rd,bzm,byt}) -- {hex address, decmal address, ptr size, (new) byte table}
									
									for x=rd, rd+bzm-1 do
										local rxa=key
										if x~=rd then
											rxa=string.format('%X',x)
										end
										if mem_accs_lookup[rxa]==nil then
											local tml={}
											tml.dec=x
											tml.hex=rxa
											tml.ixs={string.format('#%d',ix)}
											mem_accs_lookup[rxa]=tml
										else
											table.insert(mem_accs_lookup[rxa].ixs,string.format('#%d',ix))
										end
									end
									
								end
						end
					end
					present_mem_last_lookup={}

					local prm=#present_mem
					
					for k=1, #og_present_mem do
						mk=og_present_mem[k]
						present_mem_last_lookup[ mk[1] ]=mk
					end
					
								local a = getSymbolNameFromAddress(RIP,true)
								local pa=RIPx
								if a[1]==a[2] then
									if a[1]~=RIPx then
										pa=RIPx .. ' [ ' .. a[1] .. ' ]'
									end
								else
									if a[1]~=RIPx and a[2]~=RIPx then
										pa=RIPx .. string.format(' [ %s (%s) ]',a[1],a[2])
									elseif a[1]~=RIPx and a[2]==RIPx then
										pa=RIPx .. ' [ ' .. a[1] .. ' ]'
									elseif a[1]==RIPx and a[2]~=RIPx then
										pa=RIPx .. ' [ ' .. a[2] .. ' ]'
									end
								end

								local prinfo=string.format('%s:\t%s  -  %s', pa, bytes, reffed_instruction)
								local regs_mem_tbl={}

								if prl>0 then
									for i=1, prl do
										local pi=present_r[i]
										local dsp=''
										if registers['disp_aob'][pi[1]]~=nil then
											dsp=' = {'..pi[2]['aob_str']..'}'
										else
											dsp='='..pi[2]['hex']
										end
										table.insert(regs_mem_tbl,pi[1]..dsp)
									end
								end

								if prm>0 then
									for i=1, prm do
										local pi=present_mem[i]
										local aoby= table.concat(tableToAOB(pi[4])['aob'],' ')
										local dsp=string.format('[%s] = {%s}',pi[1],aoby)
										table.insert(regs_mem_tbl,dsp)
									end
								end

								if #regs_mem_tbl>0 then
									local regs_str=table.concat(regs_mem_tbl,', ')
									prinfo=prinfo..'\t( '..regs_str..' )'
								end
								
								local prinfo_cnt=string.format('%s:\t%s  -  %s', pa, bytes, instruction)

								if extraField~='' then
									prinfo=prinfo .. ' ( ' .. extraField .. ' )'
								end
								m_acc['extraField']=extraField
								m_acc['instruction']=instruction
								m_acc['bytes']=bytes
								m_acc['address']=address
								m_acc['prinfo']=prinfo
								m_acc['prinfo_cnt']=prinfo_cnt
								m_acc['present_regs']=present_r

					deref['mem_accesses']=m_acc --List of accessed memory addresses; table of tables
					deref['dec_address']=RIP
					deref['isJump']=false

					if ix>1 then
						local last_addr=hits[ix-1]
						local nextInst_addr=getInstructionSize(last_addr)+last_addr
						if RIP~=nextInst_addr then
							deref['isJump']=true
						end
					end
					
					hits_deref[ix]=deref -- hits_deref is a table of tables (full local scope)
					deref['index']=ix
					local cnt=1
					for j=1, #accessed_addrs do
						local aj=accessed_addrs[j]
						if hits_deref_lookup[ aj ]==nil then
							hits_deref_lookup[ aj ] = {deref} --table of tables { {} }
						else
							table.insert( hits_deref_lookup[ aj ] , deref) -- { {}, {}, ... }
							cnt=#hits_deref_lookup[ aj ]
						end
					end
					hits_deref[ix]['count']=hit_no
					
					local ended=false

					if rpt==false then
						if cnt_done==true then
							runStop(true)
							ended=true
							if stopTraceEnd==true then
								return 1
							else
								debug_continueFromBreakpoint(co_run) --END OF TRACE!
							end
						elseif runToRet==true then
								if stopTraceEnd==true then
									return 1
								else
									debug_continueFromBreakpoint(co_run) --END OF TRACE!
								end
						elseif stp==1 then
							if cnt_done==false then
								if alreadyRun==true then
									debug_continueFromBreakpoint(co_stepover)
								else
									debug_continueFromBreakpoint(co_stepinto)
								end
							end
						else
							if cnt_done==false then
								debug_continueFromBreakpoint(co_stepinto)
							end
						end
					elseif endTrace==true and ended==false then -- End of trace!
						if stopTraceEnd~=true then
							debug_continueFromBreakpoint(co_run) --END OF TRACE!
						end
						if rpt==true then
							runStop(false,string.format('%X',instRep))
						else
							runStop(true)
						end	
						if stopTraceEnd==true then
							return 1
						end
				end
				end
	end
end

local function attach_rw(a,c,w,z,s,n)
	
	local tya=type(a)
	local ad
	rw_lookup={0,{}}
	
	if tya=='table' and #a>1 then
		ad=getAddress(a[1])
		for i=2, #a do
			local ai=a[i]
			local aid=getAddress(ai)
			local sz=getInstructionSize(aid)
			local szx=string.format('%X',aid+sz)
			rw_lookup[2][szx]=aid
			rw_lookup[1]=rw_lookup[1]+1
		end
	elseif tya=='string' or tya=='number' then
		ad=getAddress(a)
	else
		print('Argument "a" must be an address or a table containing >=2 addresses')
		return
	end
	
	if type(c)~='number' or c<=0 then
			print('Argument "c" must be >0')
			return
	end
	
	if type(n)=='string' and n~=nil and n~='' then
		forceSave=n
	else
		forceSave=''
	end
	
	stopTraceEnd=false
	if z==true then
		stopTraceEnd=true
	end
	
	abp={}
	hits={}
	hits_lookup={}
	hits_deref={}
	hits_deref_lookup={}
	mem_accs_lookup={}
	mem_accs_sorted={}
	hp={}
	hpp={}
	currTraceDss={}
	present_r_last_lookup={}
	present_m_last_lookup={}
	present_mem_last_lookup={}
	mri_skip=false
	mri_isCall=true
	mrc_retAdr=nil
	
	instRep=nil
	count=c
	
		local tys=type(s)
	
	stp=0
	sio='step into'
	if s==true then
		stp=1
		sio='step over previously run instructions'
	elseif (tys=='string' and s~='') or (tys=='table' and #s>0) then
		stp=2
		sio='step into specified modules'
		
		traceModules={}
		local lms={}
		if tys=='string' then 
			lms[s]=true
		elseif tys=='table' then
			for k=1, #s do
				lms[ s[k] ]=true
			end
		end
		
		local modulesTable= enumModules()
		for i,v in pairs(modulesTable) do
			if lms[v.Name]==true then
				local sz=getModuleSize(v.Name)
				local tm={
					['Size']=sz,
					['Name']=v.Name,
					['lastByte']=v.Address+sz-1,
					['Address']=v.Address
				}
				table.insert(traceModules,tm)
			end 
		end
	end
	
	condBpProg=false
	prog=false
	rw_trace=2
	first=true
	midTrace=true
	
	local trg=bptAccess
	
	if w==true then
		trg=bptWrite
	end
	
	abp={{ad,string.format('%X',ad)}}
	
	debug_setBreakpoint(ad,1,trg,bpmInt3,function()
			debug_getContext()

		local RIPx=string.format('%X',RIP)
		local validAddr=rw_lookup[2][RIPx]
		if rw_lookup[1]>0 then
			validAddr=rw_lookup[2][RIPx]
		else
			validAddr=getPreviousOpcode(RIP)
		end
		
		if validAddr==nil then
			debug_continueFromBreakpoint(co_run)
		else --store data from previous instruction
			onBp_rw_proc(validAddr)
			onBp()
			rw_trace=1
		end
	end)
end

local function condBp(a, c, s, bf)
	local tc={['str']={},['num']={},['opc']={},['bf']=nil}
		
	if type(bf)=='number' then
		if bf<0 then
			print('bf, if specified, must be >=0!')
			return
		end
		tc.bf=bf
	end

	local ta={}
	local typa=type(a)
	if typa=='table' then
			for i=1, #a do
				if type(a[i])=='string' then
					local as=getAddress(a[i])
					table.insert(ta, {as,string.format('%X',as)})
				else
					table.insert(ta, {a[i], string.format('%X',a[i])})
				end
			end
	elseif typa=='string' then
		local as=getAddress(a)
		ta={{as,string.format('%X',as)}}
	elseif typa=='number' then
		ta={{a,string.format('%X',a)}}
	end
	condBpAddr=ta
		
	local typc=type(c)
	if typc=='table' then
			for i=1, #c do
				local ci=c[i]
				local tyci=type(ci)
				if tyci=='string' then
					local cs=upperc(space_fix(ci))
					table.insert(tc.str, cs)
				elseif tyci=='table' then
					for j=1, #ci do
						table.insert(tc.opc, ci[j])
					end
				elseif tyci=='number' then
					table.insert(tc.num, ci)
				end
			end
	elseif typc=='string' then
		tc.str={upperc(space_fix(c))}
	elseif typc=='number' then
		tc.num={c}
	end
	condBpVals=tc

	mri_skipCond=false
	mri_isCallCond=true
	mrc_retAdrCond=nil
	
	local tys=type(s)
	condTraceModules={}
	if tys=='table' or (tys=='string' and s~='') then
		local lms={}
		if tys=='table' then 
			for k=1, #s do
				lms[ s[k] ]=true
			end
		else
			lms[s]=true
		end
	
		local modulesTable=enumModules()
		for i,v in pairs(modulesTable) do
			if lms[v.Name]==true then
				local sz=getModuleSize(v.Name)
				local tm={
					['Size']=sz,
					['Name']=v.Name,
					['lastByte']=v.Address+sz-1,
					['Address']=v.Address
				}
				table.insert(condTraceModules,tm)
			end 
		end
	end
	
	first=true
	present_r_last_lookup={}
	present_mem_last_lookup={}
	present_m_last_lookup={}
	condBpProg=true
	rw_trace=0
	debug_setBreakpoint(condBpAddr[1][1], 1, bptExecute)
	midTrace=true
end

local function onCondBp()

	debug_getContext(true)
	registers['regs']['R8G']=getSubRegDecBytes(string.format("%X", R8), 8,1,8)
	registers['regs']['R9G']=getSubRegDecBytes(string.format("%X", R9), 8,1,8)
	registers['regs']['R10G']=getSubRegDecBytes(string.format("%X", R10), 8,1,8)
	registers['regs']['R11G']=getSubRegDecBytes(string.format("%X", R11), 8,1,8)
	registers['regs']['R12G']=getSubRegDecBytes(string.format("%X", R12), 8,1,8)
	registers['regs']['R13G']=getSubRegDecBytes(string.format("%X", R13), 8,1,8)
	registers['regs']['R14G']=getSubRegDecBytes(string.format("%X", R14), 8,1,8)
	registers['regs']['R15G']=getSubRegDecBytes(string.format("%X", R15), 8,1,8)
	registers['regs']['RAX']=RAX
	registers['regs']['RBX']=RBX
	registers['regs']['RCX']=RCX
	registers['regs']['RDX']=RDX
	registers['regs']['RDI']=RDI
	registers['regs']['RSI']=RSI
	registers['regs']['RBP']=RBP
	registers['regs']['RSP']=RSP
	registers['regs']['R8']=R8
	registers['regs']['R9']=R9
	registers['regs']['R10']=R10
	registers['regs']['R11']=R11
	registers['regs']['R12']=R12
	registers['regs']['R13']=R13
	registers['regs']['R14']=R14
	registers['regs']['R15']=R15
	registers['regs']['EAX']=EAX
	registers['regs']['EBX']=EBX
	registers['regs']['ECX']=ECX
	registers['regs']['EDX']=EDX
	registers['regs']['EDI']=EDI
	registers['regs']['ESI']=ESI
	registers['regs']['EBP']=EBP
	registers['regs']['ESP']=ESP
	registers['regs']['EIP']=EIP
	registers['regs']['ESI_X']=getSubRegDecBytes(string.format("%X", ESI), 4,1,4)
	registers['regs']['EDI_X']=getSubRegDecBytes(string.format("%X", EDI), 4,1,4)
	registers['regs']['EBP_X']=getSubRegDecBytes(string.format("%X", EBP), 4,1,4)
	registers['regs']['ESP_X']=getSubRegDecBytes(string.format("%X", ESP), 4,1,4)
	registers['regs']['EIP_X']=getSubRegDecBytes(string.format("%X", EIP), 4,1,4)
	registers['regs']['EAX_X']=getSubRegDecBytes(string.format("%X", EAX), 4,1,4)
	registers['regs']['EBX_X']=getSubRegDecBytes(string.format("%X", EBX), 4,1,4)
	registers['regs']['ECX_X']=getSubRegDecBytes(string.format("%X", ECX), 4,1,4)
	registers['regs']['EDX_X']=getSubRegDecBytes(string.format("%X", EDX), 4,1,4)
	registers['regs']['FP0']=FP0
	registers['regs']['FP1']=FP1
	registers['regs']['FP2']=FP2
	registers['regs']['FP3']=FP3
	registers['regs']['FP4']=FP4
	registers['regs']['FP5']=FP5
	registers['regs']['FP6']=FP6
	registers['regs']['FP7']=FP7
	registers['regs']['XMM0']=XMM0
	registers['regs']['XMM1']=XMM1
	registers['regs']['XMM2']=XMM2
	registers['regs']['XMM3']=XMM3
	registers['regs']['XMM4']=XMM4
	registers['regs']['XMM5']=XMM5
	registers['regs']['XMM6']=XMM6
	registers['regs']['XMM7']=XMM7
	registers['regs']['XMM8']=XMM8
	registers['regs']['XMM9']=XMM9
	registers['regs']['XMM10']=XMM10
	registers['regs']['XMM11']=XMM11
	registers['regs']['XMM12']=XMM12
	registers['regs']['XMM13']=XMM13
	registers['regs']['XMM14']=XMM14
	registers['regs']['XMM15']=XMM15

	local ai1=0
	local ai1_hx=''
		if condBpAddr[1]~=nil then
			ai1=condBpAddr[1][1]
			ai1_hx=condBpAddr[1][2]
		end
		if #condBpAddr>1 and RIP==ai1 then
			print('Breakpoint at ' .. ai1_hx .. ' hit!')
			debug_removeBreakpoint(ai1)
			table.remove(condBpAddr,1)
			debug_setBreakpoint(condBpAddr[1][1], 1, bptExecute)
			debug_continueFromBreakpoint(co_run)
		else
				if first ==true then
					debug_removeBreakpoint(ai1)
					condBpAddr={}
					first=false
					print('Breakpoint at ' .. ai1_hx .. ' hit!')
				end
	end
	local breakHere={false,''}
	local RIPx=string.format('%X',RIP)
	local dst = disassemble(RIP)
	local extraField, instruction, bytes, address = splitDisassembledString(dst)
	
					local cvp=#condBpVals.opc
					if cvp>0 then
						for k=1, cvp do
							local pk=condBpVals.opc[k]
							if string_find(instruction,pk)~=nil then
								breakHere={true, 'Instruction pattern match'}
								break
							end		
						end
					end
	
		-- EXTRA SUB-REGISTERS
	local instruction_rb=string_match(instruction,'[^%s]+%s*(.*)')
	local instruction_r=upperc(instruction_rb)
	
	local s=deepcopy(instruction_r)  -- substitute register names for their spaces
	--local sd=instruction_r -- substitute register names for their decimals
	local present_r={}
	local present_r_lookup={}
	local maxRegSize=0
	
	for i=1, #registers['list_regs'] do
		local regs_pos={}
		if string_find(s,'%u')~=nil then
			local fnd=false
			lri=registers['list_regs'][i] --check for presence of register
			local ri=lri[1]
			local ri_fnd=ri
			local ri_alt=registers['alt_names'][ri]
			local ri_pos=str_allPosPlain(s,ri)
			if ri~=ri_alt and ri_alt~=nil then
				local ri_alt_pos=str_allPosPlain(s,ri_alt)
				if #ri_pos>0 then
					fnd=true
					regs_pos=ri_pos
				elseif  #ri_alt_pos>0 then
					fnd=true
					ri_fnd=ri_alt
					regs_pos=ri_alt_pos
				end
			else
				if #ri_pos>0 then
					fnd=true
					regs_pos=ri_pos
				end
			end
			
			if  fnd==true then
				local rgs=registers['regs'][ri]
				local arg_n=registers['regs_args'][ri]
				local mxr=lri[2]
				if mxr>maxRegSize then
					maxRegSize=mxr
				end
				local rg={}
				if arg_n~=nil then
					rg=registers['get_regs'][ri](registers['regs'][arg_n])
				else
					rg['dec']=rgs
					local hx=string.format('%X',rgs)
					rg['hex']=hx
					rg['aob']=hexToAOB(hx)
				end
				s=plainReplace(s,ri_fnd,string.rep(' ',string.len(ri_fnd)))
				--[[if rg['dec']~=nil then
					sd=plainReplace(sd,ri_fnd,rg['dec'])
				end]]
				if rg['aob']~=nil then
					rg['aob_str']=table.concat(rg['aob'],' ')
				end
				table.insert(present_r,{ri_fnd,rg,regs_pos,ri})
				present_r_lookup[ri_fnd]={#present_r,rg,regs_pos}
			end
		else
			break
		end
	end
	
    if string_find(instruction_r,'ZMM%d+')~=nil and maxRegSize<64 then
        maxRegSize=64
    elseif string_find(instruction_r,'YMM%d+')~=nil and maxRegSize<32 then
        maxRegSize=32
    end
    
    
	local og_present_r=deepcopy(present_r)

	for key, value in pairs(present_r_last_lookup) do
		if present_r_lookup[key] == nil then
				local insrt=true
				local ri=value[4]
				local rgs=registers['regs'][ri]
				local arg_n=registers['regs_args'][ri]
				local rg={}
				if arg_n~=nil then
					rg=registers['get_regs'][ri](registers['regs'][arg_n])
				else
					rg['dec']=rgs
					
					if breakHere[1]~=true then
						local cvn=#condBpVals.num
						if cvn>0 then
							for k=1, cvn do
								local vk=condBpVals.num[k]
								if rgs==vk then
									breakHere={true, 'Number match in register ('..ri..')'}
									break
								end		
							end
						end
					end
					
					local hx=string.format('%X',rgs)
					rg['hex']=hx
					rg['aob']=hexToAOB(hx)
				end
			if rg['aob']~=nil then
					rg['aob_str']=table.concat(rg['aob'],' ')
					if breakHere[1]~=true then
						local cvs=#condBpVals.str
						if cvs>0 then
							for k=1, cvs do
								local vk=condBpVals.str[k]
								if string_find(rg['aob_str'],vk,1,true)~=nil then
									breakHere={true, 'AOB match in register ('..ri..')'}
									break
								end		
							end
						end
					end
					if rg['aob_str']==value[2]['aob_str'] then
						insrt=false
					end
			end
			if insrt==true then
				table.insert(present_r,{value[1],rg,value[3],ri})
			end
		end
	end
	
	present_r_last_lookup={}
	
	local prl=#present_r
	
	for k=1, #og_present_r do --reintroduce decimal registers
		rk=og_present_r[k]
		present_r_last_lookup[ rk[1] ]=rk
	end
	
	local chkMem={}
	local chkMem_last={}
	for key, value in pairs(present_m_last_lookup) do
		chkMem[key]=value
		chkMem_last[key]=value
	end
	
	present_m_last_lookup={}

		--print('HIT!')
		local asc_nr=getAccessed(s) -- get memory "[...]" syntax matches with spaces in place of registers
		--local asc_d=getAccessed(sd) -- get memory "[...]" syntax matches in decimal
		local asc=getAccessed(instruction_rb,instruction_r) -- get memory "[...]" syntax matches
		local reffed_instruction=instruction
		
		local maxPtrSize=0

		for i=1, #asc do -- get max ptr size
				local bz=asc[i][5]
				if bz>maxPtrSize then
					maxPtrSize=bz
				end
		end

		for i=1, #asc do
			local ai=asc_nr[i]
			local ais=asc[i]
			local sa=string_arr(s)
			local c=1
			local mtc_hex="%x+"
			local brk=false
			while brk==false do
				  local fa,fb=string_find(s,mtc_hex,c)
				  if fa~=nil then
					 sa[fa]='0x'..sa[fa]
					 c=fb+1
				  else
					  brk=true
				  end
			end
			
			local ai3=ai[3]  -- pos of syntax
			local ai3_1, ai3_2=ai3[1], ai3[2]
			
			for k=1, prl do --reintroduce decimal registers
				rk=present_r[k]
				local rkd=rk[2]['dec']
				local rk3=rk[3]
				local rk3l=#rk3
				if rkd~=nil and #rk3>0 then	
				for m=1, rk3l do
						rk3_1=rk3[m][1]
						rk3_2=rk3[m][2]
						if rk3_1>=ai3_1 and rk3_2<=ai3_2 then
							sa[ rk3_1 ]=rkd
								for j=rk3_1+1, rk3_2 do
									sa[j]=''
								end
						end
					end
				end
			end

			local a_dec=get_substring_tbl(sa,ai3_1,ai3_2)
			local func= load("return ".. a_dec)
			local b,r=pcall(func) -- r=calculated address

			if r~=nil and type(r)=='number' and math.tointeger (r)~=nil then				
				local rx=string.format('%X',r)
				local bz=ais[5]
				if bz==0 then -- No attached size
					if maxRegSize==0 then
						if maxPtrSize==0 then
							bz=1 -- No attached size, no max register size, no max ptr size
						else
							bz=maxPtrSize -- No attached size, no max register size, a max ptr size
						end
					else -- No attached size, a max register size
						bz=maxRegSize
					end
				end
				local og_bz=bz
				local adr=r
				if condBpVals.bf~=nil then
					adr=adr-condBpVals.bf -- origin address
					if adr<0 then
						adr=0
					end
					bz=math.max(bz,condBpVals.bf) -- no. of bytes to read
					local upl=adr+bz-1
					bz=upl-adr+1
				end

				local byt=readBytes(adr,bz,true)	
				local bytn=readBytes(r,og_bz,true)	
				local tb={r,rx,nil,nil}
				
				if byt~=nil then
								local aobt={}
								local bytl=#byt
								for j=1, bytl do
									table.insert(aobt,string.format('%X',byt[j]))
								end
								local aob=table.concat(aobt, ' ')
								chk=true
								tb[4]=aob
				end
				
					if bytn~=nil then
								local bytln=#bytn
								local aobt_le={}
								for j=bytln, 1, -1 do
									table.insert(aobt_le,string.format('%X',bytn[j]))
								end
						
								local dec = tonumber(table.concat(aobt_le, ''),16)
								chk=true
								tb[3]=dec
					end
							
				
				present_m_last_lookup[rx]=tb -- all present addresses added
				chkMem[rx]=tb
				local fstx=asc[i][2]
				local brkt=asc[i][1]
				-- [2]= { --[[ full syntax "[...]" ]] }
				if brkt~=rx then
					local rep_with='[ '..brkt..' ('..rx..') ]'
					reffed_instruction=plainReplace(reffed_instruction,fstx,rep_with)
				else
					local rep_with='[ '..brkt..' ]'
					reffed_instruction=plainReplace(reffed_instruction,fstx,rep_with)
				end
			end
		end

if breakHere[1]~=true then
	for key, v in pairs(chkMem) do
		if breakHere[1]==true then
			break
		end
		if v[3]~=nil then
				local cvn=#condBpVals.num
					if cvn>0 then
						for k=1, cvn do
							local vk=condBpVals.num[k]
							if v[3]==vk then
								if chkMem_last[key]~=nil then
									if chkMem_last[key][3]~=v[3] then
										breakHere={true, 'Number match at memory address'}
										break
									end
								else
									breakHere={true, 'Number match at memory address'}
									break
								end
							end		
						end
					end
		end
		
		if v[4]~=nil then
					local cvs=#condBpVals.str
					if cvs>0 then
						local ja=cvs
						local jb=1
						local jc=-1
					if jmpFirst==true then
						ja=1
						jb=cvs
						jc=1
					end
					
						for k=ja, jb, jc do
							local vk=condBpVals.str[k]
							if string_find(v[4],vk,1,true)~=nil then
							if chkMem_last[key]~=nil then
								if chkMem_last[key][4]~=v[4] then
									breakHere={true, 'AOB match at memory address',v[5]}
									break
								end
							else
								breakHere={true, 'AOB match at memory address',v[5]}
								break
							end
							end	
						end
					end
		end
	end
end


					if breakHere[1]==true then
						local a = getSymbolNameFromAddress(address,true)
						local pa=RIPx
						if a[1]==a[2] then
							if a[1]~=RIPx then
								pa=RIPx .. ' [ ' .. a[1] .. ' ]'
							end
						else
							if a[1]~=RIPx and a[2]~=RIPx then
								pa=RIPx .. string.format(' [ %s (%s) ]',a[1],a[2])
							elseif a[1]~=RIPx and a[2]==RIPx then
								pa=RIPx .. ' [ ' .. a[1] .. ' ]'
							elseif a[1]==RIPx and a[2]~=RIPx then
								pa=RIPx .. ' [ ' .. a[2] .. ' ]'
							end
						end

						local prinfo=string.format('%s:\t%s  -  %s', pa, bytes, reffed_instruction)		
						if prl>0 then
							local regs_tbl={}
							for i=1, prl do
								local pi=present_r[i]
								local dsp=''
								if registers['disp_aob'][pi[1]]~=nil then
									dsp=' = {'..pi[2]['aob_str']..'}'
								else
									dsp='='..pi[2]['hex']
								end
								table.insert(regs_tbl,pi[1]..dsp)
							end
							local regs_str=table.concat(regs_tbl,', ')
							prinfo=prinfo..'\t( '..regs_str..' )'
						end

						if extraField~='' then
							prinfo=prinfo .. ' ( ' .. extraField .. ' )'
						end
						prinfo=prinfo ..'\t〈 '..breakHere[2]..' 〉'
						print(prinfo)
						
						if breakHere[3]~=nil then
							getMemoryViewForm().HexadecimalView.address=breakHere[3]
						end
						return 1
					else
						debug_continueFromBreakpoint(co_stepinto)
					end
		
end

local function findWrite(n,aobs,m,b,f,p)

	debug_getContext()
	if type(aobs)=='string' then
		findWriteAobs={aobs}
	else
		findWriteAobs=aobs
	end
	
	if m=='' or m==nil then
		findWriteModules=nil
	else
		findWriteModules={}
		if type(m)=='string' then
			findWriteModules[m]=true
		else
			for i=1, #m do
				findWriteModules[ m[i] ]=true
			end
		end
	end
	
	findWriteWasPatt=false
	if p~=nil then
		findWritePatts={}
	elseif type(p)=='string' then
		findWritePatts={p}
	else
		findWritePatts=p
	end
	
	modulesList_findWrite={}
	local modulesTable= enumModules()
	for i,v in pairs(modulesTable) do
		local inc=false
		if findWriteModules==nil or findWriteModules[v.Name]~=nil then
			inc=true
		end
		local sz=getModuleSize(v.Name)
			local tm={
				['Size']=sz,
				['Name']=v.Name,
				['lastByte']=v.Address+sz-1,
				['Address']=v.Address,
				['Included']=inc
			}
		table.insert(modulesList_findWrite,tm)
	end
	
	if n==0 then --probe stack
	
		findWriteStackBps={}
		local RIPx=string.format('%X',RIP)
		local bps=debug_getBreakpointList()
		local bpl=#bps
		if bpl>0 then
			for i=1, bpl do
				debug_removeBreakpoint(bps[i])
			end
		end
		lastAddr_findWrite={RIP,isInModule(RIP,RIPx,modulesList_findWrite)[2]}
		local bp=nil
		findWriteAttached={}
		findWriteToAttach={}
		findWriteLookup={}
		findWriteLookup_step={}
		if b==nil or b<0 then
			bp=math.max(RBP-7,RSP)
		else
			if f==true then
				bp=RSP+b
			else
				bp=math.max(math.min(RSP+b,RBP-7),RSP)
			end
		end
		local stackBPs={'findWriteStack(…) breakpoints:'}
		for i=RSP, bp do
			local rd=readQword(i)
			if type(rd)=='number' and rd>=0 then
				local dx=string.format('%X',rd)
				local isRet=isInModule(rd,dx,modulesList_findWrite)
				local lst=getPreviousOpcode(rd)
				local dst = disassemble(lst)
				local extraField, instruction, bytes, address = splitDisassembledString(dst)
				if isRet[1]==true and findWriteLookup[dx]==nil and string_find(instruction,"^%s*call%s+")~=nil then
					table.insert(findWriteToAttach,rd)
					findWriteLookup[dx]=#findWriteToAttach
					table.insert(stackBPs,string.format("\t'%s'",isRet[2]))
				end
			end
		end
		
		if #findWriteToAttach>1 then
			local lst=math.max(1,math.min(4,#findWriteToAttach))
			findWriteStackBps={1,lst}
			setupFWstack()
		end
		
		print(table.concat(stackBPs,'\n')..'\n')
	else --step into/over (2)
		findWriteLastWasCall=false
		local bn=b
		if type(b)=='string' then
			bn=getAddress(b)
		end
		local fn=f
		if type(f)=='string' then
			fn=getAddress(f)
		end
		findWriteStart=bn
		findWriteEnd=fn
		findWriteStepOver=n
		lastAddr_findWrite={bn,isInModule(bn,string.format('%X',bn),modulesList_findWrite)[2]}
		debug_setBreakpoint(bn,1,bptExecute)
		findWriteBp=true
		midTrace=true
	end
end

local function findWriteStack(aobs,m,b,f) --(n,aobs,m,b,f,p)
	 findWrite(0,aobs,m,b,f,nil)
end

local function findWriteStep(i,aobs,b,f,p,m) --(n,aobs,m,b,f,p)
	local stp=2 --into
	-- internal: 3->into but over if already executed/2->into/1->over
						-- external-> internal: 0->2,1->1, 2->3
	if i==1 then
		stp=1 --over
	elseif i==2 then
		stp=3 --into but over if already executed
	end
	 findWrite(stp,aobs,m,b,f,p)
end

local function isMidTrace()
	return midTrace
end

local function end_fw()
	findWriteBp=false
	midTrace=false
	for j=1, #findWriteAttached do
		local aj=findWriteAttached[j]
		if aj~=nil then
			debug_removeBreakpoint(aj)
		end
	end
end

local function onFindWriteBp()
	debug_getContext()
	if RIP==findWriteStart then
		debug_removeBreakpoint(RIP)
	end
	
	if RIP==findWriteEnd then
		debug_continueFromBreakpoint(co_run)
		print('findWrite reached end!')
		return
	end
	
	local RIPx=string.format('%X',RIP)
	
	local isRet
	local isPatt
	local isCall
	local modCurr
	local isRep
	local ft=false
	if findWriteLookup_step[RIPx]==nil then --1st time
						ft=true
						modCurr=isInModule(RIP,RIPx,modulesList_findWrite)
						--print(modCurr[2])
						local ds = disassemble(RIP)
						local extraField, instruction, bytes, address = splitDisassembledString(ds)
						isRet=false
						isPatt=false
						isCall=false
						isRep=false
						
						if string_find(instruction,"%s+ret%s*$")~=nil or string_find(instruction,"^%s*ret%s*$")~=nil then
							isRet=true
						end
						
						if string_find(instruction,"^%s*call%s+")~=nil then
							isCall=true
						end
						
						local la,lb=string_find( instruction,"^%s*rep[^%s]*%s+")
						if la~=nil then
							isRep=true
						end
						
						if findWritePatts~=nil then
							local pl=#findWritePatts
							if pl>0 then
								for i=1,pl do
									if string_find(instruction,findWritePatts[i])~=nil then
										isPatt=true
										break
									end
								end
							end
						end
						findWriteLookup_step[RIPx]={modCurr,instruction,isRet,isPatt,isCall,isRep}
	end

	if ft==false then
		local rx=findWriteLookup_step[RIPx]
		modCurr=rx[1]
		isRet=rx[3]
		isPatt=rx[4]
		isCall=rx[5]
		if rx[6]==true then
			ft=true
		end
	end
	
	--local writeFound=false
	local scanHere=false
	if modCurr[1]==true then
		if findWriteStepOver==2 or ( findWriteStepOver==3  and ft==true) then --into
			if findWriteLastWasCall==true or isRet==true or isPatt==true or findWriteWasPatt==true then
				scanHere=true
			end
		else -- step over
			if isCall==true or isRet==true or isPatt==true or findWriteWasPatt==true then
				scanHere=true
			end
		end
	end
	
	if scanHere==true then
		for i=1, #findWriteAobs do
			local ai=findWriteAobs[i]
			local res=AOBScan(ai,"",0)
			if res~=nil then
				local rCnt= res.Count
				local rCnt_1= rCnt-1
				local resLookup={}
				if rCnt>0 then
					for w=0, rCnt_1 do 
						local rw=res[w]
						resLookup[rw]=true
					end
					for k,v in pairs(findWriteAlreadyStep) do
						if resLookup[k]~=true then
							findWriteAlreadyStep[k]=nil
						end
					end
					for w=0, rCnt_1 do 
						local rw=res[w]
						if findWriteAlreadyStep[rw]~=true then
							print( string.format("'%s' was written to memory between: '%s' and '%s' at %s",ai,lastAddr_findWrite[2],modCurr[2],res[w]))
							findWriteAlreadyStep[rw]=true
						end
					end
					--[[writeFound=true
					findWriteBp=false
					midTrace=false
					break]] -- keep going until user ends it!
				else
					lastAddr_findWrite={RIP,modCurr[2]}
				end
				res.destroy()
			end
		end
	end
	
	if isCall==true then
		findWriteLastWasCall=true
	else
		findWriteLastWasCall=false
	end
	
	if isPatt==true then
		findWriteWasPatt=true
	else
		findWriteWasPatt=false
	end

	--[[if writeFound==true then
		debug_continueFromBreakpoint(co_run)
	else]]if findWriteStepOver==2 or (findWriteStepOver==3 and ft==true) then --into
		debug_continueFromBreakpoint(co_stepinto)
	else -- step over
		debug_continueFromBreakpoint(co_stepover)
	end

end

frm.hv.OnSelectionChange=function (sender, address, address2)
	if debug_isBroken()==true then
		jumpMem(address)
	else
		jumpMemOnly(address)
	end
end

function onOpenProcess(processid)
	if currModule~=nil then
		dealloc('traceCount_registers')
		currModule=nil
	end
end

function debugger_onBreakpoint()
	if rw_trace==2 then
		return
	elseif rw_trace==1 then
		onBp()
	elseif findWriteBp==true then
		onFindWriteBp()
	elseif liteBp==true then
		onLiteBp()
	elseif prog==false and condBpProg==false then
		if debug_isBroken()==true then
			jumpMem(RIP)
		end
	elseif condBpProg==true then
		onCondBp()
	elseif prog==true then
		onBp()
	end
end

traceCount={}
traceCount.isMidTrace=isMidTrace
traceCount.attach=attach
traceCount.attach_rw=attach_rw
traceCount.stop=stop
traceCount.printHits=printHits
traceCount.save=save
traceCount.saved=saved
traceCount.compare=compare
traceCount.delete=delete
traceCount.query=query
traceCount.condBp=condBp
traceCount.lite=lite
traceCount.litePrint=litePrint
traceCount.findWriteStack=findWriteStack
traceCount.findWriteStep=findWriteStep
traceCount.end_fw=end_fw