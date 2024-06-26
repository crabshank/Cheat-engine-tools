-- Disassembler mnemonics - crabshank
local procID=getOpenedProcessID()

local string=string
local string_match=string.match
local string_format=string.format

local function trim_str(s)
	return string_match(s,'^()%s*$') and '' or string_match(s,'^%s*(.*%S)')
end

local function string_match_t(s,p)
	return trim_str(string_match(s,p))
end

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
	local st2={}
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

	shfs['rol']=function(op,nimm)
        if nimm==true then
            return string.format('Rotate bits (position: n -> n+%s)',op)
        end
		return string.format('Rotate bits (position: n -> n+%d)',op)
	end
	shfs['ror']=function(op,nimm)
        if nimm==true then
            return string.format('Rotate bits (position: n -> n-%s)',op)
        end
		return string.format('Rotate bits (position: n -> n-%d)',op)
	end
	shfs['shl']=function(op,nimm)
        if nimm==true then
            return string.format('Shift bits (position: n -> n+%s)',op)
        end
		return string.format('Shift bits (position: n -> n+%d)',op)
	end
	shfs['sal']=shfs['shl']
	
	shfs['shr']=function(op,nimm)
        if nimm==true then
            return string.format('Shift bits (position: n -> n-%s)',op)
        end
		return string.format('Shift bits (position: n -> n-%d)',op)
	end
	shfs['sar']=function(op,nimm)
        if nimm==true then
            return string.format('Shift bits, but disregard sign bit (position: n -> n-%s)',op)
        end
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
					st[stl]='and '..st[stl]
				end
				s=table.concat(st,', ')
				return 'Clear all '..by..' except: '..s
			end
		else
			return 'If the nth bit of '..op2..'~=1, then clear the nth bit of '..op1
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
				if stl>1 or (stl==1 and r[1][1][1]~=r[1][1][2]) then
					by='bits'
				end
				local s=''
				if stl>2 then
					st[stl]='and '..st[stl]
				end
				s=table.concat(st,', ')
				return s..' '..by..'==0?'
			end
		elseif op1==op2 then
			return op1..'==0? '..op1..'<0? Parity?'
		else
			return 'Get the positions of the "1" bits in '..op2..', do all the bits in those positions of '..op1..'==0?'
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
				if stl>1 or (stl==1 and r[1][1][1]~=r[1][1][2]) then
					by='bits'
				end
				local s=''
				if stl>2 then
					st[stl]='and '..st[stl]
				end
				s=table.concat(st,', ')
				return 'Invert: '..s..' '..by
			end
		elseif op1==op2 then
			return 'Clear '..op1
		else
			return 'If the nth bit of '..op2..'==1, then invert the nth bit of '..op1
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
				if stl>1 or (stl==1 and r[1][1][1]~=r[1][1][2]) then
					by='bits'
				end
				local s=''
				if stl>2 then
					st[stl]='and '..st[stl]
				end
				s=table.concat(st,', ')
				return 'Set: '..s..' '..by..' to 1'
			end
		else
			return 'If the nth bit of '..op2..'==1, then set the nth bit of '..op1..' to 1'
		end
	end
	
local round = function(a, prec)
    return math.floor(a + 0.5*prec)
end

local getBits= function (num, asTable,paddTable)
							local x = {}
							if num==0 then
								if asTable==true then
									x={0}
									if paddTable~=nil then
										for i=#x+1, paddTable do
											x[i]=0
										end
									end
									return x
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
								if paddTable~=nil then
									for i=#x+1, paddTable do
										x[i]=0
									end
								end
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
			elseif opcd=='shufps' or opcd=='shufpd' then
					local dst = disassemble(address)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					
					local op1=string_match_t(instruction,'%s+([^,]+),.+')
					local op2=string_match_t(instruction,'%s+[^,]+,([^,]+)')
					local imm8=string_match_t(instruction,'%s+[^,]+,[^,]+,(.+)')
					
					local imm=tonumber(imm8,16)
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
							local bn=getBits(n_s,true,8)
							
							local msk={}
							local shf_txt=''
							local mask_cases={}
							if opcd=='shufps' then
								msk={
									tonumber(bn[1]..bn[2],2),
									tonumber(bn[3]..bn[4],2),
									tonumber(bn[5]..bn[6],2),
									tonumber(bn[7]..bn[8],2),
								}
								mask_cases={
									string_format('%s[0]:=%s[0] |',op1,op1),
									string_format('%s[0]:=%s[1] |',op1,op1),
									string_format('%s[0]:=%s[2] |',op1,op1),
									string_format('%s[0]:=%s[3] |',op1,op1)
								}
								shf_txt=mask_cases[msk[1]+1]
								
								mask_cases={
									string_format(' %s[1]:=%s[0] |',op1,op1),
									string_format(' %s[1]:=%s[1] |',op1,op1),
									string_format(' %s[1]:=%s[2] |',op1,op1),
									string_format(' %s[1]:=%s[3] |',op1,op1)
								}
								shf_txt=shf_txt..mask_cases[msk[2]+1]
								
								mask_cases={
									string_format(' %s[2]:=%s[0] |',op1,op2),
									string_format(' %s[2]:=%s[1] |',op1,op2),
									string_format(' %s[2]:=%s[2] |',op1,op2),
									string_format(' %s[2]:=%s[3] |',op1,op2)
								}
								shf_txt=shf_txt..mask_cases[msk[3]+1]
								
								mask_cases={
									string_format(' %s[3]:=%s[0]',op1,op2),
									string_format(' %s[3]:=%s[1]',op1,op2),
									string_format(' %s[3]:=%s[2]',op1,op2),
									string_format(' %s[3]:=%s[3]',op1,op2)
								}
								shf_txt=shf_txt..mask_cases[msk[4]+1]

								txt= txt..' || '.. shf_txt
							else -- shufpd
								if bn[1]==0 then
									shf_txt=string_format('%s[0]:=%s[0] |',op1,op1)
								else
									shf_txt=string_format('%s[0]:=%s[1] |',op1,op1)
								end
								if bn[2]==0 then
									shf_txt=shf_txt..string_format(' %s[0]:=%s[0]',op1,op2)
								else
									shf_txt=shf_txt..string_format(' %s[0]:=%s[1]',op1,op2)
								end
								txt= txt..' || '.. shf_txt
							end
						
			elseif shfs[opcd]~=nil then -- shift
					local dst = disassemble(address)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					
					local ops1=string_match_t(instruction,'%s+([^,]+),.+')
					local ops2=string_match_t(instruction,'%s+[^,]+,(.+)')
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
					else -- no immediate
                        ops2=string_match_t(instruction,'%s+[^,]+,(.+)')
                        txt= txt..' || '..shfs[opcd](ops2,true)
                    end
			elseif ops[opcd]~=nil then -- bitwise op
					local dst = disassemble(address)
					local extraField, instruction, bytes, address = splitDisassembledString(dst)
					
					local ops1=string_match_t(instruction,'%s+([^,]+),.+')
					local ops2=string_match_t(instruction,'%s+[^,]+,(.+)')
					local imm=tonumber(ops2,16)
					
					if imm==nil then --not immediate
							ops2=string_match_t(instruction,'%s+[^,]+,(.+)')
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

	local s=string_match(getComment(LastDisassembleData.address),"[^〈]*%s*〈" )
	if s ==nil then
		s="〈"
	end
	
	setComment(LastDisassembleData.address,s .. txt .. '〉 %s' )
	return result,description
end

visDis.OnPostDisassemble = f
