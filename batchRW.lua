local timer
local lprog=false
local timer_attach={['accessed']={}}
local addr_stack=nil
local empty_stack=true
local firstStack=true
local rets_lookup={}
local rets_lookup_order={}
local modulesList={}
local bps={}
local xcld={['Decimal address']=true}
local jumpRes={['sel']='',['rsp']={},['stack']={}}

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

local function print_th(t,p)
	if p~=nil then
		p:write(t..'\n')
	else
		print(t)
	end
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

local function tprint(tbl, lookup_exclude, indent,suppressNL,pth,noQM)
  local function do_tprint(tbl, lookup_exclude, indent,pth,noQM) -- https://gist.github.com/ripter/4270799
	if indent==nil then indent = 0 end
	for k, v in pairs(tbl) do
		local tyk=type(k)
		local passthrough=false
		if tyk~='string' then
			passthrough=true
		elseif type(lookup_exclude)=='table' then
			if lookup_exclude[k]==nil then
				passthrough=true
			end
		else
			passthrough=true
		end
		if passthrough==true then
			  formatting = string.rep("	", indent) .. k .. ": "
			  local typv=type(v)
			  if typv == "table" then
				print_th(formatting,pth)
				do_tprint(v, lookup_exclude, indent+1,pth,noQM)
			  elseif typv == 'boolean' then
				print_th(formatting .. tostring(v),pth)
			  elseif typv == 'string' then
				if noQM==true then print_th(formatting..v,pth) else
					local la, lb=string.find(v, "\n")
					if la==nil then
						print_th(formatting .. '"'.. v ..'"',pth)
					else
						print_th(formatting .. '[['.. v ..']]',pth)
					end
				end
			  elseif typv == 'function' then
				print_th(formatting .. 'function () … end',pth)
			  else
				print_th(formatting .. tostring(v),pth)
			  end
		end
	end
  end
  do_tprint(tbl, lookup_exclude, indent,pth,noQM)
  if suppressNL~=true then
		if pth~=nil then
			pth:write('\n')
		else
			print('\n')
		end
  end
end

local function tprint_kv(k,v, lookup_exclude, indent,suppressNL)
  local function do_tprint_kv(k,v, lookup_exclude, indent) -- https://gist.github.com/ripter/4270799
	if indent==nil then indent = 0 end
		local tyk=type(k)
		local passthrough=false
		if tyk~='string' then
			passthrough=true
		elseif type(lookup_exclude)=='table' then
			if lookup_exclude[k]==nil then
				passthrough=true
			end
		else
			passthrough=true
		end
		if passthrough==true then
			  formatting = string.rep("	", indent) .. k .. ": "
			  local typv=type(v)
			  if typv == "table" then
				print(formatting)
				tprint(v, lookup_exclude, indent+1,true)
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
				print(formatting .. tostring(v))
			  end
		end
  end
  do_tprint_kv(k,v, lookup_exclude, indent)
  if suppressNL~=true then
	print('\n')
  end
end

local function isInModule(address,address_hex,list) -- https://github.com/cheat-engine/cheat-engine/issues/205 (mgrinzPlayer)
	for i=1, #list do
	local v=list[i]
		if address>=v.Address and address<=v.lastByte then
			local ofs=address-v.Address
			local ofsNm=''
			if ofs>0 then
				ofsNm=v.Name..'+'..string.format('%X',ofs)
			else
				ofsNm=v.Name
			end
			return {true,ofsNm,v.Name}
		end
	end
	return {false,address_hex}
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

local function trim_str(s)
	return string.match(s,'^()%s*$') and '' or string.match(s,'^%s*(.*%S)')
end

local function space_fix(s)
	local s2 = s:gsub("%s+", " ")
	return trim_str(s2)
end

local function AOB_to_byte_table(s)
	local t={}

	for c in string.gmatch(s,'%x%x') do
	  table.insert(t,c)
	end
	local out = {}
	for i=1, #t do
	table.insert(out,tonumber(t[i], 16))
	end
	return out
end

local function reverseHex(h,aob)
	local rht={}
	local sl=string.len(h)
	for i=sl, 1, -2 do
		table.insert(rht,string.sub(h,i-1,i))
	end
	local s=''
	if aob==true then
		s=' '
	end
	return table.concat(rht,s)
end

local function tableLen(t)
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

local function do_attach(s,z,onWrite,cond,col,t,alist,alc)
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
		local xclc={}
		if col~=nil then
			if type(col)=='table' then
				colr=tonumber(reverseHex(col[1]),16)
				xclc[string.format('%d',colr)]=true
				local colL=#col
				if colL>1 then
					for i = 2, colL do
						xclc[string.format('%d',tonumber(reverseHex(col[i]),16))]=true
					end
				end
			else
				xclc[string.format('%d',reverseHex(col))]=true
			end
		else
			xclc['65535']=true
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
				local scol=string.format('%d',mr.Color)
				 if attThis==true and mr.type<11 and (t~=true or (xclc[scol]==nil and t==true) ) then --See defines.lua for "<11"	
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
				elseif mr~=nil and xclc[scol]==true and t==true then
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
				trg=bptWrite
				print('Written to addresses:')
			else
				print('Read addresses:')
			end
		end
		
		for i = 1, #bps do
			local b=bps[i]
			debug_setBreakpoint(b[1], 1, trg, bpmInt3, function()
						debug_getContext()
						local mtc={false,''}
						
						if cond~=nil then
							local csl=#cond.str
							if csl>0 then
								for k=1, csl do
									local ck=cond.str[k] -- each aob
										local ct=ck.tbl -- byte table for this aob
										local byt=readBytes(b[1],#ct,true)
										if sameTable(ct,byt)==true then
											mtc={true,"AOB match ('"..ck.aob.."')"}
											break
										end
								end
							end
							
							if mtc[1]~=true then
								local cnl=#cond.num
								if cnl>0 then
									for k=1, cnl do
										local ck=cond.num[k] -- each number
											local ct=ck.tbl -- byte table for this number
											local byt=readBytes(b[1],#ct,true)
											if sameTable(ct,byt)==true then
												local sb='bytes'
												local cn2=ck.number[2]
												if cn2==1 then
													sb='byte'
												end
												mtc={true,'Number match: '..ck.number[1]..' ('..cn2..' '..sb..')'}
												break
											end
									end
								end
							end
						end
						
						local ch=false
						if cond~=nil and mtc[1]==true then
							ch=true
						end
						
						if cond==nil or ch==true then
							b[3].Color=colr --yellow
							local lst=getPreviousOpcode(RIP)
							local dst = disassemble(lst)
							local extraField, instruction, bytes, address = splitDisassembledString(dst)
							local bx=string.format('%X',b[1])
							local lstx=string.format('%X',lst)
							timer_attach.accessed[bx]=b[1]
							
							local a = getSymbolNameFromAddress(lst,true)
							local pa=lstx
							if a[1]==a[2] then
								if a[1]~=lstx then
									pa=lstx .. ' [ ' .. a[1] .. ' ]'
								end
							else
								if a[1]~=lstx and a[2]~=lstx then
									pa=lstx .. string.format(' [ %s (%s) ]',a[1],a[2])
								elseif a[1]~=lstx and a[2]==lstx then
									pa=lstx .. ' [ ' .. a[1] .. ' ]'
								elseif a[1]==lstx and a[2]~=lstx then
									pa=lstx .. ' [ ' .. a[2] .. ' ]'
								end
							end

							local prinfo=string.format('%s:\t%s  -  %s }', pa, bytes, instruction)
							if ch==true then
										prinfo=prinfo..'\t[ '..mtc[2]..' ]'
							end
							if b[4]=='' then
								local sp=b[2] .. ' (#' .. b[5] .. ')\t{ '..prinfo
								print(sp)
							else
								local sp=b[4] .. ' - ' .. b[2] .. ' (#' .. b[5] .. ')\t{ '..prinfo
								print(sp)
							end
							debug_removeBreakpoint(b[1])
						end
			end)
		end
end

local function attach(s,z,onWrite,cond,col)
	if timer~=nil then
		timer.destroy()
	end
	
	--format for cond: (	string(AOB)	) /  (number, size)
		local condit=nil
		if cond~=nil then
			condit={['str']={},['num']={}}
			local typc=type(cond)
			if typc=='table' then
					for i=1, #cond do
						local ci=cond[i]
						local tyci=type(ci)
						if tyci=='number' then
							local cs={}
							cs.number=cond
							cs.tbl=AOB_to_byte_table(reverseHex(string.format('%0'..(cond[2]*2)..'X',ci),true))
							table.insert(condit.num, cs)
							break
						elseif tyci=='table' then
							local cs={}
							cs.number=ci
							cs.tbl=AOB_to_byte_table(reverseHex(string.format('%0'..(ci[2]*2)..'X',ci[1]),true))
							table.insert(condit.num, cs)
						elseif tyci=='string' then
							local cs={}
							cs.tbl=AOB_to_byte_table(string.upper(space_fix(ci)))
							cs.aob=c[i]
							table.insert(condit.str, cs)
					end
				end
		elseif typc=='string' then
			local cs={}
			cs.tbl=AOB_to_byte_table(string.upper(space_fix(cond)))
			cs.aob=cond
			table.insert(condit.str, cs)
		end
	end

	do_attach(s,z,onWrite,condit,col)
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
		local hx=string.format('%s%s%X',bse,sgn,d)
		rec.setDescription(hx)
		--rec.ShowAsHex=true
		rec.Type=0
	end
	
end

local function keepCol(c)
		local keepc={}
		if c~=nil then
			if type(c)=='table' then
					for i = 1, #c do
						keepc[string.format('%d',tonumber(reverseHex(c[i]),16))]=true
					end
			else
				keepc[string.format('%d',reverseHex(c))]=true
			end
		else
			keepc['65535']=true
		end

	local al = getAddressList()
	local vt={}
	  for i = 0, al.Count - 1 do
		  local mr = al.getMemoryRecord(i)
		  local scol=string.format('%d',mr.Color)
		  if mr ~= nil and mr.Type<11 and keepc[scol]==nil then --See defines.lua for "<11"
			  table.insert(vt,mr)
		 end
	 end
	  for i = 1, #vt do
		  vt[i].destroy()
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
					attach(0,z,onWrite,nil,col)
					return
				end
				local taal=tableLen(timer_attach.accessed)
				if alc-taal<=z then
					end_loop()
					print('\nAttached to remaining entries:')
					attach(0,z,onWrite,nil,col)
				elseif taal<alc then
					local za=timer_attach.z
					local s=timer_attach.s_mult*za
					timer_attach.s_mult=timer_attach.s_mult+1
					local mod_s =math.fmod(s,alc)
					do_attach(mod_s,za,timer_attach.onWrite,nil,col,true,al,alc)
				else
					end_loop()
				end
			end
			lprog=false
		end
	end
	timer.OnTimer=ot
end

local function end_stack(p)
	if addr_stack~=nil then
		debug_removeBreakpoint(addr_stack)
	end
	 if empty_stack==true then
		print('No stack data!')
		return
	 end
 
	local pth=nil
	if p~=nil and p~=''  then
			pth=io.open(p,'w')
			print('Saving stack logs…')
	end
 
	jumpRes.stack={}
	jumpRes.sel='stack'
	local cnt=1
	local t2={}
	for key0, value0 in pairs(rets_lookup) do
		print_th('Instruction address '..key0..':',pth)
		for key, value in pairs(value0) do
			table.insert(t2,{['Symbolic address']=value['Symbolic_address'],['Decimal address']=value['address_dec'],['Address']=key,['Count']=value['count'],['RSP+… ']=value['RSP+…']})
		end
		table.sort( t2, function(a, b) return a['Count'] > b['Count'] end )
		for n=1, #t2 do
			t2[n]['Jump #']=cnt
			table.insert(jumpRes.stack,t2[n])
			cnt=cnt+1
		end
		tprint(t2,xcld,1,true,pth)
		if pth~=nil then
			pth:write('\n')
		else
			print('')
		end
	end
	if pth~=nil then
			print('Stack logs saved!')
			io.close(pth)
	end
end

local function stack(d,b,m,f)

	empty_stack=true

	local tyd=type(d)
	local trg=bptExecute
	if tyd=='table' then
		trg=bptAccess
		if d[2]==true then
			trg=bptWrite
		end
		addr_stack=getAddress(d[1])
	elseif tyd=='string' then
		addr_stack=getAddress(d)
	else
		addr_stack=d
	end

	rets_lookup={}
	rets_lookup_order={}
	modulesList={}

	local modulesTable= enumModules()
	for i,v in pairs(modulesTable) do
		if v.Name==m or m==nil or m=='' then
			local sz=getModuleSize(v.Name)
			local tm={
				['Size']=sz,
				['Name']=v.Name,
				['lastByte']=v.Address+sz-1,
				['Address']=v.Address
			}
			table.insert(modulesList,tm)
		end
	end
	firstStack=true
	debug_setBreakpoint(addr_stack, 1, trg, bpmDebugRegister, function()
		if firstStack==true then
			firstStack=false
			print('Breakpoint for '..string.format('%X',addr_stack)..' hit!')
		end
		debug_getContext()
		local bp
		if b==nil or b<0 then
			bp=math.max(RBP-7,RSP)
		else
			if f==true then
				bp=RSP+b
			else
				bp=math.max(math.min(RSP+b,RBP-7),RSP)
			end
		end
		
		local fc=0
		local fsx='0'
		local RIPx=string.format('%X',RIP)
		local first=false
		for i=RSP, bp do
			local rd=readQword(i)
			if type(rd)=='number' and rd>=0 then
				if first==false then
					first=true
					if rets_lookup_order[RIPx]==nil then
						rets_lookup_order[RIPx]={}
					end
					if rets_lookup[RIPx]==nil then
						rets_lookup[RIPx]={}
					end
				end
				local dx=string.format('%X',rd)
				local isRet=isInModule(rd,dx,modulesList)
				if isRet[1]==true then
				 empty_stack=false
				 local orderRet={}
				 orderRet['# ']=#rets_lookup_order[RIPx]+1
				 orderRet['Address']=dx
				 orderRet['Decimal address']=rd
				 orderRet['Symbolic address']=isRet[2]
				 orderRet['RSP+… ']=fsx
				 table.insert(rets_lookup_order[RIPx],orderRet)
					if rets_lookup[RIPx][dx]==nil then
						rets_lookup[RIPx][dx]={}
						rets_lookup[RIPx][dx]['count']=1
						rets_lookup[RIPx][dx]['address_dec']=rd
						rets_lookup[RIPx][dx]['Symbolic_address']=isRet[2]
						rets_lookup[RIPx][dx]['RSP+…']={}
						rets_lookup[RIPx][dx]['RSP+…'][fsx]=1
					else
						rets_lookup[RIPx][dx]['count']=rets_lookup[RIPx][dx]['count']+1
						if rets_lookup[RIPx][dx]['RSP+…'][fsx]~=nil then
							rets_lookup[RIPx][dx]['RSP+…'][fsx]=rets_lookup[RIPx][dx]['RSP+…'][fsx]+1
						else
							rets_lookup[RIPx][dx]['RSP+…'][fsx]=1
						end
					end
				end
			end
			fc=fc+1
			fsx=string.format('%X',fc)
		end
	end)
end

local function rsp(b,m,f)

	debug_getContext()
	local rets_lookup2={}
	rets_lookup2.ord={}
	local modulesList2={}
	
	local modulesTable= enumModules()
  for i,v in pairs(modulesTable) do
	if v.Name==m or m==nil or m=='' then
		local sz=getModuleSize(v.Name)
		local tm={
			['Size']=sz,
			['Name']=v.Name,
			['lastByte']=v.Address+sz-1,
			['Address']=v.Address
		}
		table.insert(modulesList2,tm)
	end
  end
		local bp
		if b==nil or b<0 then
			bp=math.max(RBP-7,RSP)
		else
			if f==true then
				bp=RSP+b
			else
				bp=math.max(math.min(RSP+b,RBP-7),RSP)
			end
		end
		local fc=0
		local fsx='0'
		for i=RSP, bp do
			local rd=readQword(i)
			if type(rd)=='number' and rd>=0 then
				local dx=string.format('%X',rd)
				local isRet=isInModule(rd,dx,modulesList2)
				if isRet[1]==true then
					if rets_lookup2[dx]==nil then
						table.insert(rets_lookup2.ord,dx)
						rets_lookup2[dx]={}
						rets_lookup2[dx]['Count']=1
						--rets_lookup2[dx]['address_dec']=rd
						rets_lookup2[dx]['Address']=dx
						rets_lookup2[dx]['Decimal address']=rd
						rets_lookup2[dx]['Symbolic address']=isRet[2]
						rets_lookup2[dx]['RSP+… ']={}
						rets_lookup2[dx]['RSP+… '][fsx]=1
					else
						rets_lookup2[dx]['Count']=rets_lookup2[dx]['Count']+1
						if rets_lookup2[dx]['RSP+… '][fsx]~=nil then
							rets_lookup2[dx]['RSP+… '][fsx]=rets_lookup2[dx]['RSP+… '][fsx]+1
						else
							rets_lookup2[dx]['RSP+… '][fsx]=1
						end
					end
				end
			end
			fc=fc+1
			fsx=string.format('%X',fc)
		end
	jumpRes.rsp={}
	jumpRes.sel='rsp'
	for i=1, #rets_lookup2.ord do
		local k=rets_lookup2.ord[i]
		local v=rets_lookup2[k]
		v['Jump #']=i
		table.insert(jumpRes.rsp,v)
		tprint_kv(k,v,xcld,nil,true)
	end
end

local function jump(i)
	local js=jumpRes[jumpRes.sel]
	local j=js[i]
	if j==nil then
		print(string.format('Argument "i" must be between 1 and %d',#js))
	else
		getMemoryViewForm().DisassemblerView.TopAddress=j['Decimal address']
	end
end

local function region(a)
	local out={}
	local finalOut={}
	local rt=enumMemoryRegions()
	local ad=getAddress(a)

	for k, v in pairs(rt) do
		local vab=v.AllocationBase
		local vabx=string.format('%X',vab)
		local vba=v.BaseAddress
		local vbax=string.format('%X',vba)
		
			if out[vbax]==nil then
				local ov=deepcopy(v)
				ov.RegionType='Base'
				ov.RelevantBase=vba
				out[vbax]={ov}
			else
				local ov=deepcopy(v)
				ov.RegionType='Base'
				ov.RelevantBase=vba
				table.insert(out[vbax],ov)
			end
			
			if out[vabx]==nil then
				local ov=deepcopy(v)
				ov.RegionType='AllocationBase'
				ov.RelevantBase=vab
				out[vabx]={ov}
			else
				local ov=deepcopy(v)
				ov.RegionType='AllocationBase'
				ov.RelevantBase=vab
				table.insert(out[vabx],ov)
			end
	end
	
	for k, v in pairs(out) do
		for ki=1, #v do
			local vki=v[ki]
			local vb=vki.RelevantBase
			if ad>=vb and ad<=vb+vki.RegionSize-1 then
				local vt={}
				for k1, v1 in pairs(vki) do
					if string.find(k1,'Base')==nil then
						if type(v1)=='number' then
							vt[k1]=string.format('%d (0x%X)',v1,v1)
						else
							vt[k1]=v1
						end
					end
				end
				vt.Offset=string.format('%X+%X',vb,ad-vb)
				vt.Address=string.format('%X',ad)
				finalOut[k]=vt
			end
		end
	end
     
	 tprint(finalOut,nil, nil,nil,nil,true)
end

batchRW={
	attach=attach,
	attach_loop=attach_loop,
	end_loop=end_loop,
	printAddrs=printAddrs,
	detachAll=detachAll,
	add=add,
	keepCol=keepCol,
	end_stack=end_stack,
	stack=stack,
	rsp=rsp,
	jump=jump,
	region=region
}