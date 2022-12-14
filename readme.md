## attachBpLog.lua

#### Log registers at a breakpoint, then print those registers if another breakpoint is hit. Used to provide extra data from earlier in the program's execution. Set a breakpoint on code that you know runs before the breakpoint you set with Cheat Engine's GUI. Useful for shared opcodes.

To use: place the the file into your autorun folder, open the LUA Engine and type in 'attachBpLog.' (without quotes), and then it will show you the methods listed below: 

### Methods on (attachBpLog.…): 

* **attachBp(a)** -> Attach logging breakpoint to address a

* **dumpRegisters()** -> Force dump last stored registers to output (Not recommended to use; done after Cheat Engine GUI set breakpoint hit, anyway.)

* **removeAttachedBp()** -> Remove attached breakpoint


## proxValues.lua

#### To find multiple values that lie in an area of memory of max size *m* bytes or an unlimited number of bytes (argument of 'proxValues.fullScan(m)', below).

To use: place the the file into your autorun folder, open the LUA Engine and type in 'proxValues.' (without quotes), and then it will show you the methods listed below: 

### Methods on (proxValues.…): 

* **addMemScan()** -> Add result of memory scan to the script, for processing.

* **resetAllResults()** -> Reset everything.

* **removeResult(i)** -> Remove the i-th memscan result from the script

* **printFiltered( n,m --[[Optional]] )** -> Print filtered results (usually done after a scan anyway):

         printFiltered(n) : Print all results with max. memory area size <=n
   
         printFiltered(n,m) : Print all results with max. memory area size >=n and <=m
    
         printFiltered(): Print all results

* **fullScan( m --[[Optional]] )** -> Go through all added memscan results to find all instances where a result of all the memscans are found in an area of memory of max size *m* bytes (*m* must be positive integer >=1), or an unlimited size of memory if no argument is specified.

* **narrowDown( n --[[Optional]] )** -> If you have done a full scan and then added another memscan result, use this to further filter the results given by 'fullScan(m)'

        narrowDown(n) : Only keep and output results with max. memory area size <=n
        
        narrowDown() : Use previous memory area size

***

## CETRACE reader x64.html

Load a .cetrace file, wait, and it will finish loading.

Clicking on the opcode line (above RAX) in different places (check the tooltip), will highlight the current all latter instances and the same goes for the registers.

The "Jump to..." buttons allow the user the jump to the next time a highlighted value changes.

"Remove tracking on all instructions" un-highlights everything.

N.B. traces with thousands of steps will use a lot of memory.

***

## Disassembler mnemonics

Simply paste the file into your autorun folder, and it will put the instructions' mnemonics in the "Comments" column in the disassembler.

N.B. place your own comments before the "〈" character.

***

## Hex viewer

Paste space-separated byte hex into the text area and it shows the data converted to a type of your choosing.

N.B.

* This is much faster than "Hex converter".

* Hovering over the (converted) bytes highlights them.

* Use of dark mode in your browser may make the colour the the underline in the display of the RGB byte hex the accurate one (rather than the background or border colour).

***

## Hex converter

Paste space-separated byte hex into the text area and wait for the processing to end. This is designed to make spotting struct values easier.

N.B.

* Click on a byte in the textarea or double click on the line for an address to prime the button "Set byte #..." to make this the base.

* Click on a line to highlight it (not just on hover), or use the auto highlighting button to search for lines matching your specfied conditions and then press the auto-higlight button.
  
* You can generate a cheat table containing all the highlighted values. To add names to the addreses, edit the text box saying "base +/- …" and to change "base", select the base address and change its name. 'Group name' describes what the values are for, e.g. character struct. Change the array of bytes to on starting from the base address. Leaving the 'module name' box blank may give better results.
