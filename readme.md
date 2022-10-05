## CETRACE reader x64.html

Load a .cetrace file, wait, and it will finish loading.

Clicking on the opcode line (above RAX) in different places (check the tooltip), will highlight the current all latter instances and the same goes for the registers.

The "Jump to..." buttons allow the user the jump to the next time a highlighted value changes.

"Remove tracking on all instructions" un-highlights everything.

N.B. traces with thousands of steps will use a lot of memory.

***

## Disassembler mnemonics.lua

Simply paste the file into your autorun folder, and it will put the instructions' mnemonics in the "Comments" column in the disassembler.

N.B. place your own comments before the "〈" character.

## Hex Converter

Paste space-separated byte hex into the text area and wait for the processing to end. This is designed to make spotting struct values easier.

N.B.

*Click on a byte in the textarea or double click on the line for an address to prime the button "Set byte #..." to make this the base.

*Click on a line to highlight it (not just on hover).
