opcode_inj={}

local script_ref,inj_name,newmem_name,newmem_size,vars,inj_script,pattern,aobs,lookahead_n,parts,module_names

local function giveModuleAndOffset(address) -- https://github.com/cheat-engine/cheat-engine/issues/205 (mgrinzPlayer)
  local modulesTable,size = enumModules(),0
  for i,v in pairs(modulesTable) do
      size = getModuleSize(v.Name)
      if address>=v.Address and address<(v.Address+size) then
        return {v.Name..'+'..string.format('%X',address-v.Address),v.Name}
      end
  end
  return {address,''}
end

local function spaceSepBytes(b)
	local bs = string.gsub(b, "%s+", "")
	local out={}
	for i=1,#bs, 2 do
		table.insert(out,string.sub(bs,i,i+1))
	end
	return table.concat(out,' ')
end

local function checkAdressOffset_ret_string(address,hex_address_string) -- decimal
	local cea=getNameFromAddress(address)
	local mfa= giveModuleAndOffset(address)
	if mfa[1] == cea or string.find(mfa[1], mfa[2], 1,true)==nil or  string.find(cea, mfa[2], 1,true)==nil then
		return mfa[1]
	else
		if hex_address_string~= nil then
			return hex_address_string
		else
			return string.format('%X',address)
		end
	end
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
		print(formatting .. tostring(v))
	  end
	end
  end
  do_tprint(tbl,indent)
  print('\n')
end

local function string_variFormat(p,t)
	return string.format(p,table.unpack(t))
end

local function tbl_ception(t)
  local tt={}
  for i=1, #t do
      local ty=type(t[i])
      if ty~='table' then -- only {{},{},...,{}} can pass
         return {t} -- return table containing table
      else
          table.insert(tt,t[i])

      end
  end
  return tt
end

local function trim_str(s)
	return string.match(s,'^()%s*$') and '' or string.match(s,'^%s*(.*%S)')
end

local function trim_table(t)
	if t==nil then
		return {}
	end
	local out={}
	for i=1,#t do
		table.insert(out,trim_str(t[i]))
	end
	return out
end

local function get_subtable(t, strt, ed)
  local out = {}

  for i =strt, ed do
    table.insert(out,t[i])
  end

  return out
end

local function get_substring(starr,strt,ed)
	return table.concat(get_subtable(starr, strt, ed),'')
end

local function child_els_index(t,ix)
      local out={}
      for i=1, #t do
          table.insert(out,t[i][ix])
      end
      return out
end

local function string_arr(s)
	local spl={}
	local sl=string.len(s)
	for i=1, sl do
		table.insert(spl,string.sub(s,i,i))
	end
	return spl
end

local function filter_tbl(t,v,b)
	local out={}
	for i=1, #t do
		local ti=t[i]
		if (b==true and ti==v) or (b==false and ti~=v) then
			table.insert(out,ti)
		end
	end
        return out
end

local function tbl_fill(n,v)
	local t={}
	for i=1, n do
		table.insert(t,v)
	end
	return t
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

local function str_find_ix_reduce(s,p,d) --BEWARE! FILLS WITH WHITESPACE
	local out={}
	local redu={}
	local redu_s=s
	
	for k=1, #p do
		local pk=p[k]
		local i=1
		while true do
			local a,b=string.find(redu_s,pk,i)
			if a==nil then
				break
			else
				table.insert(out,{a,b,d[k]})
				table.insert(redu,string.sub(redu_s,a,b))
				i=a+1
			end
		end
		for j=1, #redu do
			local rj=redu[j]
			redu_s=plainReplace(redu_s,rj,string.rep(' ',string.len(rj)))
		end
	end
	return out
end

local function string_Dollar(s,t)
	tfmt = {['string']='',['tokens']={},['args']={}}
	local out=''
	local mtc="%$%%[^%{]+%{%s*[^%}]+%s*%}" --$%s{…} syntax
	local mtc2="%$(%%[^%{]+)%{%s*[^%}]+%s*%}"
	local mtc3="%$%%[^%{]+%{%s*([^%}]+)%s*%}"

	local mtcf="%$%{%s*[^%}]+%s*%}%(%s*[^%)]*%s*%)" --full function syntax ${…}(…) syntax
	local mtcf2="%$%{%s*[^%}]+%s*%}%(%s*([^%)]*)%s*%)" -- ("…")
	local mtcf3="%$%{%s*([^%}]+)%s*%}%(%s*[^%)]*%s*%)"

	local mtcf_t="%$%%[^{]+%{%s*[^%}]+%s*%}%(%s*[^%)]*%s*%)" --full function syntax $%d{…}(…) syntax
	local mtcf2_t="%$%%[^{]+%{%s*[^%}]+%s*%}%(%s*([^%)]*)%s*%)" -- ("…")
	local mtcf3_t="%$%%[^{]+%{%s*([^%}]+)%s*%}%(%s*[^%)]*%s*%)"
	local mtcf4_t="%$(%%[^{]+)%{%s*[^%}]+%s*%}%(%s*([^%)]*)%s*%)"

	local mt="%$%{%s*[^%}]+%s*%}" --${…} syntax
	local mt2="%$%{%s*([^%}]+)%s*%}"

	local mrs=s
	--local sp=string_arr(s)
	local sf=str_find_ix_reduce(s,{mtc,mtcf,mtcf_t,mt},{0,1,2,3})
	table.sort( sf, function(a, b) return a[1] < b[1] end ) -- results array now sorted by count (ascending)
	
	for k=1, #sf do
		local sfk=sf[k]
		local i=string.sub(s,sfk[1],sfk[2])
		if sfk[3]==0 then
				local ag=string.match(i,mtc3)
				local tk=string.match(i,mtc2)
				mrs=plainReplace(mrs,i,tk)
				table.insert(tfmt['tokens'],tk)
				table.insert(tfmt['args'],t[ag])
		elseif sfk[3]==1 then
				mrs=plainReplace(mrs,i,'%s')

				local ags=string.match(i,mtcf2)
				local fn=string.match(i,mtcf3)

				table.insert(tfmt['tokens'],'%s')
				if string.match(ags,'%s*')~=nil then --there are arguments
					local agsp=plainSplitKeep(ags,',')
					local fa=filter_tbl(agsp,',',false)
					local argms=trim_table(fa)
					local fr=t[fn](table.unpack(argms))
					table.insert(tfmt['args'],fr)
				else
					table.insert(tfmt['args'],t[fn]())
				end
		elseif sfk[3]==2 then
			    local ags=string.match(i,mtcf2_t)
				local fn=string.match(i,mtcf3_t)
				local tk=string.match(i,mtcf4_t)
				mrs=plainReplace(mrs,i,tk)
				table.insert(tfmt['tokens'],tk)
				if string.match(ags,'%s*')~=nil then --there are arguments
					local agsp=plainSplitKeep(ags,',')
					local fa=filter_tbl(agsp,',',false)
					local argms=trim_table(fa)
					local fr=t[fn](table.unpack(argms))
					table.insert(tfmt['args'],fr)
				else
					table.insert(tfmt['args'],t[fn]())
				end
		else
				mrs=plainReplace(mrs,i,'%s')
				local fn=string.match(i,mt2)
				table.insert(tfmt['tokens'],'%s')
				if type(t[fn])=='function' then
					table.insert(tfmt['args'],t[fn]())
				else
					table.insert(tfmt['args'],t[fn])
				end
		end
	end
	
tfmt['string']=mrs
  return tfmt
end

local function str_concat_rep(s,n,p)
	local out={}
	for i=1, n do
		table.insert(out,s)
	end
	return table.concat(out,p)
end

local function getLookaheads(k,lookahead_n,instruction,bytes)
		local lookaheads={['offsets']={0},['instructions']={instruction},['bytes']={bytes}}
		local szk=getInstructionSize(k)
		lookaheads['sizes']={szk}
		local lbc=szk -- running byte count
		local offset_inst=k+szk --running byte count + address
		while lbc<lookahead_n+1 do
			table.insert(lookaheads['offsets'],lbc) --start (offset) of next instruction

			szk=getInstructionSize(offset_inst) -- size of next instruction
			table.insert(lookaheads['sizes'],szk)

			local dsk_off = disassemble(offset_inst)
			local extraField_off, instruction_off, bytes_off, address_off = splitDisassembledString(dsk_off)
			table.insert(lookaheads['instructions'],instruction_off) -- insert next instruction
			table.insert(lookaheads['bytes'],spaceSepBytes(bytes_off)) -- insert next instruction

			lbc=lbc+szk -- running byte count
			offset_inst=offset_inst+szk --running byte count + address
		end

		return lookaheads
end

local function instruction_address_spec(addr,lookahead_n,parts,module_names)
	  local parts_tt={}
	  local parts_tt_l=0

	local dsk = disassemble(addr)
	local extraField, instruction, bytes, address = splitDisassembledString(dsk)
	local a = checkAdressOffset_ret_string(addr,address)
	
	local pt={}
	if parts~=nil then
		parts_tt=tbl_ception(parts)
		parts_tt_l=#parts_tt
		for i=1, parts_tt_l do
			local pi=parts_tt[i]
			local mc=1
			for mt in string.gmatch (instruction, pi[1]) do
				if mc==pi[2] then
					table.insert(pt,{pi[3],mt})
					break
				else
					mc=mc+1
				end
			end
		end
	end

	local byt=readBytes(addr,lookahead_n+1,true)
	local hexByteTable={}
	if type(byt) =='table' then
	   for i=1,#byt do
			table.insert(hexByteTable,string.format('%02X',byt[i]))
	   end
	end
	
	local lookaheads=getLookaheads(addr,lookahead_n,instruction,spaceSepBytes(bytes))
	
      local outp= {['og_bytes_dec']=byt,['og_hex']=hexByteTable,['address_dec']=addr, ['address_string']=a ,['lookaheads']=lookaheads,['og_instruction']=instruction}
	  local ptl=#pt
	  if parts~=nil and ptl>0 then
		  -- Spread parts array
		  for i=1, ptl do
			  outp[ pt[i][1] ]= pt[i][2]
		  end
	  end
      return outp
end

local function instruction_address(pattern,aobs,lookahead_n,parts,module_names)

	local type_aobs=type(aobs)
	
	if type_aobs=='string' then
		return instruction_address_spec(getAddress(aobs),lookahead_n,parts,module_names)
	elseif type_aobs=='number' then
		return instruction_address_spec(aobs,lookahead_n,parts,module_names)
	end
	
      local aob_tt=tbl_ception(aobs)

	  local parts_tt={}
	  local parts_tt_l=0

	  if parts~=nil then
		parts_tt=tbl_ception(parts)
		parts_tt_l=#parts_tt
		for i=1, parts_tt_l do
          local pi=parts_tt[i]
          local pi_1=pi[1]
          local adp=plainReplace(pattern,pi_1,table.concat({'(',pi[1],')'},''),pi[2]) --INSERTION [4]!! ; capture part
          parts_tt[i][4]=adp
		end
	end

      local fnd={}
      local fnd_it={}

      for i=1, #aob_tt do
		local bi=aob_tt[i]

		local aob_list={}

		if module_names~=nil then
			local mdn={}
			local tmn=type(module_names)
			if tmn=='string' then
				mdn[1]=module_names
			elseif tmn=='table' then
				mdn=module_names
			end

			for m=1, #mdn do
				local mdnm=mdn[m] -- module name

				local boolf,adr=pcall(function ()
					local addr=getAddress(mdnm)
					return {addr,addr+getModuleSize(mdnm)-1}
				end)

				if boolf==true then -- SUCCESS (NO ERROR)!
					local memscan = createMemScan()
					memscan.firstScan(
						  soExactValue, vtByteArray, nil,
						  bi[1], nil, adr[1],adr[2], '',
						  fsmNotAligned, '', true, true, false,false)
					memscan.waitTillDone()
					
					local foundlist = createFoundList(memscan)
					foundlist.initialize()
					
					for j = 0, foundlist.Count - 1 do
						table.insert(aob_list,foundlist.Address[j])
					end
					
					foundlist.destroy()
					memscan.destroy()
				end
			end
			
		else
			 local aob_list1=AOBScan(bi[1], "", 0)
			 local aob_count=aob_list1.Count
			 for j=1,aob_count do
				aob_list[j]=aob_list1[j-1]
			end
			aob_list1.destroy()
        end

          for j=1,#aob_list do
            local res=aob_list[j]
            local dec_res=tonumber(res,16)
            local rb=dec_res+bi[2]
            if rb<0 then
               rb=0
            end
	    local rf=dec_res+bi[3]
            for k=rb, rf do
                local dsk = disassemble(k)
				local extraField, instruction, bytes, address = splitDisassembledString(dsk)
				local a = checkAdressOffset_ret_string(k,address)
                if string.match(instruction,pattern)~=nil then
					local pt={}
					if parts~=nil then
						for p=1,parts_tt_l do
						   local pttp=parts_tt[p]
						   table.insert(pt,{pttp[3],string.match(instruction, pttp[4])})
						end
					end

                                        local byt=readBytes(dec_res,lookahead_n+1,true)
					local hexByteTable={}
					if type(byt) =='table' then
                                           for i=1,#byt do
					       table.insert(hexByteTable,string.format('%02X',byt[i]))
                                           end
					end

				   local lookaheads=getLookaheads(k,lookahead_n,instruction,spaceSepBytes(bytes))

                   local fda=fnd[a]
                   if fda==nil then
						fnd[a]={dec_res,res,1,a,pt,lookaheads,instruction,hexByteTable,byt} -- {decimal address, numeric address, counter, lookup string, parts table of strings, lookahead hex, matched instruction}
                   else
						fnd[a][3]=fda[3]+1 -- counter
                   end
                   k=rg --EARLY TERMINATE!
                end
            end
          end	  
      end

      for key, value in pairs(fnd) do
		table.insert(fnd_it,value) -- create sortable table
      end

      table.sort( fnd_it, function(a, b) return a[3] > b[3] end ) -- Converted results array now sorted by count (descending);
      local f1=fnd_it[1]

      local outp= {['og_bytes_dec']=f1[9],['og_hex']=f1[8],['address_dec']=f1[1], ['address_string']=f1[4] ,['lookaheads']=f1[6],['og_instruction']=f1[7]}
	  local ptl=#f1[5]
	  if parts~=nil and ptl>0 then
		  -- Spread parts array
		  for i=1, ptl do
			  outp[ f1[5][i][1] ]= f1[5][i][2]
		  end
	  end
      return outp
end

local function do_disable()
			local unregsy={}
			local deallc={}

			 for i in string.gmatch(vars.inj_script,'registersymbol%(%s*([^%)]+)%s*%)') do
				table.insert(unregsy,'unregistersymbol('..i..')')
			end
			unregsy_txt=table.concat(unregsy,'\n')

			for i in string.gmatch(vars.inj_script,'alloc%(%s*([^,]+)%s*,') do
				table.insert(deallc,'dealloc('..i..')')
			end
			deallc_txt=table.concat(deallc,'\n')


			local dedollar=string_Dollar(unregsy_txt,vars)
			local dsb=string_variFormat(dedollar.string,dedollar.args)
			vars['unregsy_txt']=dsb

			dedollar=string_Dollar(deallc_txt,vars)
			dsb=string_variFormat(dedollar.string,dedollar.args)
			vars['deallc_txt']=dsb

			local rst_aa=[[
			${deallc_txt}
			${unregsy_txt}
			define(${inj_name},${address_string})
			${inj_name}:
			${all_og_instructions}
			]]

	dedollar=string_Dollar(rst_aa,vars)
	dsb=string_variFormat(dedollar.string,dedollar.args)
	autoAssemble(dsb)
end

local function disable(script_ref_)
	pause()

	vars=opcode_inj[script_ref_]

	local b, r = pcall(do_disable)
	if vars ~=nil and vars['address_dec']~=nil then
		local frm = getMemoryViewForm()
		local hv = frm.DisassemblerView
		frm.Show()
		hv.TopAddress = vars['address_dec']
		hv.SelectedAddress = vars['address_dec']
	end
	unpause()

end

local function do_disable_nop()
	local inj_script=[[
		unregistersymbol(${inj_name})
		define(${inj_name},${address_string})
		${inj_name}:
		  ${nopped_instruction}
	]]
	local dedollar=string_Dollar(inj_script,vars)
	local dsb=string_variFormat(dedollar.string,dedollar.args)
	autoAssemble(dsb)
end

local function disable_nop(script_ref_)
	pause()

	vars=opcode_inj[script_ref_]

	local b, r = pcall(do_disable_nop)
	if vars ~=nil and vars['address_dec']~=nil then
		local frm = getMemoryViewForm()
		local hv = frm.DisassemblerView
		frm.Show()
		hv.TopAddress = vars['address_dec']
		hv.SelectedAddress = vars['address_dec']
	end
	unpause()

end

local function do_inject()

	local opa=instruction_address(pattern,aobs,lookahead_n,parts,module_names)
	for k, v in pairs(opa) do
		vars[k]=v
	end
	vars.instruction_size=getInstructionSize(vars.address_string)

	local enb_jmp_size=[[
	define(${inj_name},${address_string})
	alloc(${newmem_name},${newmem_size},${inj_name})

	${inj_name}:
	  jmp ${newmem_name}
	return:
	]]

	local vpst=vars['post']
	if vpst~=nil then
		for i=1, #vpst do
			local vpi=vpst[i]
			if type(vpi)=='function' then
				vars=vpi(vars)
			end
		end
	end

	local dedollar=string_Dollar(enb_jmp_size,vars)
	local enb_jmp_size_ntk=string_variFormat(dedollar.string,dedollar.args)
	autoAssemble(enb_jmp_size_ntk)

        local jmp_dss=disassemble(vars.address_string)
	local extraField_ci, instruction_ci, bytes_ci, addr_ci = splitDisassembledString(jmp_dss)
        vars['instruction_jmp']=instruction_ci
        vars['instruction_jmp_bytes']=spaceSepBytes(bytes_ci)
        local ad=tonumber(addr_ci,16)
        vars['address_dec']=ad
        vars['address_string']=checkAdressOffset_ret_string(ad,addr_ci)
	vars.jmp_size=getInstructionSize(vars.address_string)

	vars.post_jmp=''
	vars.overwritten=''
	if vars.jmp_size < vars.instruction_size then
	  vars.nops=vars.instruction_size-vars.jmp_size
	  vars.post_jmp=str_concat_rep('nop',vars.nops,'\n')
	elseif vars.jmp_size > vars.instruction_size then
	  vars.overlap=0
	  local offs=vars['lookaheads']['offsets']
	  for i=1, #offs do
		  if offs[i]>=vars.jmp_size then
			 vars.overlap=i-2
             vars.nops=offs[i]-vars.jmp_size
	         vars.post_jmp=str_concat_rep('nop',vars.nops,'\n')
			 break
		 end
	  end
	  if vars.overlap > 0 then
		 local offs_opc=vars['lookaheads']['instructions']
		 local ovps={}
		 for i=1,vars.overlap do
			 table.insert(ovps,offs_opc[i+1])
		 end
		 vars.overwritten=table.concat(ovps,'\n')
	  end
	end

	dedollar=string_Dollar(inj_script,vars)
	enb_jmp_size_ntk=string_variFormat(dedollar.string,dedollar.args)
	 local b, r = autoAssembleCheck(enb_jmp_size_ntk)
	 if b==false then
		print(r)
		error(r)
	end
	autoAssemble(enb_jmp_size_ntk)
	-- CORRECT INJECTION!!
	 opcode_inj[vars.script_ref]=vars
end

local function check_inj()
        if vars==nil or vars['address_dec']==nil then
           return
        end
	local curr_lookahead=getLookaheads(vars['address_dec'],vars['lookahead_n'],vars['instruction_jmp'],vars['instruction_jmp_bytes'])
	local rst=false
	local c=1
	local clp=curr_lookahead['instructions']
	local ogl=vars['lookaheads']['instructions']
        local ogll=#ogl
	vars['all_og_instructions']=table.concat(ogl,'\n')
        local farl1=false
	for i=1, #clp do
		local opc=clp[i]
		if i==1 and string.match(opc,'^%s*jmp%s+.+$')~=nil then
			c=c+1
		elseif i==1 then
			rst=true
			break
		elseif string.match(opc,'^%s*nop%s*$')==nil then
                       local nf=true
			if opc~=ogl[c] then
                           if farl1==false and c<ogll then
                             farl1=true
                             local jc=0
                             for j=c+1,ogll do
                                 jc=jc+1
                                 if opc==ogl[j] then
                                    nf=false
                                    c=j+1
                                    --i=i+jc
                                    break
                                 end
                             end
                           end

                             if nf==true then
				rst=true
				break
                             end
			else
				c=c+1
			end
		end
	end

		if rst==true then
			opcode_inj[vars.script_ref]=vars
			do_disable()
		end
end

local function inject(script_ref_,inj_name_,newmem_name_,newmem_size_,vars_,inj_script_,pattern_,aobs_,lookahead_n_,parts_,module_names_)
	pause()

	vars=vars_

	script_ref=script_ref_
	vars['script_ref']=script_ref
		inj_name=inj_name_
		vars['inj_name']=inj_name
	inj_script=inj_script_
	vars['inj_script']=inj_script
		pattern=pattern_
		vars['pattern']=pattern
	aobs=aobs_
	vars['aobs']=aobs
		lookahead_n=lookahead_n_
		vars['lookahead_n']=lookahead_n
	parts=parts_
	vars['parts']=parts
		module_names=module_names_
		vars['module_names']=module_names
	newmem_name=newmem_name_
	vars['newmem_name']=newmem_name
		newmem_size=newmem_size_
		vars['newmem_size']=newmem_size

	local b, r = pcall(do_inject)

	b, r = pcall(check_inj)
	if vars ~=nil and vars['address_dec']~=nil then
		local frm = getMemoryViewForm()
		local hv = frm.DisassemblerView
		frm.Show()
		hv.TopAddress = vars['address_dec']
		hv.SelectedAddress = vars['address_dec']
	end
	unpause()

end

local function dump_vars(ref)
	tprint(opcode_inj[ref])
end

local function do_nop()
	local opa=instruction_address(pattern,aobs,0,{},module_names)
	for k, v in pairs(opa) do
		vars[k]=v
	end
	vars.instruction_size=getInstructionSize(vars.address_string)
	vars['address_dec']=vars['address_dec']-vars.instruction_size
	vars['address_string']=checkAdressOffset_ret_string(vars['address_dec'])

	vars.nops=vars.instruction_size
	vars.nop_text=str_concat_rep('nop',vars.nops,'\n')
	vars.nopped_instruction=vars.og_instruction
	local enb_jmp_size=[[
		registersymbol(${inj_name})
		define(${inj_name},${address_string})

		${inj_name}:
		  ${nop_text}

	]]
	local dedollar=string_Dollar(enb_jmp_size,vars)
	local nop_ntk=string_variFormat(dedollar.string,dedollar.args)
	autoAssemble(nop_ntk)
	-- CORRECT INJECTION!!
	 opcode_inj[vars.script_ref]=vars
end

local function nop(script_ref_,inj_name_,vars_,pattern_,aobs_,module_names_)

	pause()
		vars=vars_

		script_ref=script_ref_
	vars['script_ref']=script_ref
		inj_name=inj_name_
		vars['inj_name']=inj_name
	pattern=pattern_
	vars['pattern']=pattern
	aobs=aobs_
	vars['aobs']=aobs
		module_names=module_names_
		vars['module_names']=module_names

	local b, r = pcall(do_nop)
	if vars ~=nil and vars['address_dec']~=nil then
		local frm = getMemoryViewForm()
		local hv = frm.DisassemblerView
		frm.Show()
		hv.TopAddress = vars['address_dec']
		hv.SelectedAddress = vars['address_dec']
	end
	unpause()

end
 
 opcode_inj['inject']=inject
 opcode_inj['disable']=disable
 opcode_inj['disable_nop']=disable_nop
 opcode_inj['dump']=dump_vars
 opcode_inj['nop']=nop
