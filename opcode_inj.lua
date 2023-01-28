opcode_inj={}

local script_ref,inj_name,newmem_name,newmem_size,vars,inj_script,pattern,aobs,lookahead_n,parts,module_names

local function giveModuleAndOffset(address) -- https://github.com/cheat-engine/cheat-engine/issues/205 (mgrinzPlayer)
  local modulesTable,size = enumModules(),0
  for i,v in pairs(modulesTable) do
      size = getModuleSize(v.Name)
      if address>=v.Address and address<=v.Address+size then
        return {v.Name..'+'..string.format('%X',address-v.Address),v.Name}
      end
  end
  return {address,''}
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

local function tprint (tbl, indent) -- https://gist.github.com/ripter/4270799
  if not indent then indent = 0 end
  for k, v in pairs(tbl) do
    formatting = string.rep("	", indent) .. k .. ": "
    if type(v) == "table" then
      print(formatting)
      tprint(v, indent+1)
    elseif type(v) == 'boolean' then
      print(formatting .. tostring(v))
    else
      print(formatting .. v)
    end
  end
end

--[[local function safeString(s,not_escape)
	local ls=string.len(s)
	local st={}
	local spl={}
	for i=1, ls do
		table.insert(spl,string.sub(s,i,i))
	end
	if not_escape==true then
		local i=1
		while i< ls do
			local si=spl[i]
			local si2= spl[i+i]
			if si=='\\' and si2=="n" then
				st[i]=string.char(13)
				st[i+1]=""
				i=i+2
			elseif si=='\\' and si2=="'" then
				st[i]=string.char(39)
				st[i+1]=""
				i=i+2
			else
				st[i]=si
				i=i+1
			end
		end
	else
			for i=1, ls do
				local si=spl[i]
				if si==string.char(13) or si==string.char(10) then
					st[i]='\\n'
				elseif si==string.char(39) then
					st[i]="\\'"
				else
					st[i]=si
				end
			end
	end
        return table.concat(st,'')
end]]

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

local function child_els_index(t,ix)
      local out={}
      for i=1, #t do
          table.insert(out,t[i][ix])
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

local function fullMatchesReplace(s,r,w,notAll)
	local ls=string.len(s)
	local spl={}
	for i=1, ls do
		table.insert(spl,{string.sub(s,i,i),false})
	end
	local ended=false
	local x=1
	while ended==false do
        local fss=''
		local i,j=string.find(s,r,x)

		if i==nil then
			ended=true
		else
			local fs=child_els_index(get_subtable(spl,i,j),1)
			local fst=table.concat(fs,'')
			fss=string.match(fst,w)
			x=i+1
			if notAll==true then
				x=j+1
			end
			if fss~=nil then
				local c=1
				for k=i, j do
					if c==1 then
						spl[k][1]=fss
						spl[k][2]=false
					else
						spl[k][1]=''
						spl[k][2]=true
					end
				   c=c+1
				end
			end
		end
		if x>ls then
			ended=true
		end
	end
	local out={}
	for i=1, ls do
		local spli=spl[i]
		if spli[2]==false then
			table.insert(out,spli[1])
		end
	end
	return table.concat(out,'')
end

local function plainReplace(s,r,w,n)
      local ls=string.len(s)
      local lp=string.len(r)
      local c=0
      local se=ls-lp+1
      for i=1, se do
          local sse=i+lp-1
          local sbs=string.sub(s,i,sse)
          if sbs==r then
             c=c+1
          end
          if c==n then
             local out={}
             local prev=i-1
             if i==1 then
                table.insert(out,w)
             else
                 table.insert(out,table.concat({string.sub(s,1,prev),w},''))
             end

             if sse~=ls then
                 table.insert(out,table.concat({string.sub(s,sse+1,ls)},''))
             end
             return table.concat(out,'')
          end
      end
      return s
end

local function string_Dollar(s,t)
  tfmt = {['string']='',['tokens']={},['args']={}}
  local out=''
  local mtc="%$%%[^%{]+%{%s*[^%}]+%s*%}"
  local mtc2="%$(%%[^%{]+)%{%s*[^%}]+%s*%}"
  local mtc3="%$%%[^%{]+%{%s*([^%}]+)%s*%}"
  tfmt['string']=fullMatchesReplace(s,mtc,mtc2,true)
  for i in string.gmatch(s,mtc) do
        local ag=string.match(i,mtc3)
        local tk=string.match(i,mtc2)
        table.insert(tfmt['tokens'],tk)
        table.insert(tfmt['args'],t[ag])
  end
  return tfmt
end

local function str_concat_rep(s,n,p)
	local out={}
	for i=1, n do
		table.insert(out,s)
	end
	return table.concat(out,p)
end

local function getLookaheads(k,lookahead_n,opcode)
		local lookaheads={['offsets']={0},['opcodes']={opcode}}
		local szk=getInstructionSize(k)

		local lbc=szk -- running byte count
		local offset_inst=k+szk --running byte count + address
		while lbc<lookahead_n+1 do
			table.insert(lookaheads['offsets'],lbc) --start (offset) of next opcode

			szk=getInstructionSize(offset_inst) -- size of next opcode

			local dsk_off = disassemble(offset_inst)
			local extraField_off, opcode_off, bytes_off, address_off = splitDisassembledString(dsk_off)
			table.insert(lookaheads['opcodes'],opcode_off) -- insert next opcode

			lbc=lbc+szk -- running byte count
			offset_inst=offset_inst+szk --running byte count + address
		end

		return lookaheads
end

local function opcode_address(pattern,aobs,lookahead_n,parts,module_names)
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
          local aob_list=AOBScan(bi[1], "", 0)
          local aob_count=aob_list.Count

          for j=1,aob_count do
            local res=aob_list[j-1]
            local dec_res=tonumber(res,16)
            local rb=dec_res+bi[2]
            if rb<0 then
               rb=0
            end
	    local rf=dec_res+bi[3]
            for k=rb, rf do
                local dsk = disassemble(k)
				local extraField, opcode, bytes, address = splitDisassembledString(dsk)
				local a = checkAdressOffset_ret_string(k,address)
                local mb=true
                local mdn={}
                if module_names~=nil then
                   mb=false
                   local tmn=type(module_names)
                   if tmn=='string' then
                      mdn[1]=module_names
                  elseif tmn=='table' then
                     mdn=module_names
                   end
                   local mdnl=#mdn
                   for m=1, mdnl do
                       local mdnm=mdn[m]
                       if string.find(a, mdnm, 1,true)~=nil then
                          mb=true
                          m=mdnl
                       end
                   end
                end
                if string.match(opcode,pattern)~=nil and mb==true then
					local pt={}
					if parts~=nil then
						for p=1,parts_tt_l do
						   local pttp=parts_tt[p]
						   table.insert(pt,{pttp[3],string.match(opcode, pttp[4])})
						end
					end

                                        local byt=readBytes(dec_res,lookahead_n+1,true)
					local hexByteTable={}
					if type(byt) =='table' then
                                           for i=1,#byt do
					       table.insert(hexByteTable,string.format('%02X',byt[i]))
                                           end
					end

				   local lookaheads=getLookaheads(k,lookahead_n,opcode)

                   local fda=fnd[a]
                   if fda==nil then
						fnd[a]={dec_res,res,1,a,pt,lookaheads,opcode,hexByteTable,byt} -- {decimal address, numeric address, counter, lookup string, parts table of strings, lookahead hex, matched opcode}
                   else
						fnd[a][3]=fda[3]+1 -- counter
                   end
                   k=rg --EARLY TERMINATE!
                end
            end
          end
		  	  aob_list.destroy()
      end

      for key, value in pairs(fnd) do
		table.insert(fnd_it,value) -- create sortable table
      end

      table.sort( fnd_it, function(a, b) return a[3] > b[3] end ) -- Converted results array now sorted by count (descending);
      local f1=fnd_it[1]

      local outp= {['og_bytes_dec']=f1[9],['og_hex']=f1[8],['address_dec']=f1[1], ['address_string']=f1[4] ,['lookaheads']=f1[6],['opcode']=f1[7]}
	  if parts~=nil then
		  -- Spread parts arry
		  for i=1, #f1[5] do
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
			$%s{deallc_txt}
			$%s{unregsy_txt}
			define($%s{inj_name},$%s{address_string})
			$%s{inj_name}:
			$%s{all_og_opcodes}
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
		unregistersymbol($%s{inj_name})
		define($%s{inj_name},$%s{address_string})
		$%s{inj_name}:
		  $%s{nopped_opcode}
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

	local opa=opcode_address(pattern,aobs,lookahead_n,parts,module_names)
	for k, v in pairs(opa) do
		vars[k]=v
	end
	vars.instruction_size=getInstructionSize(vars.address_string)

	local enb_jmp_size=[[
	define($%s{inj_name},$%s{address_string})
	alloc($%s{newmem_name},$%s{newmem_size},$%s{inj_name})

	$%s{inj_name}:
	  jmp $%s{newmem_name}
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
	local extraField_ci, opcode_ci, bytes_ci, addr_ci = splitDisassembledString(jmp_dss)
        vars['opcode_jmp']=opcode_ci
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
		 local offs_opc=vars['lookaheads']['opcodes']
		 local ovps={}
		 for i=1,vars.overlap do
			 table.insert(ovps,offs_opc[i+1])
		 end
		 vars.overwritten=table.concat(ovps,'\n')
	  end
	end

	dedollar=string_Dollar(inj_script,vars)
	enb_jmp_size_ntk=string_variFormat(dedollar.string,dedollar.args)

	autoAssemble(enb_jmp_size_ntk)
	-- CORRECT INJECTION!!
	 opcode_inj[vars.script_ref]=vars
end

local function check_inj()
        if vars==nil or vars['address_dec']==nil then
           return
        end
	local curr_lookahead=getLookaheads(vars['address_dec'],vars['lookahead_n'],vars['opcode_jmp'])
	local rst=false
	local c=1
	local clp=curr_lookahead['opcodes']
	local ogl=vars['lookaheads']['opcodes']
	vars['all_og_opcodes']=table.concat(ogl,'\n')
	for i=1, #clp do
		local opc=clp[i]
		if i==1 and string.match(opc,'^jmp%s*.+$')~=nil then
			c=c+1
		elseif i==1 then
			rst=true
			break
		elseif string.match(opc,'^%s*nop%s*$')==nil then
			if opc~=ogl[c] then
				rst=true
				break
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
	local opa=opcode_address(pattern,aobs,0,{},module_names)
	for k, v in pairs(opa) do
		vars[k]=v
	end
	vars.instruction_size=getInstructionSize(vars.address_string)
	vars['address_dec']=vars['address_dec']-vars.instruction_size
	vars['address_string']=checkAdressOffset_ret_string(vars['address_dec'])

	vars.nops=vars.instruction_size
	vars.nop_text=str_concat_rep('nop',vars.nops,'\n')
	vars.nopped_opcode=vars.opcode
	local enb_jmp_size=[[
		registersymbol($%s{inj_name})
		define($%s{inj_name},$%s{address_string})
		
		$%s{inj_name}:
		  $%s{nop_text}
	
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