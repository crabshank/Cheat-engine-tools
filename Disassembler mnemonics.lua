-- Disassembler mnemonics - crabshank
local procID=getOpenedProcessID()

local string=string
local string_match=string.match

local visDis = getVisibleDisassembler()
local allDisassemblerNotes={}

local function get_nth(n)
	local ns=tostring(n)
	local lns=#ns
	local z=ns:sub(lns,lns)
	local z2=ns:sub(lns-1,lns)
	local a=ns:sub(1,lns-1)
	if lns==1 then
		a=''
		z2=''
	end
	if z=='1' and z2~='11' then
		return a..z..'st'
	elseif z=='2' and z2~='12' then
		return a..z..'nd'
	elseif z=='3' and z2~='13' then
		return a..z..'rd'
	else
		return a..z..'th'
	end
end

local function getOnes(bin)
	local r={}
	local rc=1
	for i=1,#bin do
		local bi=bin[i]
		if bi==1 then
			if r[rc]==nil then
				 r[rc]={i,i}
			else
				r[rc][2]=i
			end
		elseif #r>0 and r[rc]~=nil then
			rc=rc+1
		end
	end
	
	local st={}
	for i=1,#r do
		local ri=r[i]
		
		if ri[1]==ri[2] then
			table.insert(st,get_nth(ri[1]))
		else
			table.insert(st,get_nth(ri[1])..'-'..get_nth(ri[2]))
		end
	end
	return {r,st}
end

local shfs={}

	shfs['rol']=function(op)
		return string.format('Rotate bits (position: n -> n+%d)',op)
	end
	shfs['ror']=function(op)
		return string.format('Rotate bits (position: n -> n-%d)',op)
	end
	shfs['shl']=function(op)
		return string.format('Shift bits (position: n -> n+%d)',op)
	end
	shfs['sal']=shfs['shl']
	
	shfs['shr']=function(op)
		return string.format('Shift bits (position: n -> n-%d)',op)
	end
	shfs['sar']=function(op)
		return string.format('Shift bits, but disregard sign bit (position: n -> n-%d)',op)
	end

local ops={}

	ops['and']=function(imm,bin,op1,op2)
		if imm==true then
			local r=getOnes(bin)
			local st=r[2]
			local stl=#st
			if stl==0 then
				return 'Clear all bits'
			else
				local by='bits'
				local s=''
				if stl>2 then
					s=table.concat(st,', ')
				else
					s=table.concat(st,' ')
				end
				return 'Clear all '..by..' except: '..s
			end
		else
			return ''
		end
	end
	
	ops['test']=function(imm,bin,op1,op2)
		if imm==true then
			local r=getOnes(bin)
			local st=r[2]
			local stl=#st
			if stl==0 then
				return ''
			else
				local by='bit'
				if stl>1 then
					st[stl]='and '..st[stl]
					by='bits'
				end
				local s=''
				if stl>2 then
					s=table.concat(st,', ')
				else
					s=table.concat(st,' ')
				end
				return s..' '..by..'==0?'
			end
		else
			return op1..'==0? '..op1..'<0? Parity?'
		end
	end
	
	ops['xor']=function(imm,bin,op1,op2)
		if imm==true then
			local r=getOnes(bin)
			local st=r[2]
			local stl=#st
			if stl==0 then
				return ''
			else
				local by='bit'
				if stl>1 then
					st[stl]='and '..st[stl]
					by='bits'
				end
				local s=''
				if stl>2 then
					s=table.concat(st,', ')
				else
					s=table.concat(st,' ')
				end
				return 'Invert: '..s..' '..by
			end
		else
			if op1==op2 then
				return 'Clear '..op1
			else
				return ''
			end
		end
	end
	
	ops['or']=function(imm,bin,op1,op2)
		if imm==true then
			local r=getOnes(bin)
			local st=r[2]
			local stl=#st
			if stl==0 then
				return ''
			else
				local by='bit'
				if stl>1 then
					st[stl]='and '..st[stl]
					by='bits'
				end
				local s=''
				if stl>2 then
					s=table.concat(st,', ')
				else
					s=table.concat(st,' ')
				end
				return 'Set: '..s..' '..by..' to 1'
			end
		else
			return ''
		end
	end
	
local round = function(a, prec)
    return math.floor(a + 0.5*prec)
end

local getBits= function (num, asTable)
							local x = {}
							if num==0 then
								if asTable==true then
									return {0}
								else
									return '0'
								end
							end
							while num > 0 do
								rest = num % 2
								table.insert(x,round(rest,1e-15))
								num = (num - rest) / 2
							end
							if asTable==true then
								return x
							else
								return table.concat(x)
							end
				end
				
local function trim_str(s)
	return string_match(s,'^()%s*$') and '' or string_match(s,'^%s*(.*%S)')
end

function f(sender, address, LastDisassembleData, result, description)
	if not sender.syntaxHighlighting then return end
	
	local pid=getOpenedProcessID()
	
	if pid~=procID then
		procID=pid
		allDisassemblerNotes={}
	end
	local ads=tostring(address)
	local txt=LastDisassembleData.description
	if allDisassemblerNotes[ads]==nil or allDisassemblerNotes[ads].dss~=result then
		local opcd=trim_str(LastDisassembleData['opcode'])
			if opcd=='lea' then
				txt=txt..' || Load value in brackets into first operand'
			elseif shfs[opcd]~=nil then -- shift
					local dst = disassemble(address)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					
					local ops1=string_match(instruction,'%s+([^,]+)%s*,%s*.+')
					local ops2=string_match(instruction,'%s+[^,]+%s*,%s*([^%s]+)')
					local imm=tonumber(ops2,16)
					
					if imm~=nil then -- immediate
						local abs_imm= math.abs(imm)
						local b=1
						if abs_imm>1 then
							b=math.ceil((math.log( abs_imm ) / math.log( 2 )/8)) --bytes required to represent this number
						end
							local max_u=string.rep('FF',b)
							max_u=tonumber(max_u,16)
							local max_s=math.floor(max_u/2)
							local min_s=-(max_s+1)
							local n_s=imm
							if imm<0 then
								n_s=max_s+(imm-min_s)+1
							end
						txt= txt..' || '..shfs[opcd](n_s)
					end
			elseif ops[opcd]~=nil then -- bitwise op
					local dst = disassemble(address)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					
					local ops1=string_match(instruction,'%s+([^,]+)%s*,%s*.+')
					local ops2=string_match(instruction,'%s+[^,]+%s*,%s*([^%s]+)')
					local imm=tonumber(ops2,16)
					

					if imm==nil then --not immediate
							local ops1=string_match(instruction,'%s+([^,]+)%s*,%s*.+')
							local ops2=string_match(instruction,'%s+[^,]+%s*,%s*(.+)')
							local txt1=ops[opcd](false,nil,ops1,ops2)
							if ops1~=nil and ops2~=nil and txt1~='' then
								txt=txt..' || '..txt1
							end
					else --immediate
						local abs_imm= math.abs(imm)
						local b=1
						if abs_imm>1 then
							b=math.ceil((math.log( abs_imm ) / math.log( 2 )/8)) --bytes required to represent this number
						end
							local max_u=string.rep('FF',b)
							max_u=tonumber(max_u,16)
							local max_s=math.floor(max_u/2)
							local min_s=-(max_s+1)
							local n_s=imm
							if imm<0 then
								n_s=max_s+(imm-min_s)+1
							end
							local bn=getBits(n_s,true)
							local txt1=ops[opcd](true,bn,nil,nil)
							if txt1~='' then
								txt=txt..' || '..txt1
							end
					end
			end
			allDisassemblerNotes[ads]={dss=result, opcode=opcd,description=description, text=txt}
	else
		txt=allDisassemblerNotes[ads].text
	end

	local s=string.match(getComment(LastDisassembleData.address),"[^〈]*%s*〈" )
	if s ==nil then
		s="〈"
	end
	
	setComment(LastDisassembleData.address,s .. txt .. '〉 %s' )
	return result,description
end

visDis.OnPostDisassemble = f
