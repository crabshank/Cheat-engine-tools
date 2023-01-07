local count=0
local hits={}
local hp={}
local hps={}
local prog=false
local first=false
local addr=0
local hpp={}
local gm=nil
local mt=''

local function attach(a,c,t,m)
	if c==nil or c<0 then
		print('Argument "c" must be >=0')
		return
	end
	if a==nil or  a<0 then
		print('Argument "a" must be >=0')
		return
	end
	if t~=nil and type(t)~='string' then
		print('Argument "t" must be a string')
		return
	end	
	if m~=nil and m<1 then
		print('Argument "m" must be >=1')
		return
	end
	addr=a
	hits={}
	hp={}
	hps={}
	hpp={}
	count=c
	gm=m
	mt=t
	prog=true
	first=true
	debug_setBreakpoint(a, 1, bptExecute)
end

local function get_print_info(i)
	local ch=hits[i]
	local chs=tostring(ch)
	local h=hp[chs]
	local mtm=true
	if i==1 or h==nil then
		local chsx=string.format('%X',ch)
		local dst = disassemble(ch)
		local extraField, opcode, bytes, address = splitDisassembledString(dst)
		local a = getNameFromAddress(address) or ''
		local pa=chsx .. ' ( ' .. a .. ' )'
		
		if a=='' then
			pa=chsx
		else
			if mt~='' and string.match(a, mt)==nil then
				mtm=false
			end
		end
		
		if mtm==true then
			local prinfo=string.format('%s:\t%s  -  %s', pa, bytes, opcode)
			hp[chs]={1,ch,chsx,prinfo}
			table.insert(hps,chs)
		end
	elseif h~=nil then
		h[1]=h[1]+1
	end
end

local function printHits(m,t)
	for i=1, #hits do
		get_print_info(i)
	end
	hpp={}
	for i=1, #hps do
		table.insert(hpp,hp[hps[i]])
	end
	table.sort( hpp, function(a, b) return a[1] < b[1] end ) -- Converted results array now sorted by count (ascending);
	local hb=nil
	if m~=nil and m>=1 then
		local ic=1
		for i=1, #hpp do
			hb=hpp[i]
			if hb[1]>=m then
				print('#' .. ic .. ' (' .. hb[1] .. '):\t' ..hb[4])
				ic=ic+1
			end
		end
	else
		for i=1, #hpp do
				hb=hpp[i]
				print('#' .. i .. ' (' .. hb[1] .. '):\t' ..hb[4])
			end
	end
end

local function onBp()
		if prog==true then
		
				if first ==true then
					debug_removeBreakpoint(addr)
					first=false
				end
				
				count=count-1
				
				if count>=0 then
					table.insert(hits,RIP)
					debug_continueFromBreakpoint(co_stepinto)
				else
					debug_continueFromBreakpoint(co_run)
					prog=false
					printHits(gm)
				end
		end
end

function debugger_onBreakpoint()
	onBp()
end

traceCount={
	attach=attach,
	printHits=printHits
}