## maxScan.lua

Change the "Memory Scan Options" to search over the maximum area by default.

## opcode_inj.lua

**N.B.** When the code injection is successful: the extension will show the memory browser at the injection point; if there was no found address, then it won't. If there is a syntax error with the injection script, the extension will print it in the LUA Engine.

* **inject(script_ref, inj_name, newmem_name, newmem_size, vars, inj_script, pattern, aobs, lookahead_n, parts, module_names)**

  * **vars**: A table in the extension's global scope that can hold any data with any name (key) you like, but the extension adds or expects data with the following keys:

```
[ post[…]: use numeric indexes here to run functions assigned to them to run before the "$%s{…}" syntax is first processed. You can write a whole list of instructions as one token (see example script below!) (set by user) ]

[ instruction_size: the size of the found opcode in bytes (decimal) (set by extension) ]
[ address_string: a string representing the address of the found opcode, usually "module.…+offset" (set by extension) ]
[ jmp_size: size of the jmp instruction, placed at the location of the found opcode, that diverts the code to your injected code in bytes (decimal) (set by extension) ]
[ post_jmp: assembler text to be inserted after the injected jmp to avoid undesired opcodes appearing (set by extension) ]
[ overwritten: if the jmp instruction overwrites other instructions, this will replace them after your injected code (set by extension) ]
[ nops: number of nops required to keep the execution flow the same after injection (set by extension)]
[ overlap: number of opcodes overwritten by jmp (set by extension) ]
[ ['lookaheads'](['offsets']/['opcodes']): data ahead of the found opcode, to help with nops and overwites to help keep the execution flow the same (set by extension) ]
[ nopped_opcode: opcode nopped by the method 'disable_nop(…)' (set by extension) ]
[ opcode: the found opcode (at injection point) (set by extension) ]
[ og_bytes_dec: byte decimal table of matched opcode (set by extension) ]
[ og_hex: byte hex table of matched opcode (set by extension) ]
[ address_dec: address of found opcode in decimal (set by extension) ]
[ address_string: address of found opcode as a hex string (set by extension) ]
[ unregsy_txt: text containing code to unregister all symbols registered by the cheat table (set by extension) ]
[ deallc_txt: text containing code to dealloc all memory allocated by the cheat table (set by extension) ]
[ opcode_jmp: the opcode of the jmp that redirects execution flow towards the injected code (set by extension) ]
[ all_og_opcodes: all orginal opcodes, pre-injection (set by extension) ]
[ nop_text: text containing number of nop instructions required to keep the execution flow the same after injection (set by extension) ]

[ THE BELOW ARE THE SAME AS THE ARGUMENTS FOR ".inject(…)": ]
[ inj_script ]
[ script_ref ]
[ inj_name ]
[ inj_script ]
[ pattern ]
[ aobs ]
[ lookahead_n ]
[ parts ]
[ module_names ]
[ newmem_name ]
[ newmem_size ]

```
  * **script_ref**: name to give the script so that it recognises a specific cheat table
  * **inj_name**: name to the injection point
  * **newmem_name**: name to give to the memory that stores the injected (redirected to) code
  * **newmem_size**: size of the memory that stores the injected (redirected to) code (STRING!: "$%s{newmem_size}"; INTEGER!: "$%d{newmem_size}")
  * **vars**: put data that you want to be accessible using the "$%s{…}" syntax here
  * **inj_script**: like Cheat engine's auto-assembler script, but it can also access the top level keys of the 'vars' table using the syntax e.g. ```$%s{key}``` for a string value in `vars[key]` (see LUA pattern notation: %s, %d, etc.)
  * **pattern**: a LUA string with a pattern that opcodes are checked against for matches.
  * **aobs**: a table or, table of tables, that contain `{'aob string', search from (string + this number), until (string + this number) }`
  * **lookahead_n**: at least this many bytes worth of opcodes will be stored, ahead of the found opcode.
  * **parts**: a table or, table of tables, that contain `{ a substring from your pattern , nth occurrence of this substring will be matched , name given to this part }`
  * **module_names**: a table or, table of tables: match only addresses with address strings (usually containing module name) that contain one of these strings.
  
* **disable(script_ref)**

Example script:

```
{$lua}
if syntaxcheck then return end
local vars={}
--OPTIONAL (Add as named element of 'vars' table to use in '$%s{...}' notation)
local suffix='_la'
vars.varis_1_n='mult'..suffix
vars.varis_1_d='dd (float)1\ndd (float)1\ndd (float)1\ndd (float)1'
vars.varis_1_size=16
local parts={{'[^%]]+',1,'localAddress'},{'%d+',1,'xreg_n'},{'xmm%d+',1,'x_reg'},{'mov.+',1,'mov_op'}}
local module_names='FL_2023.exe'
vars.post={}

vars.post[1]=function() --gives names "xmm~1" to "xmm~15" to all registers that are not 'x_reg'
 local xn=tonumber(vars.xreg_n)
 local c=1
 for i=0,15 do
  if xn~=i then
   vars['xmm~'..c]='xmm'..i
   c=c+1
  end
 end
 return vars --IMPORTANT!
end

--COMPULSORY
local newmem_name='newmem'..suffix
local newmem_size='$1000'
local script_ref='Left_arm' --  opcode_inj[vars.script_ref] stores vars
local inj_name='INJECT'..suffix
local pattern='^%s*mov.+%s*xmm%d+,%s*%[[^%]]+%]'
local aobs={'48 89 44 24 20 C7 44 24 28 FF FF FF FF 89 44 24 2C',-24,0}
local lookahead_n=32

local inj_script=[[
	define($%s{inj_name},$%s{address_string})
    registersymbol($%s{inj_name})
    alloc($%s{newmem_name}, $%s{newmem_size}, $%s{inj_name})
	alloc($%s{varis_1_n}, $%d{varis_1_size}, $%s{inj_name})
    registersymbol($%s{varis_1_n})
	$%s{varis_1_n}:
	$%s{varis_1_d}

	label(code)
	label(return)

	$%s{newmem_name}:
	code:
	  $%s{opcode}
      mulps $%s{x_reg},[$%s{varis_1_n}]
      mulps $%s{x_reg} , $%s{xmm~2} -- FROM: vars.post[1]
      $%s{overwritten}
	  jmp return

	$%s{inj_name}:
	  jmp $%s{newmem_name}
	  $%s{post_jmp}
	return:
]]

[ENABLE]
opcode_inj.inject(script_ref,inj_name,newmem_name,newmem_size,vars,inj_script,pattern,aobs,lookahead_n,parts,module_names)

[DISABLE]
opcode_inj.disable(script_ref)
opcode_inj[script_ref]=nil
```

* **nop(script_ref, inj_name, vars, pattern, aobs, module_names)** & **disable_nop(script_ref)**

Example script:

```
{$lua}
if syntaxcheck then return end
local vars={}
--OPTIONAL
local suffix='_la'
local parts={{'[^%]]+',1,'localAddress'},{'xmm%d+',1,'x_reg'},{'mov.+',1,'mov_op'}}
local module_names='PES2021.exe'

--COMPULSORY
local script_ref='Left_arm' --  opcode_inj[vars.script_ref] stores vars
local inj_name='INJECT'..suffix
local pattern='^%s*mov.+%s*xmm%d+,%s*%[[^%]]+%]'
local aobs={'48 89 44 24 20 C7 44 24 28 FF FF FF FF 89 44 24 2C',-24,0}

[ENABLE]
opcode_inj.nop(script_ref,inj_name,vars,pattern,aobs,module_names)
[DISABLE]
opcode_inj.disable_nop(script_ref)
opcode_inj[script_ref]=nil
```

* **dump(ref)**

  **ref**: dump all the data stored at `opcode_inj[ref]` a.k.a. `opcode_inj[vars.script_ref]` go to the LUA engine to see the dump.

## logpoint.lua

#### Log specified registers at a breakpoint. Useful for shared opcodes.

To use: place the the file into your autorun folder, open the LUA Engine and type in 'logpoint.' (without quotes), and then it will show you the methods listed below: 

### Methods on (logpoint.…): 

* **attach( {a, c, p --[[Optional]] , bh --[[Optional]] , fw --[[Optional]] , bpt --[[Optional]] }, {…}, … )** -> Takes a series of tables, one for each address. Attach logging breakpoint to address **a** (Use '0x…' for addresses in hexadecimal). 

**c** is a string or table of strings specifying what to log (could be a (sub-)register or e.g. register*y+x or, XMM0-15 or FP0-7, depending on whether you're using x64 or x86. Use "0x…", again, for hex offsets e.g. "RAX+0xC". Sub-registers are also available (the variable names defined below "-- EXTRA SUB-REGISTERS AVAILABLE:", in the code). 

Also, the float registers are interpreted as byte tables, so using them with argument **p** is undefined behaviour). If **p** is set to *true*, then the string(s) in **c** is/are interpreted as a memory address(es) and the bytes from there will be logged.

**bh** and **fw** extend the range of what is captured, e.g `logpoint.attach(0x14022E56F,'RCX',true,-0x40,0x60)` will log memory from [RCX-40] to [RCX+60] ([RCX-64] to [RCX+96] in decimal). 

**bpt** is a string or table of strings containing AOBs, that when any of the strings specified by **c** is present, the debugger will pause on the logpoint.
 
* **dumpRegisters( k --[[Optional]] )** -> Force dump last stored registers to output. Argument **k** is the index printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no argument specified, it will dump last stored registers for all breakpoints.

* **removeAttached( i --[[Optional]], b --[[Optional]] )** -> Remove attached breakpoint with address **i**, or, if b==true: the index **i** printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no arguments specified, it will remove all attached breakpoints.

* **stop( pr --[[Optional]] )** -> Removes all breakpoints made by this extension and, if **pr**==true (print), dump all the logged data in the console.

* **printAttached()** -> Print all attached breakpoints preceded by an index.

N.B. all data is displayed as arrays of bytes for convenience. I suggest pasting the data into a notepad, removing everything except the byte hex and pasting it into a hex editor/viewer.

## traceCount.lua

#### Attach a breakpoint to an address ("traceCount.attach(…)") and: print opcodes that are executed afterwards, sorted by the number of times they are executed or in the order in which they were executed. This is useful for finding repeating code e.g. single animations.

### Methods on (traceCount.…): 

* **attach( a, c, n --[[Optional]] , s --[[Optional]] )** -> Attach breakpoints to address **a** (Use '0x…' for addresses in hexadecimal), and keep logging for **c** steps afterwards ("step into/over"). If **n** is a specified, non-empty string, then it will save the trace by that string (see the *.saved()* method). If **s** is set to **true**, then the extension will "step over" (calls), otherwise it will "step into".

* **stop()** -> End the trace and print in ascending order of times executed.

* **printHits( m --[[Optional]] , n --[[Optional]], l --[[Optional]] , f --[[Optional]] , t --[[Optional]] )** -> 

If **m**==1: Prints all executed opcodes in the order they were executed "#…", and the number of times they have been executed, in parentheses; if **m**==0 or nil: Prints in ascending order of times executed. 

If **n** is a specified, non-empty string, then it will print the saved trace saved with that name (see *.saved()* method); if an empty string it will print the current trace. 

If **l** (integer) if specified, the extension will only print opcodes that have been executed >=**l** times, unless printing in the order of execution. 

If *m==1*, then **f** and **t**, if specified prints from the *f*th breakpoint hit to the **t**th.

* **save(n)** -> Save the current trace with the name of the non-empty string **n**

* **saved()** -> Print the names and information of saved traces.

* **query( a,  n --[[Optional]] )** -> Query the trace for the presence, count, and indexes (order it was hit) of an address or table of addresses. 

**a** is an an address or table of addresses. 

If **n** is a specified, non-empty string, then it will query the saved trace saved with that name (see *.saved()* method); if an empty string it will query the current trace.

* **compare(...)** -> Takes a series of strings -> **1st**: The name to save the comparison with; **2nd**: The trace from which to take information for the adresses present in all compared traces (*2nd string and beyond*). The output trace can be printed with *.printHits(…)* like any other.

* **delete( n --[[Optional]] )** -> If n is a string matching the name of a saved trace, it will delete that trace. If n is unspecified, it will delete all saved traces.

## batchRW.lua

#### Simply attach breakpoints to selected addresses ("batchRW.attach(…)") and: print the addresses and turn them yellow in the address list if they are read or written to ("writeTo" argument in "batchRW.attach(…)").

### Methods on (batchRW.…): 

* **attach(s, z --[[Optional]] , onWrite --[[Optional]] )** -> 
 
Attach breakpoints to address **s** (Use '0x…' for addresses in hexadecimal) (if eligible, otherwise will be attached to the next eligible address) ("Index" printed by "batchRW.printAddrs()") and **z**-1 eligible addresses after it (**z** in total, probably will not work if >4). If **z** is not specified, it will be set to 1. 

If "onWrite"==true, then it breaks if the address is written to, otherwise it breaks if the address is read.

* **printAddrs()** -> Print all attachable addresses in the address list, with their indexes for "batchRW.attach(…)".

* **detachAll()** -> Remove all breakpoints set by this extension.

## attachBpLog.lua

#### Log registers at a breakpoint, then print those registers if another breakpoint is hit. Used to provide extra data from earlier in the program's execution. Set a breakpoint on code that you know runs before the breakpoint you set with Cheat Engine's GUI. Useful for shared opcodes.

#### Currently only outputs 64-bit raw hex data.

To use: place the the file into your autorun folder, open the LUA Engine and type in 'attachBpLog.' (without quotes), and then it will show you the methods listed below: 

### Methods on (attachBpLog.…): 

* **attachBp(t)** -> Attach logging breakpoint to address **t** (Use '0x…' for addresses in hexadecimal), or, a table of addresses **t**.

* **dumpRegisters( k --[[Optional]] )** -> Force dump last stored registers to output (Not recommended to use; done after Cheat Engine GUI set breakpoint hit, anyway). Argument **k** is the index printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no argument specified, it will dump last stored registers for all breakpoints.

* **removeAttachedBp( i --[[Optional]], b --[[Optional]] )** -> Remove attached breakpoint with address **i**, or, if b==true: the index **i** printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no arguments specified, it will remove all attached breakpoints.

* **printAttached()** -> Print all attached breakpoints preceded by an index.

## proxValues.lua

#### To find multiple values that lie in an area of memory of max size **m** bytes or an unlimited number of bytes (argument of 'proxValues.fullScan(m)', below).

To use: place the the file into your autorun folder, open the LUA Engine and type in 'proxValues.' (without quotes), and then it will show you the methods listed below: 

### Methods on (proxValues.…): 

* **addMemScan()** -> Add result of memory scan to the script, for processing.

* **resetAllResults()** -> Reset everything.

* **removeResult(i)** -> Remove the **i**th memscan result from the script

* **printFiltered( n --[[Optional]], m --[[Optional]] )** -> Print filtered results (usually done after a scan anyway):

         printFiltered(n) : Print all results with max. memory area size <=n
   
         printFiltered(n,m) : Print all results with max. memory area size >=n and <=m
    
         printFiltered(): Print all results

* **fullScan( m --[[Optional]] )** -> Go through all added memscan results to find all instances where a result of all the memscans are found in an area of memory of max size **m** bytes (**m** must be positive integer >=1), or an unlimited size of memory if no argument is specified.

* **narrowDown( n --[[Optional]] )** -> If you have done a full scan and then added another memscan result, use this to further filter the results given by 'fullScan(m)'

        narrowDown(n) : Only keep and output results with max. memory area size <=**n**
        
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
