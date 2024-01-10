local function trim_str(s)
	return string.match(s,'^()%s*$') and '' or string.match(s,'^%s*(.*%S)')
end

function tprint(tbl, indent)

	local function actualPrint(k,v,indent,notTable,do_tprint,zero)
			local formatting=''
	if notTable~=true or zero==true then
		formatting = string.rep("	", indent) .. k .. ": "
	 end
	  local typv=type(v)
	  if typv == "table" then
		print(formatting)
		do_tprint(v, indent+1)
	  elseif typv == 'userdata' then
			local noEls=true
			local propertyList=getPropertyList(v)
			local plc=propertyList.Count
			if plc>0 then
				local plt={}
				for i=0, plc-1 do

					local pli=propertyList[i]
					local typ=type(pli)

					local nm=''
					if typ=='string' then
						plt[i]=pli
						noEls=false
					elseif type(pli.Name)=='string' then
						   nm=pli.Name
						   plt[nm]=pli
						   noEls=false
					end
				end
				propertyList.destroy()
				if noEls==false then
					local vn=v.Name
					if type(vn)=='string' and trim_str(vn)~='' then
						formatting = string.rep("	", indent) ..vn.. ": "
						print(formatting)
						do_tprint(plt, indent+1)
					else
						local lk=k..': '
						if notTable==true then
							lk=''
						end
						local fmi= string.rep("	", indent)
						formatting =fmi..lk.."{"
						print(formatting)
						do_tprint(plt, indent+1)
						print(fmi..'}')
					end
				end
			else
				propertyList.destroy()
			end

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

  local function do_tprint(tbl, indent,notTable) -- https://gist.github.com/ripter/4270799
	if notTable==true then
		tbl={tbl}
		indent = 0
	else
		if not indent then indent = 0 end
	end
	if tbl[0]~=nil then
		local nt=false
		if type(tbl[0])~=table then
			nt=true
		end
		actualPrint(0,tbl[0],indent,nt,do_tprint,true)
	end
	for k, v in pairs(tbl) do
		if k~=0 then
			actualPrint(k,v,indent,notTable,do_tprint)
		end
	end
  end

  local notTable=false
  local tyb=type(tbl)
  if tyb~='table' then
	notTable=true
  end

  do_tprint(tbl,indent,notTable)
  print('\n')
end
