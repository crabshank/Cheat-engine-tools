local print=print
local upperc=string.upper
local string_gmatch=string.gmatch
local string_match=string.match

local condBpProg=false
local condBpAddr={}
local condBpVals={['str']={},['num']={},['opc']={}}
local condBp_bk=0
local condBp_fw=0

local present_r_last_lookup={}
local present_m_last_lookup={}
local currModule=nil
local currRegsAddr=nil
local jmpFirst=false

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
      if address>=v.Address and address<=(v.Address+size) then
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
		  local fa,fb=string.find(s,p,c,true)
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

	for i=b*2, a*2, -2 do
	   out=string.sub(out1,i-1,i) .. out
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
	'XMM10',
	'XMM11',
	'XMM12',
	'XMM13',
	'XMM14',
	'XMM15',
	'XMM0',
	'XMM1',
	'XMM2',
	'XMM3',
	'XMM4',
	'XMM5',
	'XMM6',
	'XMM7',
	'XMM8',
	'XMM9',
	'R10D',
	'R10W',
	'R10B',
	'R11D',
	'R11W',
	'R11B',
	'R12D',
	'R12W',
	'R12B',
	'R13D',
	'R13W',
	'R13B',
	'R14D',
	'R14W',
	'R14B',
	'R15D',
	'R15W',
	'R15B',
	'RAX',
	'RBX',
	'RCX',
	'RDX',
	'RDI',
	'RSI',
	'RBP',
	'RSP',
	'R10',
	'R11',
	'R12',
	'R13',
	'R14',
	'R15',
	'EAX',
	'EBX',
	'ECX',
	'EDX',
	'EDI',
	'ESI',
	'EBP',
	'ESP',
	'EIP',
	'FP0',
	'FP1',
	'FP2',
	'FP3',
	'FP4',
	'FP5',
	'FP6',
	'FP7',
	'R8D',
	'R8W',
	'R8B',
	'R9D',
	'R9W',
	'R9B',
	'SIL',
	'DIL',
	'BPL',
	'SPL',
	'R8',
	'R9',
	'AX',
	'AL',
	'AH',
	'BX',
	'BL',
	'BH',
	'CX',
	'CL',
	'CH',
	'DX',
	'DL',
	'DH',
	'SI',
	'DI',
	'BP',
	'SP',
	'IP',
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
	['SIL']='ESI',
	['DIL']='EDI',
	['BPL']='EBP',
	['SPL']='ESP',
	['IP']='EIP',
	['AX']='EAX',
	['AL']='EAX',
	['AH']='EAX',
	['BX']='EBX',
	['BL']='EBX',
	['BH']='EBX',
	['CX']='ECX',
	['CL']='ECX',
	['CH']='ECX',
	['DX']='EDX',
	['DL']='EDX',
	['DH']='EDX',
	['SI']='ESI',
	['DI']='EDI',
	['BP']='EBP',
	['SP']='ESP',
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

registers['get_regs']['SIL']=function(ESI)
	return getSubRegDecBytes(ESI,4,4,4,true)
end

registers['get_regs']['DIL']=function(EDI)
	return getSubRegDecBytes(EDI,4,4,4,true)
end

registers['get_regs']['BPL']=function(EBP)
	return getSubRegDecBytes(EBP,4,4,4,true)
end

registers['get_regs']['SPL']=function(ESP)
	return getSubRegDecBytes(ESP,4,4,4,true)
end

registers['get_regs']['AX']=function(EAX)
	return getSubRegDecBytes(EAX,4,3,4,true)
end

registers['get_regs']['AL']=function(EAX)
	return getSubRegDecBytes(EAX,4,4,4,true)
end

registers['get_regs']['AH']=function(EAX)
	return getSubRegDecBytes(EAX,4,3,3,true)
end

registers['get_regs']['BX']=function(EBX)
	return getSubRegDecBytes(EBX,4,3,4,true)
end

registers['get_regs']['BL']=function(EBX)
	return getSubRegDecBytes(EBX,4,4,4,true)
end

registers['get_regs']['BH']=function(EBX)
	return getSubRegDecBytes(EBX,4,3,3,true)
end

registers['get_regs']['CX']=function(ECX)
	return getSubRegDecBytes(ECX,4,3,4,true)
end

registers['get_regs']['CL']=function(ECX)
	return getSubRegDecBytes(ECX,4,4,4,true)
end

registers['get_regs']['CH']=function(ECX)
	return getSubRegDecBytes(ECX,4,3,3,true)
end

registers['get_regs']['DX']=function(EDX)
	return getSubRegDecBytes(EDX,4,3,4,true)
end

registers['get_regs']['DL']=function(EDX)
	return getSubRegDecBytes(EDX,4,4,4,true)
end

registers['get_regs']['DH']=function(EDX)
	return getSubRegDecBytes(EDX,4,3,3,true)
end

registers['get_regs']['SI']=function(ESI)
	return getSubRegDecBytes(ESI,4,3,4,true)
end

registers['get_regs']['DI']=function(EDI)
	return getSubRegDecBytes(EDI,4,3,4,true)
end

registers['get_regs']['BP']=function(EBP)
	return getSubRegDecBytes(EBP,4,3,4,true)
end

registers['get_regs']['SP']=function(ESP)
	return getSubRegDecBytes(ESP,4,3,4,true)
end

registers['get_regs']['IP']=function(EIP)
	return getSubRegDecBytes(EIP,4,4,4,true)
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
		local la, lb=string.find(v, "\n")
		if la==nil then
			print(formatting .. '"'.. v ..'"')
		else
			print(formatting .. '[['.. v ..']]')
		end
	  elseif typv == 'function' then
		print(formatting .. 'function () … end')
	  else
		print(formatting .. v)
	  end
	end
  end
  do_tprint(tbl,indent)
  print('\n')
end

local count=0
local hits={}
local hits_lookup={}
local hits_deref={}
local hits_deref_lookup={}
local currTraceDss={}
local st={}
local hp={}
local prog=false
local first=false
local abp={}
local hpp={}
local stp=false
local trace_info=''
local forceSave=''
local sio=''

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
	local sp_start, sp_end = string.find(str, ptrn, strt_pos,true)

	while sp_start do
		local sa=string.sub(str, strt_pos, sp_start-1)
		if sa~='' then
			table.insert( out, sa )
		end
		table.insert( out, string.sub(str, sp_start, sp_end) )
		strt_pos = sp_end + 1
		sp_start, sp_end = string.find(str, ptrn, strt_pos,true)
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

local function getAccessed(instruction)
	local t={}
	local instruction_arr=string_arr(instruction)
	
	local mtc="%[%s*[^%]]+%s*%]" -- [...]
	local mtc2="%[%s*([^%]]+)%s*%]" -- [(...)]

	local c=1
	local brk=false
	while brk==false do
		  local fa,fb=string.find(instruction,mtc,c)
		  if fa~=nil then
			local curr=get_substring_tbl(instruction_arr, fa, fb)
			local og_fa=fa
			local og_fb=fb
			fa,fb=string.find(curr,mtc2,1)
			 if fa~=nil then
				local l_fa, l_fb=og_fa+1, og_fb-1
				local a=string_match(curr,mtc2)
				table.insert(t,{ a, curr, { l_fa, l_fb} })
				c=og_fb+1
			end
		  else
			  brk=true
		  end
	end

	return t -- { { --[[ just the bracket contents ]] }, { --[[ full syntax "[...]" ]] }, {start, end} }
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

local function attach(a,c,n,s)
	debug_removeBreakpoint(addr)
	if c==nil or c<0 then
		print('Argument "c" must be >=0')
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
	hits={}
	hits_lookup={}
	hits_deref={}
	hits_deref_lookup={}
	hp={}
	hpp={}
	currTraceDss={}
	present_r_last_lookup={}
	present_m_last_lookup={}
	count=c
	stp=s
	sio='step into'
	if s==true then
		sio='step over'
	end
	condBpProg=false
	prog=true
	first=true
	debug_setBreakpoint(abp[1][1], 1, bptExecute)
end

local function get_disassembly(hi,i)
	local hisx=string.format('%X',hi)
	local h=hp[hisx]

	local hdi=hits_deref[i]
	local hdi_dss=hdi['disassembly']
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

local function printHits(m,n,l,f,t)
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

		for i=f, t do
			local stn2i=stnp[i]
			table.insert(pt,'#')
			table.insert(pt,i)
			table.insert(pt,' (')
			table.insert(pt,stn2i['count'])
			table.insert(pt, '):\t' )
			table.insert(pt,stn2i['mem_accesses']['prinfo'])
			print(table.concat(pt))
			pt={}
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
				print(table.concat(pt))
				pt={}
				ic=ic+1
			end
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

	table.sort( hpp, function(a, b) return a['count'] < b['count'] end ) -- Converted results array now sorted by count (ascending);
	local addr_hx=abp[1][2]
	if count==hl then
		trace_info=addr_hx .. ', ' .. count .. ' steps, ' .. sio
	else
		trace_info=addr_hx .. ', ' .. hl .. ' steps (' .. count .. ' specified),' .. sio
	end
	currTraceDss={hits, ds, hpp, trace_info, hp, hpp_a, hits_deref, hits_deref_lookup,hits_lookup}
end

local function runStop(b)
	condBpProg=false
	prog=false
	if abp~= nil and #abp>1 then
			debug_removeBreakpoint(abp[1][1])
	end
	saveTrace()
	if b==true then
		print('Trace count limit reached')
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
				if first ==true then
					debug_removeBreakpoint(ai1)
					first=false
					print('Breakpoint at ' .. ai1_hx .. ' hit!')
				end

				count=count-1

				if count>=0 then
					table.insert(hits,RIP)

					local ix=#hits
					local RIPx=string.format('%X',RIP)
					local hit_no=1
					local hlk=hits_lookup[RIPx]
					if  hlk~= nil then
						hit_no=hlk[1]+1
						hlk[1]=hit_no
						table.insert(hits_lookup[RIPx][2],ix)
					else --nil
						hits_lookup[RIPx]={hit_no,{ix}}
					end

					local deref={['hit_address']=RIPx}
					local dst = disassemble(RIP)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					deref['disassembly']={instruction,address,bytes,extraField}
					--Get accessed memory addresses

					-- EXTRA SUB-REGISTERS
					local instruction_r=upperc(string_match(instruction,'[^%s]+%s*(.*)'))
					local s=instruction_r  -- substitute register names for their spaces
					--local sd=instruction_r -- substitute register names for their decimals
					local present_r={}
					local present_r_lookup={}
					
					for i=1, #registers['list_regs'] do
						local regs_pos={}
						if string.find(s,'%u')~=nil then
							local fnd=false
							local ri=registers['list_regs'][i] --check for presence of register
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
									local hx=string.format('%X',rgs)
									rg['hex']=hx
									rg['aob']=hexToAOB(hx)
								end
							if rg['aob']~=nil then
									rg['aob_str']=table.concat(rg['aob'],' ')
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
					
					
					local asc_nr=getAccessed(s) -- get memory "[...]" syntax matches with spaces in place of registers
					--local asc_d=getAccessed(sd) -- get memory "[...]" syntax matches in decimal
					local asc=getAccessed(instruction) -- get memory "[...]" syntax matches
					local m_acc={}
					local reffed_instruction=instruction
					local accessed_addrs={}

					for i=1, #asc do
						local ai=asc_nr[i]
						local sa=string_arr(s)
						local c=1
						local mtc_hex="%x+"
						local brk=false

						while brk==false do
							  local fa,fb=string.find(s,mtc_hex,c)
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
							local fstx=asc[i][2]
							local brkt=asc[i][1]
							-- [2]= { --[[ full syntax "[...]" ]] }
								local rep_with='[ '..brkt..' ('..rx..') ]'
								reffed_instruction=plainReplace(reffed_instruction,fstx,rep_with)
						end
					end
								local a = getNameFromAddress(address) or ''
								local pa=''
								if a=='' then
									pa=RIPx
									m_acc['address_string']=pa
								else
									m_acc['address_string']=a
									pa=RIPx .. ' ( ' .. a .. ' )'
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
								
								local prinfo_cnt=string.format('%s:\t%s  -  %s', pa, bytes, instruction)

								if extraField~='' then
									prinfo=prinfo .. ' (' .. extraField .. ')'
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
					local ix=#hits
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
					if stp==true then
						debug_continueFromBreakpoint(co_stepover)
					else
						debug_continueFromBreakpoint(co_stepinto)
					end
				else
					debug_continueFromBreakpoint(co_run)
					runStop(true)
				end
		end
end

local function condBp(a, c, b, f)
	condBp_bk=0
	condBp_fw=0
	if b~=nil then
		condBp_bk=b
	end
	
	if f~=nil then
		condBp_fw=f
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
		
	local tc={['str']={},['num']={},['opc']={}}
	local typc=type(c)
	if typc=='table' then
			for i=1, #c do
				local ci=c[i]
				if type(ci)=='string' then
					local cs=upperc(space_fix(ci))
					table.insert(tc.str, cs)
				elseif type(ci)=='table' then
					for j=1, #ci do
						table.insert(tc.opc, ci[j])
					end
				elseif typc=='number' then
					table.insert(tc.num, ci)
				end
			end
	elseif typc=='string' then
		tc.str={upperc(space_fix(c))}
	elseif typc=='number' then
		tc.num={c}
	end
	condBpVals=tc
	
	first=true
	present_r_last_lookup={}
	present_m_last_lookup={}
	condBpProg=true
	debug_setBreakpoint(condBpAddr[1][1], 1, bptExecute)
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
							if string.find(instruction,pk)~=nil then
								breakHere={true, 'Instruction pattern match'}
								break
							end		
						end
					end
	
		-- EXTRA SUB-REGISTERS
	local instruction_r=upperc(string_match(instruction,'[^%s]+%s*(.*)'))
	local s=instruction_r  -- substitute register names for their spaces
	--local sd=instruction_r -- substitute register names for their decimals
	local present_r={}
	local present_r_lookup={}
	
	for i=1, #registers['list_regs'] do
		local regs_pos={}
		if string.find(s,'%u')~=nil then
			local fnd=false
			local ri=registers['list_regs'][i] --check for presence of register
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
								if string.find(rg['aob_str'],vk,1,true)~=nil then
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
		local asc=getAccessed(instruction) -- get memory "[...]" syntax matches
		local reffed_instruction=instruction

		for i=1, #asc do
			local ai=asc_nr[i]
			local sa=string_arr(s)
			local c=1
			local mtc_hex="%x+"
			local brk=false
			while brk==false do
				  local fa,fb=string.find(s,mtc_hex,c)
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
				local rb=r+condBp_bk
				local rf=r+condBp_fw
				local rg=rf-rb+1
				local byt=readBytes(rb,rg,true)
				local tb={r,rx,nil,nil,r}
				
				if type(byt) =='table' then
								local aobt={}
								local aobt_le={}
								local bytl=#byt
								for j=1, bytl do
									table.insert(aobt,string.format('%X',byt[j]))
								end
								
								for j=bytl, 1, -1 do
									table.insert(aobt_le,string.format('%X',byt[j]))
								end
								local aob=table.concat(aobt, ' ')
								local dec = tonumber(table.concat(aobt_le, ''),16)
								chk=true
								tb[3]=dec
								tb[4]=aob
				end
				present_m_last_lookup[rx]=tb -- all present addresses added
				chkMem[rx]=tb
				local fstx=asc[i][2]
				local brkt=asc[i][1]
				-- [2]= { --[[ full syntax "[...]" ]] }
					local rep_with='[ '..brkt..' ('..rx..') ]'
					reffed_instruction=plainReplace(reffed_instruction,fstx,rep_with)
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
							if string.find(v[4],vk,1,true)~=nil then
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
						local a = getNameFromAddress(address) or ''
						local pa=''
						if a=='' then
							pa=RIPx
						else
							pa=RIPx .. ' ( ' .. a .. ' )'
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
							prinfo=prinfo .. ' (' .. extraField .. ')'
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

local function jumpMem()
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
	
	local lst=getPreviousOpcode(RIP)
	if lst==nil then
		lst=RIP
	end
	--local lstx=string.format('%X',lst)
	local dst = disassemble(lst)
	local extraField, instruction, bytes, address = splitDisassembledString(dst)
	
local instruction_r=upperc(string_match(instruction,'[^%s]+%s*(.*)'))
	local s=instruction_r  -- substitute register names for their spaces
	--local sd=instruction_r -- substitute register names for their decimals
	local present_r={}
	local present_r_lookup={}
	
	for i=1, #registers['list_regs'] do
		local regs_pos={}
		if string.find(s,'%u')~=nil then
			local fnd=false
			local ri=registers['list_regs'][i] --check for presence of register
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
					local hx=string.format('%X',rgs)
					rg['hex']=hx
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
		local asc=getAccessed(instruction) -- get memory "[...]" syntax matches
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
				  local fa,fb=string.find(s,mtc_hex,c)
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
		local frm = getMemoryViewForm()
		local hv = frm.DisassemblerView
                local hx=frm.HexadecimalView
		hv.SelectedAddress2 = lst
                hx.address=r 
				memJmp=true
				break
			end
		end
		if memJmp==false then
			local mn=getModuleName(lst)
			if currModule==nil then
				currModule=mn
				currRegsAddr=alloc('traceCount_registers',1024,mn)
			elseif mn~=currModule then
				dealloc('traceCount_registers')
				currModule=mn
				currRegsAddr=alloc('traceCount_registers',1024,mn)
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

	        local frm = getMemoryViewForm()
		local hv = frm.DisassemblerView
                local hx=frm.HexadecimalView
		hv.SelectedAddress2 = lst
                hx.address=currRegsAddr
		end
		return
end

function debugger_onBreakpoint()
	if prog==false and condBpProg==false then
		jumpMem()
	elseif condBpProg==true then
		onCondBp()
	elseif prog==true then
		onBp()
	end
end

traceCount={}
traceCount.attach=attach
traceCount.stop=stop
traceCount.printHits=printHits
traceCount.save=save
traceCount.saved=saved
traceCount.compare=compare
traceCount.delete=delete
traceCount.query=query
traceCount.condBp=condBp
