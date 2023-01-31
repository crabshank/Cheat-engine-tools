local print=print

local count=0
local hits={}
local currTraceDss={}
local st={}
local hp={}
local prog=false
local first=false
local addr=0
local addr_hx=0
local hpp={}
local stp=false
local trace_info=''
local forceSave=''
local sio=''

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
	if a==nil or  a<0 then
		print('Argument "a" must be >=0')
		return
	end
	if type(n)=='string' and n~=nil and n~='' then
		forceSave=n
	else
		forceSave=''
	end
	addr=a
	addr_hx=string.format('%X',a)
	hits={}
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
	debug_setBreakpoint(a, 1, bptExecute)
end

local function get_disassembly(hi,i)
	local hisx=string.format('%X',hi)
	local h=hp[hisx]
	
	if i==1 or h==nil then
		local dst = disassemble(hi)
		local extraField, opcode, bytes, address = splitDisassembledString(dst)
		local a = getNameFromAddress(address) or ''
		local pa=hisx .. ' ( ' .. a .. ' )'
		
		if a=='' then
			pa=hisx
		end
		local prinfo=string.format('%s:\t%s  -  %s', pa, bytes, opcode)
		if extraField~='' then
			prinfo=prinfo .. ' (' .. extraField .. ')'
		end
		h={1,hi,hisx,prinfo,pa,bytes,opcode,extraField}
		hp[hisx]=h
	elseif h~=nil then
		h[1]=h[1]+1
	end

	return {['order']=i, ['count']=h[1], ['address']=h[2], ['address_hex_str']=h[3], ['prinfo']=h[4], ['address_str']=h[5], ['bytes']=h[6], ['opcode']=h[7], ['extraField']=h[8]}

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
				table.insert(pt,stn3i['prinfo'])
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
	if count==hl then
		trace_info=addr_hx .. ', ' .. count .. ' steps, ' .. sio
	else
		trace_info=addr_hx .. ', ' .. hl .. ' steps (' .. count .. ' specified),' .. sio
	end
	currTraceDss={hits,ds,hpp,trace_info,hp,hpp_a}
	
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

local function query(a,n)
	local ta={}
	local qt={}
	local typa=type(a)
	if typa=='table' then
		ta=a
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

local function onBp()
		if prog==true then
				if first ==true then
					debug_removeBreakpoint(addr)
					first=false
					print('Breakpoint at ' .. addr_hx .. ' hit!')
				end
				
				count=count-1
				
				if count>=0 then
					table.insert(hits,RIP)
					
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