	local print=print
	local upperc=string.upper
	local string_gmatch=string.gmatch
	local string_match=string.match

	function tprint(tbl, indent)
	  local function do_tprint(tbl, indent) -- https://gist.github.com/ripter/4270799
		if not indent then indent = 0 end
		for k, v in pairs(tbl) do
		  formatting = string.rep("	", indent) .. k .. ": "
		  if type(v) == "table" then
			print(formatting)
			do_tprint(v, indent+1)
		  elseif type(v) == 'boolean' then
			print(formatting .. tostring(v))
		  elseif type(v) == 'string' then
			local la, lb=string.find(v, "\n")
			if la==nil then
				print(formatting .. '"'.. v ..'"')
			else
				print(formatting .. '[['.. v ..']]')
			end
		  else
			print(formatting .. v)
		  end
		end
	  end
	  do_tprint(tbl,indent)
	  print('\n')
	end

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

	local count=0
	local hits={}
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

	local function getAccessed(opcode)
		local t={ {}, {} }
		local mtc="%[%s*[^%]]+%s*%]" -- [...]
		local mtc2="%[%s*([^%]]+)%s*%]" -- [(...)]

		for i in string_gmatch(opcode,mtc) do

			local a=string_match(i,mtc2)

			if a~=nil and a~='' then
				table.insert(t[2],i)
				table.insert(t[1],a)
			end
		end

		return t -- { { --[[ just the bracket contents ]] }, { --[[ full syntax "[...]" ]] } }
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
		hits_deref={}
		hits_deref_lookup={}
		hp={}
		hpp={}
		currTraceDss={}
		count=c
		stp=s
		sio='step into'
		if s==true then
			sio='step over'
		end
		prog=true
		first=true
		debug_setBreakpoint(abp[1][1], 1, bptExecute)
	end

	local function get_disassembly(hi,i)
		local hisx=string.format('%X',hi)
		local h=hp[hisx]

		if i==1 or h==nil then
			local hdi=hits_deref[i] -- {RIPx, { opcode,address,bytes,extraField, m_acc }, RIP}
					local hdi2=hdi[2]
			local extraField = hdi2[4]
			local opcode = hdi2[1]
			local bytes = hdi2[3]
			local address = hdi2[2]

			local a = getNameFromAddress(address) or ''
			local pa=hisx .. ' ( ' .. a .. ' )'

			if a=='' then
				pa=hisx
			end

			-- hdi2[5] == { asc[2][i], asc[1][i], r, rx  } ||  -- [1]={ --[[ just the bracket contents ]] },  [2]= { --[[ full syntax "[...]" ]] }

					local hdi2_5=hdi2[5]
					local hdi2_5_l=#hdi2_5
			local reffed_opcode=opcode

					if hdi2_5_l>0 then
			  for i=1, hdi2_5_l do
							   local hdi2_5_i=hdi2_5[i]
				  local m_refs=hdi2_5_i[1]
				  local m_refs_isol=hdi2_5_i[2]
							  if m_refs~=nil and m_refs_isol~=nil then
					local rep_with='[ '..m_refs_isol..' ('..hdi2_5_i[4]..' || '..hdi2_5_i[3]..') ]'
					reffed_opcode=plainReplace(reffed_opcode,m_refs,rep_with)
							  end
			  end
					end
			local prinfo=string.format('%s:\t%s  -  %s', pa, bytes, reffed_opcode)
			local prinfo_cnt=string.format('%s:\t%s  -  %s', pa, bytes, opcode)
			if extraField~='' then
				prinfo=prinfo .. ' (' .. extraField .. ')'
			end
			h={1,hi,hisx,prinfo,pa,bytes,opcode,extraField,prinfo_cnt}
			hp[hisx]=h
		elseif h~=nil then
			h[1]=h[1]+1
		end

		return { ['order']=i, ['count']=h[1], ['address']=h[2], ['address_hex_str']=h[3], ['prinfo']=h[4], ['prinfo_cnt']=h[9], ['address_str']=h[5], ['bytes']=h[6], ['opcode']=h[7], ['extraField']=h[8] }

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
			stnp=stn[2] -- table of disassembled addresses
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
				table.insert(pt,stn2i['prinfo'])
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

			for i=1, stl do
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
		currTraceDss={hits, ds, hpp, trace_info, hp, hpp_a, hits_deref, hits_deref_lookup}
	end

	local function runStop(b)
		prog=false
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
		-- qt={hits, ds, hpp, trace_info, hp, hpp_a,hits_deref,hits_deref_lookup}

		if s==true then -- accesses
			for i=1, #ta do
				local res={}
				local tai=ta[i]
				local taix=string.format("%X",ta[i])
				--local h_drf=qt[7]
				local h_drf_lk=qt[8] -- ['...']={ {RIPx, {...}, RIP, ix}, {...}, ... }
				local acs=h_drf_lk[taix]
				if acs~=nil then
					for k=1, #acs do
						table.insert(res,acs[k][4])
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
				local rcs=qt[6][hxa]
				if rcs~=nil then
					for k=2, #rcs do
						table.insert(pt,rcs[k])
					end
				end
				if #pt>0 then
					local sng='times'
					local ixs='indexes'
					local c=rcs[1]['count']
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
					print("First argument mus be a non-empty string")
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
			if abp[1]~=nil then
				local ai1=abp[1][1]
				local ai1_hx=abp[1][2]
			end
			if #abp>1 and RIP==ai1 then
				print('Breakpoint at ' .. ai1_hx .. ' hit!')
				debug_removeBreakpoint(ai1)
				table.remove(abp,1)
				debug_setBreakpoint(abp[1][1], 1, bptExecute)
				debug_continueFromBreakpoint(co_run)
			elseif prog==true then
					if first ==true then
						debug_removeBreakpoint(ai1)
						first=false
						print('Breakpoint at ' .. ai1_hx .. ' hit!')
					end

					count=count-1

					if count>=0 then
						table.insert(hits,RIP)
						local RIPx=string.format('%X',RIP)
						local deref={RIPx,{}}
						local dst = disassemble(RIP)
						local extraField, opcode, bytes, address = splitDisassembledString(dst)
						deref[2]={opcode,address,bytes,extraField,{}}
						--Get accessed memory addresses

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

						local asc=getAccessed(opcode)
						local m_acc={}
						local accessed_addrs={}
						for i=1, #asc[1] do
							local upca=upperc(asc[1][i])
							local func= load("return ".. upca)
							local b,r=pcall(func)

							if r~=nil and type(r)=='number' and math.tointeger (r)~=nil then
								local rx=string.format('%X',r)
								local mt={ asc[2][i], asc[1][i], r, rx  } -- [1]={ --[[ just the bracket contents ]] }
								table.insert(accessed_addrs,rx)
								-- [2]= { --[[ full syntax "[...]" ]] }
								table.insert(m_acc,mt)
							end
						end

						restoreGlobals()

						deref[2][5]=m_acc --List of accessed memory addresses; table of tables
						table.insert(deref,RIP) -- add index: {RIPx, { opcode,address,bytes,extraField, m_acc }, RIP}
						table.insert(hits_deref,deref) -- hits_deref is a table of tables (full local scope)
						table.insert(deref,#hits) -- add index: {RIPx, { opcode,address,bytes,extraField, m_acc }, RIP, ix}; JUST FOR LOOKUP!
						for j=1, #accessed_addrs do
							local aj=accessed_addrs[j]
							if hits_deref_lookup[ aj ]==nil then
								hits_deref_lookup[ aj ] = {deref} --table of tables { {} }
							else
								table.insert( hits_deref_lookup[ aj ] , deref) -- { {}, {}, ... }
							end
						end

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

	function debugger_onBreakpoint()
		onBp()
	end

traceCount={
	attach=attach,
	stop=stop,
	printHits=printHits,
	save=save,
	saved=saved,
	compare=compare,
	delete=delete,
	query=query
}