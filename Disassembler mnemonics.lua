-- Disassembler mnemonics - crabshank

local function displayMnemonics()
  local visDis = getVisibleDisassembler()

  function f(sender, address, LastDisassembleData, result, description)
    if not sender.syntaxHighlighting then return end
	local s=string.match(getComment(LastDisassembleData.address),"[^〈]*%s*〈" )
	if s ==nil then
		s="〈"
	end
	setComment(LastDisassembleData.address,s .. LastDisassembleData.description .. '〉 %s' )
    return result,description
  end

  visDis.OnPostDisassemble = f

end

displayMnemonics()
