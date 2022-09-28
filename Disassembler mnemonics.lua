-- Disassembler mnemonics - crabshank

local function displayMnemonics()
  local visDis = getVisibleDisassembler()

  function f(sender, address, LastDisassembleData, result, description)
    if not sender.syntaxHighlighting then return end
	setComment(LastDisassembleData.address,'〈' .. LastDisassembleData.description .. '〉 %s' )
    return result,description
  end

  visDis.OnPostDisassemble = f

end

displayMnemonics()
