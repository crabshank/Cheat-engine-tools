## logpoint.lua

#### Log specified registers at a breakpoint. Useful for shared opcodes.

To use: place the the file into your autorun folder, open the LUA Engine and type in 'logpoint.' (without quotes), and then it will show you the methods listed below: 

### Methods on (logpoint.…): 

* **attach( {a, c, p --[[Optional]] , bh --[[Optional]] , fw --[[Optional]] }, {…}, … )** -> Takes a series of tables, one for each address. Attach logging breakpoint to address *a* (Use '0x…' for addresses in hexadecimal). *c* is a string or table of strings specifying what to log (could be a (sub-)register or e.g. register*y+x or, XMM0-15 or FP0-7 (uppercase and case-senstive), depending on whether you're using x64 or x86. Use "0x…", again, for hex offsets e.g. "RAX+0xC". Sub-registers are also available (the variable names defined below "-- EXTRA SUB-REGISTERS AVAILABLE:", in the code). Also, the float registers are interpreted as byte tables, so using them with argument *p* is undefined behaviour). If *p* is set to **true**, then the string(s) in *c* is/are interpreted as a memory address(es)
 and the bytes from there will be logged. *bh* and *fw* extend the range of what is captured, e.g `logpoint.attach(0x14022E56F,'RCX',true,-0x40,0x60)` will log memory from [RCX-40] to [RCX+60] ([RCX-64] to [RCX+96] in decimal).
 
* **dumpRegisters( k --[[Optional]] )** -> Force dump last stored registers to output. Argument *k* is the index printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no argument specified, it will dump last stored registers for all breakpoints.

* **removeAttached( i --[[Optional]], b --[[Optional]] )** -> Remove attached breakpoint with address *i*, or, if b==true: the index *i* printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no arguments specified, it will remove all attached breakpoints.

* **stop()** -> Removes all breakpoints made by this extension and dump all the logged data in the console.

* **printAttached()** -> Print all attached breakpoints preceded by an index.

N.B. all data is displayed as arrays of bytes for convenience. I suggest pasting the data into a notepad, removing everything except the byte hex and pasting it into a hex editor/viewer.

## traceCount.lua

#### Attach a breakpoint to an address ("traceCount.attach(…)") and: print opcodes that are executed afterwards, sorted by the number of times they are executed or in the order in which they were executed. This is useful for finding repeating code e.g. single animations.

### Methods on (traceCount.…): 

* **attach( a, c, n --[[Optional]] , s --[[Optional]] )** -> Attach breakpoints to address *a* (Use '0x…' for addresses in hexadecimal), and keep logging for *c* steps afterwards ("step into/over"). If *n* is a specified, non-empty string, then it will save the trace by that string (see the *.saved()* method). If *s* is set to **true**, then the extension will "step over" (calls), otherwise it will "step into".

* **stop()** -> End the trace and print in ascending order of times executed.

* **printHits( m --[[Optional]] , n --[[Optional]], l --[[Optional]] , f --[[Optional]] , t --[[Optional]] )** -> If *m*==1: Prints all executed opcodes in the order they were executed "#…", and the number of times they have been executed, in parentheses; if *m*==0 or nil: Prints in ascending order of times executed. If *n* is a specified, non-empty string, then it will print the saved trace saved with that name (see *.saved()* method); if an empty string it will print the current trace. If *l* (integer) if specified, the extension will only print opcodes that have been executed >=*l* times, unless printing in the order of execution. If *m==1*, then *f* and *t*, if specified prints from the *f*th breakpoint hit to the *t*th.

* **save(n)** -> Save the current trace with the name of the non-empty string *n*

* **saved()** -> Print the names and information of saved traces.

* **compare(...)** -> Takes a series of strings -> *1st*: The name to save the comparison with; *2nd*: The trace from which to take information for the adresses present in all compared traces (*2nd string and beyond*). The output trace can be printed with *.printHits(…)* like any other.

* **delete( n --[[Optional]] )** -> If n is a string matching the name of a saved trace, it will delete that trace. If n is unspecified, it will delete all saved traces.

## batchRW.lua

#### Simply attach breakpoints to selected addresses ("batchRW.attach(…)") and: print the addresses and turn them yellow in the address list if they are read or written to ("writeTo" argument in "batchRW.attach(…)").

### Methods on (batchRW.…): 

* **attach(s, z --[[Optional]] , onWrite --[[Optional]] )** -> Attach breakpoints to address *s* (Use '0x…' for addresses in hexadecimal) (if eligible, otherwise will be attached to the next eligible address) ("Index" printed by "batchRW.printAddrs()") and *z*-1 eligible addresses after it (*z* in total, probably will not work if >4). If *z* is not specified, it will be set to 1. If "onWrite"==true, then it breaks if the address is written to, otherwise it breaks if the address is read.

* **printAddrs()** -> Print all attachable addresses in the address list, with their indexes for "batchRW.attach(…)".

* **detachAll()** -> Remove all breakpoints set by this extension.

## attachBpLog.lua

#### Log registers at a breakpoint, then print those registers if another breakpoint is hit. Used to provide extra data from earlier in the program's execution. Set a breakpoint on code that you know runs before the breakpoint you set with Cheat Engine's GUI. Useful for shared opcodes.

#### Currently only outputs 64-bit raw hex data.

To use: place the the file into your autorun folder, open the LUA Engine and type in 'attachBpLog.' (without quotes), and then it will show you the methods listed below: 

### Methods on (attachBpLog.…): 

* **attachBp(t)** -> Attach logging breakpoint to address *t* (Use '0x…' for addresses in hexadecimal), or, a table of addresses *t*.

* **dumpRegisters( k --[[Optional]] )** -> Force dump last stored registers to output (Not recommended to use; done after Cheat Engine GUI set breakpoint hit, anyway). Argument *k* is the index printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no argument specified, it will dump last stored registers for all breakpoints.

* **removeAttachedBp( i --[[Optional]], b --[[Optional]] )** -> Remove attached breakpoint with address *i*, or, if b==true: the index *i* printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no arguments specified, it will remove all attached breakpoints.

* **printAttached()** -> Print all attached breakpoints preceded by an index.

## proxValues.lua

#### To find multiple values that lie in an area of memory of max size *m* bytes or an unlimited number of bytes (argument of 'proxValues.fullScan(m)', below).

To use: place the the file into your autorun folder, open the LUA Engine and type in 'proxValues.' (without quotes), and then it will show you the methods listed below: 

### Methods on (proxValues.…): 

* **addMemScan()** -> Add result of memory scan to the script, for processing.

* **resetAllResults()** -> Reset everything.

* **removeResult(i)** -> Remove the i-th memscan result from the script

* **printFiltered( n --[[Optional]], m --[[Optional]] )** -> Print filtered results (usually done after a scan anyway):

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

* Use of dark mode in your browser may sometimes make the colour the the underline in the display of the RGB byte hex the accurate one (rather than the background or border colour).

***

## Hex converter

Paste space-separated byte hex into the text area and wait for the processing to end. This is designed to make spotting struct values easier.

N.B.

* Click on a byte in the textarea or double click on the line for an address to prime the button "Set byte #…" to make this the base.

* Click on a line to highlight it (not just on hover), or use the auto highlighting button to search for lines matching your specfied conditions and then press the auto-higlight button.
  
* You can generate a cheat table containing all the highlighted values. To add names to the addreses, edit the text box saying "base +/- …" and to change "base", select the base address and change its name. 'Group name' describes what the values are for, e.g. character struct. Change the array of bytes to on starting from the base address. Leaving the 'module name' box blank may give better results.
