## Hex annotate.html

Webpage that lets you highlight hex to help you to present the structures in data. You can save your annotations to a .json file.

You can hover over hex with the mouse and hold the Ctrl/Alt keys to change the `From`/`To` values of the last entry in the annotations table.

## traceCount monitor.html

Webpage that allows you to load output from traceCount.lua (`printHits(1,…)`; output showing executed instructions in the order they were executed); adds checkboxes for easier tracking of relevant registers (will toggle all checkboxes after the one inputted to). Each line has a text box for making notes. The 'Memory accesses index' section has links to all relevant line for each memory address.

## tprint.lua

Allows you to print whole lua tables. Credit to ripter.

## maxScan.lua

Change the "Memory Scan Options" to search over the maximum area by default.

## opcode_inj.lua

**N.B.** When the code injection is successful: the extension will show the memory browser at the injection point; if there was no found address, then it won't. If there is a syntax error with the injection script, the extension will print it in the LUA Engine.

* **inject(script_ref, inj_name, newmem_name, newmem_size, vars, inj_script, pattern, aobs, lookahead_n, parts, module_names)**

  * **vars**: A table in the extension's global scope that can hold any data or functions with any name (key) you like, but the extension adds or expects data with the following keys, so check this list to avoid a clash:

```
[ post[…]: use numeric indexes here to run functions assigned to them to run before the "${…}/$%s{…}" syntax is first processed. You can write a whole list of instructions as one token (see example script below!) (set by user) ]

[ instruction_size: the size of the found instruction in bytes (decimal) (set by extension) ]
[ address_string: a string representing the address of the found instruction, usually "module.…+offset" (set by extension) ]
[ jmp_size: size of the jmp instruction, placed at the location of the found instruction, that diverts the code to your injected code in bytes (decimal) (set by extension) ]
[ post_jmp: assembler text to be inserted after the injected jmp to avoid undesired instructions appearing (set by extension) ]
[ overwritten: if the jmp instruction overwrites other instructions, this will replace them after your injected code (set by extension) ]
[ nops: number of nops required to keep the execution flow the same after injection (set by extension)]
[ overlap: number of instructions overwritten by jmp (set by extension) ]
[ ['lookaheads'](['offsets']/['instructions']/['bytes']/['sizes']): data ahead of the found instruction, to help with nops and overwites to help keep the execution flow the same (set by extension) ]
[ nopped_instruction: instruction nopped by the method 'disable_nop(…)' (set by extension) ]
[ og_instruction: the found instruction (at injection point) (set by extension) ]
[ og_bytes_dec: byte decimal table of matched instruction (set by extension) ]
[ og_hex: byte hex table of matched instruction (set by extension) ]
[ address_dec: address of found instruction in decimal (set by extension) ]
[ unregsy_txt: text containing code to unregister all symbols registered by the cheat table (set by extension) ]
[ deallc_txt: text containing code to dealloc all memory allocated by the cheat table (set by extension) ]
[ instruction_jmp: the instruction of the jmp that redirects execution flow towards the injected code (set by extension) ]
[ all_og_instructions: all orginal instructions, pre-injection (set by extension) ]
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

If you assign a function on vars (see example below): when there is a corresponding token in your script e.g. "${func_1}(7,8)", the extension will run the function with the specified arguments but as strings. So convert these stringified arguments to whatever type you need. If your function is "$%d{func_1}(7,8)", you must return a number from your function. 

N.B. Functions assigned on vars are run for every token, whereas functions on "vars['post']" are run only once. Therefore, it's better to assign constants with functions on "vars['post']".

```
  * **script_ref**: name to give the script so that it recognises a specific cheat table
  * **inj_name**: name to the injection point
  * **newmem_name**: name to give to the memory that stores the injected (redirected to) code
  * **newmem_size**: size of the memory that stores the injected (redirected to) code (STRING!: "${newmem_size}" or "$%s{newmem_size}"; INTEGER!: "$%d{newmem_size}")
  * **vars**: put data that you want to be accessible using the ```${…}/$%s{…}``` syntax here
  * **inj_script**: like Cheat engine's auto-assembler script, but it can also access the top level keys of the 'vars' table using the syntax e.g. ```${key} OR $%s{key}``` for a string value in `vars[key]` (see LUA pattern notation: %s, %d, etc.). Note that ```${…}``` is the same as ```$%s{…}```, because string is the most comnon type.
  * **pattern**: a LUA string with a pattern that instructions are checked against for matches. Ignored if **aobs** is a number or string.
  * **aobs**: a table or, table of tables, that contain `{'aob string', search from (string + this number), until (string + this number) }`; or a number or string denoting the address of the injection point. 
  * **lookahead_n**: at least this many bytes worth of instructions will be stored, ahead of the found instruction.
  * **parts**: a table or, table of tables, that contain `{ a substring from your pattern , nth occurrence of this substring will be matched , name given to this part }`
  * **module_names**: a table or, table of tables: match only addresses with address strings (usually containing module name) that contain one of these strings.
  
* **disable(script_ref)**

Example script:

```
{$lua}
if syntaxcheck then return end
local vars={}
--OPTIONAL (Add as named element of 'vars' table to use in '${...}' notation)
local suffix='_5'
vars.varis_1_n='mult'..suffix

local m1=1 -- mean
local r1=0 -- range

vars.varis_1_d='dd (float)'..m1..'\ndd (float)'..r1
vars.varis_1_size=8   --(u +0, r +4, 0.5 +8, 1+C)

local parts={{'[^%]]+',1,'localAddress'},{'%d+',1,'xreg_n'},{'xmm%d+',1,'x_reg'},{'mov.+',1,'mov_op'}}
local module_names='PES2021.exe'
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

-- token functions (below) run after ['post'] functions
vars['push_xmm']=function(...) -- n, as all arguments used for token functions, is necessarily a string!
  local n = select('#', ...) -- number of args
  local s=16*n
  local t={}
  local p=string.format('sub rsp, %X',s)
  table.insert(t,p)
  local args = {...}
  for _, v in pairs(args) do
      s=s-16
      local r=vars['xmm~'..v]
      if v=='0' then
	     r=vars['x_reg']
      end
      p=string.format('movdqu [rsp+%X],%s',s,r)
      table.insert(t,p)
  end
  return table.concat(t,'\n')
end

vars['pop_xmm']=function(...) -- n, as all arguments used for token functions, is necessarily a string!
  local n = select('#', ...) -- number of args
  local s=16*n
  local s_og=s
  local t={}
  local args = {...}
  local p=''
  for _, v in pairs(args) do
      s=s-16
      local r=vars['xmm~'..v]
      if v=='0' then
      	r=vars['x_reg']
      end
      p=string.format('movdqu %s,[rsp+%X]',r,s)
      table.insert(t,p)
  end
  p=string.format('add rsp, %X',s_og)
  table.insert(t,p)
  return table.concat(t,'\n')
end

vars['stack_push']=function(n) -- n, as all arguments used for token functions, is necessarily a string!
		return 'sub rsp, ' .. n
end

vars['stack_pop']=function(n) -- n, as all arguments used for token functions, is necessarily a string!
		return 'add rsp, ' .. n
end

--COMPULSORY
local newmem_name='newmem'..suffix
local newmem_size='$1000'
local script_ref='Animation_speed' --  opcode_inj[vars.script_ref] stores vars
local inj_name='INJECT'..suffix
local pattern='^%s*movss%s*%[[^%]]+%]%s*,%s*xmm%d+'
local aobs={'48 8B 40 10 F3 0F 11 48 44',0,16}
local lookahead_n=32

local inj_script=[[
  define(${inj_name},${address_string})
  registersymbol(${inj_name})
  alloc(${newmem_name}, ${newmem_size}, ${inj_name})

  alloc(${varis_1_n}, $%d{varis_1_size}, ${inj_name})
  registersymbol(${varis_1_n})
  ${varis_1_n}:
  ${varis_1_d}

  label(code)
  label(return)

  ${newmem_name}:
  code:
    push rcx
    push rbx
    push rax

    mov rax,[7FFE0014] //Windows internal clock
    mov rbx,rax
    shl rbx,6
    mov rcx,rax
    shl rcx,18
    imul rcx,rbx
    imul rcx,rax
    shr rcx,20 //ecx has the number
    ${push_xmm}(1,2,3,4,5)
    ${push_xmm}(0)


    cvtsi2ss ${x_reg}, rcx
    cvtss2sd ${x_reg}, ${x_reg}

    ${stack_push}(8)
        mov [rsp],FFE00000
        mov [rsp+4],41EFFFFF //move max_float into stack
        divsd ${x_reg}, [rsp] //div by max float (in double precision)
    ${stack_pop}(8)

    cvtsd2ss ${x_reg}, ${x_reg} //random float in ${x_reg}

    cvtss2si ecx, ${x_reg}  //b as int
    cvtsi2ss  ${xmm~5}, ecx // b

    ${stack_push}(10)
        mov [rsp], C0000000 //-2
        mov [rsp+4], 3F800000 //1
        mov [rsp+8], 40000000 //2
        mov [rsp+C], 3F3504F3 //sqHalf

        movss ${xmm~1},  [rsp+C] //sqHalf
        movss ${xmm~2}, [rsp] //-2
        movss ${xmm~3}, [rsp+4] //1
        movss ${xmm~4}, [rsp+8] //2

        mulss ${xmm~4}, ${xmm~5} //x~4=b*2
        subss ${xmm~3}, ${xmm~4} // x~3=1-b*2
        mulss ${xmm~1}, ${xmm~3} // x~1 = ( sqHalf* (1-b*2) )
        mulss ${xmm~2}, ${xmm~5} //x~2 = -2*b
        mulss ${xmm~2}, ${x_reg} // x~2=(-2*b)*x
        addss ${xmm~2}, ${xmm~5}//x~2=(-2*b*x)+b
        addss ${xmm~2}, ${x_reg} // x~2=(-2*b*x)+b+x
        sqrtss ${xmm~2}, ${xmm~2} // // x~2=sqrt(-2*b*x+b+x)
        mulss  ${xmm~1},${xmm~2} // x~1 = ( sqHalf* (1-b*2) )*sqrt(-2*b*x+b+x)
        addss ${xmm~1}, ${xmm~5} //  x~1 = b+ ( sqHalf* (1-b*2) )*sqrt(-2*b*x+b+x) || FINAL!
    ${stack_pop}(10)

    movss  ${xmm~4},  [${varis_1_n}+4]
    movss  ${xmm~3},  [${varis_1_n}] //u
    subss  ${xmm~3},  ${xmm~4}
    mulss  ${xmm~4},  ${xmm~1} //mul by adj_x
    addss  ${xmm~4},  ${xmm~4}
    addss  ${xmm~4},  ${xmm~3} //FINAL MULT in x~4 !

    ${pop_xmm}(0)
	mulss ${x_reg},${xmm~4}
    ${pop_xmm}(1,2,3,4,5)
    pop rax
    pop rbx
    pop rcx
    ${og_instruction}

    ${overwritten}
    jmp return

  ${inj_name}:
  jmp ${newmem_name}
  ${post_jmp}
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

N.B. To add a batch script for addresses with similar instructions, see the below example (for `movzx register,byte ptr[…]` instructions):
```
local function dealloc(name)
  local scrp=string.format('dealloc(%s)\nunregistersymbol(%s)',name,name)
  autoAssemble(scrp)
end

local function alloc(name,size,module_name,val)
  dealloc(name)
  local scrp=''
  if module_name==nil or module_name=='' then
      scrp=string.format('alloc(%s,%d)\nregistersymbol(%s)',name,size,name)
  else
      scrp=string.format('alloc(%s,%d,%s)\nregistersymbol(%s)',name,size,module_name,name)
  end
  if val~=nil then
     scrp=scrp..string.format('\n%s:\n%s',name,val)
  end
  autoAssemble(scrp)
  return getAddress(name)
end

local ads={0xDEADBEEF,0xDEADBEED} --Address list to mod
local al = getAddressList()

local templ={} -- Separate string parts to avoid clashes with escaped characters in string.format

templ[1]=[[{$lua}
if syntaxcheck then return end
local vars={}
local module_names=''
--OPTIONAL (Add as named element of 'vars' table to use in '${...}' notation)
local suffix='_batch'..%d --[1]
local parts={}

vars.post={}]]

templ[2]=[[vars.post[1]=function() -- get reg
	local ogi=vars['og_instruction'] --og instruction
	vars['reg']=string.match(ogi,'^%s*mov.*%s+([^,]+)%s*,')
	vars['mov']=string.match(ogi,'^%s*(mov.*)%s+[^,]+%s*,')
	return vars --IMPORTANT!
end

--COMPULSORY
local newmem_name='newmem'..suffix
local newmem_size='$1000'
local script_ref=suffix --  opcode_inj[vars.script_ref] stores vars
local inj_name='INJECT'..suffix
local pattern='']]

templ[3]=[[local aobs=0x%X --Address [2]
local lookahead_n=32

local inj_script=%s //[3]

define(${inj_name},${address_string})
    registersymbol(${inj_name})
    alloc(${newmem_name}, ${newmem_size}, ${inj_name})

	label(code)
	label(return)

	${newmem_name}:
	code:
	${mov} ${reg}, byte ptr[modVal]
	${overwritten}
    jmp return

	${inj_name}:
	  jmp ${newmem_name}
	  ${post_jmp}
	return:

%s --[4]

[ENABLE]
opcode_inj.inject(script_ref,inj_name,newmem_name,newmem_size,vars,inj_script,pattern,aobs,lookahead_n,parts,module_names)

[DISABLE]
opcode_inj.disable(script_ref)
opcode_inj[script_ref]=nil
]]

for i=0,#ads do
  local rec = al.createMemoryRecord()
  if i>0 then
	local ad=ads[i]
	local typeAd=type(ad)
	if typeAd=='string' then
		ad=getAddress(ad)
	end
	local desc='template'..i
	rec.setDescription(desc)
	rec.Type=11
	local sout={'',templ[2],''}
	sout[1]=string.format(templ[1],i)
	sout[3]=string.format(templ[3],ad,'[[',']]')
	rec.script=table.concat(sout,'\n')
  else --create 'modVal'
	local desc='modVal'
	rec.setDescription(desc)
	local adrs=alloc(desc,1,'example.exe','db A')
    	rec.Address=adrs
	rec.Type=vtByte
  end
end
```

## logpoint.lua

#### Log specified registers at a breakpoint. Useful for shared instructions.

To use: place the the file into your autorun folder, open the LUA Engine and type in 'logpoint.' (without quotes), and then it will show you the methods listed below: 

### Methods on (logpoint.…): 

* **attach( { a, c, bpt --[[Optional]] }, {…}, … )** -> Takes a series of tables, one for each address. Attach logging breakpoint to address **a** (Use '0x…' for addresses in hexadecimal). 

**c** is a string or table of strings specifying what to log (could be a (sub-)register or e.g. register*y+x or, XMM0-15 or FP0-7, or any of those surrounded by square brackets to indicate a pointer (like argument **p**) (To specifiy the byte range you wish to log use `[…](b,f)` syntax {e.g. `[RSP](0,7)` will log 8 bytes: RSP to RSP+7}, to be specific for this log. If you do not do either of these, it will default to logging 1 byte.), depending on whether you're using x64 or x86. Use "0x…", again, for hex offsets e.g. "RAX+0xC". Sub-registers are also available (the variable names defined below "-- EXTRA SUB-REGISTERS AVAILABLE:", in the code).

***To log values in functions and the return values of these:***

If **c** is a table and:

 * **c**[3] is a number: **c**[3] represents the offset from RSP (RSP+**c**[3]) that will be read to get return address, this value (`s`) defaults to 0.

 * ( **c**[1] is a table and **c**[2]~=nil ) `OR` ( **c**[2] is a table ): The values in **c**[1] will be logged at the function address, and those in **c**[2] will be logged at the return address.

**bpt** is a string or table of strings containing AOBs, that when any of the strings specified by **c** is present, the debugger will pause on the logpoint.
 
 * **count( {a, c}, {…}, … )** -> Takes a series of tables, one for each address. See ".attach(…)" for explanations of **a** and **c**. Use ".dumpRegisters(…)" to print counts of all values taken by **c**.
 
* **dumpRegisters( bin --[[Optional]], f --[[Optional]], k --[[Optional]] )** -> Force dump last stored registers to output.

If **bin**==:

1 -> Print only the data as raw hex, separated by `00` bytes

2 -> Non-pointer and non-table registers are printed as little endian hex rather than as arrays of bytes.

Otherwise (default) -> Print all logged data as arrays of bytes.

**f** is a (full path to a) file name (use double backslashes instead on single ones), where all the logged data will be dumped; if unspecified or nil, the data will be printed to the console, otherwise it will be dumped to the specified file path.

Argument **k** is the index printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"), the breakpoint of this log will be removed. If no argument specified, it will dump last stored registers for all breakpoints and remove the breakpoints for them all.

* **dumpRegistersChrono( k --[[Optional]], bin --[[Optional]], f --[[Optional]] )** -> Force dump last stored registers to output in chronological order.

**k** is an index or table of indexes (as printed by *printAttached()*) to be dumped.
  
If **bin**==:

1 -> Non-pointer and non-table registers are printed as little endian hex rather than as arrays of bytes.

Otherwise (default) -> Print all logged data as arrays of bytes.

***f** is the same as in ".dumpRegisters(…)".

* **jump( x, k --[[Optional]] )** -> Jump to last dumped (in the hex view) (if the dump was of a ".attach(…)" capture), #**x**'s array of bytes interpreted as an address. Argument **k** is the same as in ".dumpRegisters(…)", and only works when the last dump was not made using ".dumpRegistersChrono(…)" (even when it printed to file).

* **removeAttached( i --[[Optional]], b --[[Optional]] )** -> Remove attached breakpoint with address **i**, or, if b==true: the index **i** printed by *printAttached()* before the address (e.g. "2: 1406E8CFF"). If no arguments specified, it will remove all attached breakpoints.

* **stop( pr --[[Optional]], bin --[[Optional]], f --[[Optional]] )** -> Removes all breakpoints made by this extension and, if **pr**==true (print), dump all the logged data using ".dumpRegisters(…)". **bin** and **f** are the same as in ".dumpRegisters(…)".

* **printAttached()** -> Print all attached breakpoints preceded by an index.

N.B. all data is displayed as arrays of bytes, unless **le**==*true* in the situation described above. I suggest pasting the data into a notepad, removing everything except the byte hex and pasting it into a hex editor/viewer.

## traceCount.lua

#### Attach a breakpoint to an address ("traceCount.attach(…)") and: print instructions that are executed afterwards, sorted by the number of times they are executed or in the order in which they were executed. This is useful for finding repeating code e.g. single animations.

### Methods on (traceCount.…): 

* **attach( a, c, z --[[Optional]], s --[[Optional]], n --[[Optional]] )** -> Attach breakpoints to **a**: address or table of addresses (either in number [Use '0x…' for addresses in hexadecimal] or string, e.g. 'example.exe+7AE', form) (**If a table of addresses, then it will attach a breakpoint to the 1st element, then when it is hit it will attach one to the 2nd and so on until the last breakpoint is hit and then it will start the trace. This is useful for when the trace cannot escape system modules.**), and keep logging for **c** steps afterwards ("step into/over"). If **c** is a table, the trace will continue until the address reprsesented in the first element of the table is executed up to an optional limit, if specified by the 2nd element. If **n** is a specified, non-empty string, then it will save the trace by that string (see the *.saved()* method). If **z** == true, then it will break when the trace is over. If **s** is set to **true**, then the module will "step over" (calls), if **s** is a string or table of strings then the module will step into all modules specified by this string and "step out" of all addresses in modules not specified here, otherwise it will "step into".

* **lite( a, c, s --[[Optional]] )** -> Like "traceCount.attach(…)" but only the instructions are logged, so it's quicker. **a**, **c** and **z** are the same as in "traceCount.attach(…). , **s**, if true, will "step over", otherwise it will step into.
 
* **litePrint(fileName)** -> **fileName** is a (full path to a) file name (use double backslashes instead on single ones), where the last trace captured by "traceCount.lite(…)" will be saved; if unspecified or nil, the trace will be printed to the console.

* **condBp( a, c, s --[[Optional]], bf --[[Optional]] )** -> **a** is an address or table of addresses in string or number form, like in "traceCount.attach(…)". **c** is a string AOB or a number, or a table of these. If **c** is a table, and an element of **c** is a table, then all strings inside that table will be instruction patterns which will be compared against the instruction. **s** is the same as in "traceCount.attach(…)". **bf** is a number, a positive number of bytes around accesed memory addresses to look for **c**.

This method breaks when a register in an instruction, or one changed by an instruction, matches any AOB string or number in **c**.

N.B. To continue detection after a break, press "Step Into/Over" in the Memory Viewer.

To add extended registers (i.e. sub-registers) to Cheat Engine's in-built conditional breakpoints, see: [https://gist.github.com/crabshank/549a67e52b6fc298912cf55532de5b9d](https://gist.github.com/crabshank/549a67e52b6fc298912cf55532de5b9d)

* **stop()** -> Ends the trace, or it ends "traceCount.condBp(…)".

* **printHits( m --[[Optional]], p --[[Optional]],  n --[[Optional]], l --[[Optional]] , f --[[Optional]] , t --[[Optional]] )** -> 

If **m**==1: Prints all executed instructions in the order they were executed "#…", and the number of times they have been executed, in parentheses; if **m**==0 or nil: Prints in ascending order of times executed. 

**p** is a (full path to a) file name, where the trace will be saved; if unspecified or nil or `''`, the trace will be printed to the console (Use double backslashes instead on single ones) (".asm" extension is recommended).

If **n** is a specified, non-empty string, then it will print the saved trace saved with that name (see *.saved()* method); if an empty string it will print the current trace. 

If **l** (integer) if specified, the extension will only print instructions that have been executed >=**l** times, unless printing in the order of execution. 

If ***m**==1*, then **f** and **t**, if specified prints from the *f*th breakpoint hit to the **t**th.

* **save(n)** -> Save the current trace with the name of the non-empty string **n**

* **saved()** -> Print the names and information of saved traces.

* **query( a, s --[[Optional]] ,  n --[[Optional]] )** -> Query the trace for the presence, count, and indexes (order it was hit) of an address or table of addresses. 

**a** is an an address or table of addresses (in number or string form). 

If **s** is set to *true*, then it will query the trace for whether the address(es) was/were read or written to.

If **n** is a specified, non-empty string, then it will query the saved trace saved with that name (see *.saved()* method); if an empty string it will query the current trace.

* **compare(...)** -> Takes a series of strings -> **1st**: The name to save the comparison with; **2nd**: The trace from which to take information for the adresses present in all compared traces (*2nd string and beyond*). The output trace can be printed with *.printHits(…)* like any other.

* **delete( n --[[Optional]] )** -> If n is a string matching the name of a saved trace, it will delete that trace. If n is unspecified, it will delete all saved traces.

* **findWriteStack( aobs, m, b, f --[[Optional]] )** -> This code is to scan memory for desired aobs after instructions at the return addresses in the stack are ran, and will tell you between the running of which instructions the target aob(s) appears in memory. **aobs** is a string or table of strings containing aobs. **m** is a string or table of strings containing module names (e.g. `myProgram.exe`) and any return address in the stack that is in any of these modules will have a breakpoint attached to them. **b** how deep (RSP+**b**) to probe the stack, if unspecified the function will probe the full stack. If **f**==true, force the method to not limit itself to scanning between RSP and RBP. N.B. Execute this code whilst the debugger is broken, this code will then delete all breakpoints and set up its own, then Run the program.

* **findWriteStep( i, aobs, b, f --[[Optional]], p --[[Optional]], m --[[Optional]] )** -> This code is to scan memory for desired aobs after key instructions are ran, and will tell you between the running of which instructions the target aob(s) appears in memory. **i** is a true (Step into)/false (Step over) boolean. **aobs** is a string or table of strings containing aobs. **b** is the address on which to set the initial breakpoint. **f** is the address which if the code breaks on, the code will terminate. **p** is a string or table of strings containing lua patterns that if the current instruction matches any of them, the code will scan the memory before and after this code is executed. **m** is a string or table of strings containing module names (e.g. `myProgram.exe`) and only if a broken address is in any of these modules will it be considered as a candidate for running an aob scan on or after this step. N.B. Delete any current breakpoints, execute this code, then Run the program.

* **end_fw()** -> This will force the termination of "findWriteStack/findWriteStep(…)".

N.B. When not in a trace, or when using traceCount.condBp(…): When a breakpoint is hit, the extension will make the main memory view's hex view jump to the last (or first if jmpFirst==true) (matching in .condBp(…)) memory address ('[…]') in the broken instruction. This will make it much easier to see what's around read memory addresses when stepping through the code. If there's are no memory addressed in the instruction, it will display the contents of the registers in the hex view, all 4-byte aligned. If the target process is currently in a breakpont, you can click an instruction in the disassembler and the memory view will jump in the aforementioned way for the address you clicked on.

## batchRW.lua

#### Simply attach breakpoints to selected addresses ("batchRW.attach(…)") and: print the addresses and turn them yellow in the address list if they are read or written to ("writeTo" argument in "batchRW.attach(…)").

### Methods on (batchRW.…): 

* **attach(s, z --[[Optional]] , onWrite --[[Optional]] , cond --[[Optional]] , col --[[Optional]] )** -> 
 
Attach breakpoints to address with index **s** (if eligible, otherwise will be attached to the next eligible address) ("Index" printed by "batchRW.printAddrs()") and **z**-1 eligible addresses after it (**z** in total, probably will not work if >4). If **z** is not specified, it will be set to 1. 

If **onWrite**==true, then it breaks if the address is written to, otherwise it breaks if the address is read.

**cond** holds condtions upon which the registration of the read/write depend. The argument takes the form of a string AOB or a table of the form `{number, number size in bytes}`, or a table with a mix of the two forms. N.B. AOB matches take precedence over number matches. 

**col** is a RGB hex string, or table of strings, like "FF0000". If **col** is unspecified, accessed addresses will turn yellow. If **col** is a table of strings, then it will change the colour of the address to the 1st element's colour and duing scanning, will ignore the addresses that are any colour represented in the table. If **col** is a string, then it will change the colour of the address string's colour and duing scanning, will ignore the addresses that are that string's colour.

Protip: use ```batchRW.attach(i*4,4)``` starting with i=0 and increment i by 1, to monitor addresses in batches of four. 

* **attach_loop(z, t, onWrite --[[Optional]]  , col --[[Optional]] )** -> 

Attach breakpoints to the current address list, **z** entries at-a-time, cycling through them every **t** milliseconds. See "batchRW.attach(…)" to see what **onWrite** and **col** do.

* **add(f, t, s --[[Optional]] , n --[[Optional]] )** -> Add **t** addresses from **f**, every **n** bytes, to the address list as type byte.
**f** is a numeric or string address. **t** is a number >=1 that specifies how many addresses to add. **n** specifies the number of bytes between the addresses of each byte added to the address list. **s** is 'base' if not specified or an empty string, and it is the prefix to the addresses' desccriptions.

* **keepCol( c --[[Optional]] )** ->  If **c** is not specified, it will be yellow. Deletes entries in the address list that are not the colour **c** (if string), or any colour not in **c** (if table).

* **end_loop()** -> Force end "batchRW.attach_loop(…)"

* **printAddrs()** -> Print all attachable addresses in the address list, with their indexes for "batchRW.attach(…)".

* **detachAll()** -> Remove all breakpoints set by this extension.

* **stack(d, b --[[Optional]] , m --[[Optional]] , f --[[Optional]] )** -> Break on address **d** and attempt to find return addresses in the stack. **b** how deep (RSP+**b**) to probe the stack, if unspecified the function will probe the full stack. **m** is a string containing a module name; only addresses in module **m** will be logged. If **f**==true, force the method to not limit itself to scanning between RSP and RBP.

* **end_stack( bck --[[Optional]] , lst --[[Optional]] )** -> End logging by "batchRW.stack(…)", and print its output. If **bck**==true/false, then the return addresses will be printed in the (reverse, if true) order that they were recorded in, and if **lst** is a number, it will only print the first (if **bck**==true) or last (if **bck**==false) n values specified by the **lst** argument.

* **rsp( b --[[Optional]] , m --[[Optional]] , f --[[Optional]] )** -> Same as "batchRW.stack(…)", except it only works when the game is currently paused at a breakpoint. If **f**==true, force the method to not limit itself to scanning between RSP and RBP.

* **jump( i, s --[[Optional]] )** -> Jumps to the **i**th result, as printed by "batchRW.end_stack/rsp(…)", of: if **s**==true, rsp; if **s**==false, stack; otherwise, the last printed result.

## attachBpLog.lua

#### Log registers at a breakpoint, then print those registers if another breakpoint is hit. Used to provide extra data from earlier in the program's execution. Set a breakpoint on code that you know runs before the breakpoint you set with Cheat Engine's GUI. Useful for shared instructions.

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

* **jump(i)** -> Jump to last printed result (#**i**), in the hex view).

* **narrowDown( n --[[Optional]] )** -> If you have done a full scan and then added another memscan result, use this to further filter the results given by 'fullScan(m)'

        narrowDown(n) : Only keep and output results with max. memory area size <=**n**
        
        narrowDown() : Use previous memory area size
	
* **compare( t, r --[[Optional]] )** -> After using `.addMemScan()` at least twice, use this to print which addresses appear in the sets you sepecify with **t**. **t** is a table, or table of tables containing 2 numeric elements: {set #i, 0/1/2/3}; for the second element: 0 - > addresses contained in set #i, 1 - > addresses not contained in set #i, 2 - > addresses exclusively contained in set #i, , 3 - > addresses contained in all sets but set #i. **r** can be set to true to force the sets to be re-analysed, but they will be automatically, if: there are not yet any analysed results, or the number of added scans is different from the number there were when the results were last analysed.
***

## CETRACE reader x64.html

Load a .cetrace file, wait, and it will finish loading.

Clicking on the instruction line (above RAX) in different places (check the tooltip), will highlight the current all latter instances and the same goes for the registers.

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
  
* You can generate a cheat table containing all the highlighted values, or if there are no highlighted values it will create a generic cheat table with each entry being of type Byte. To add names to the addreses, edit the text box saying "base +/- …" and to change "base", select the base address and change its name. 'Group name' describes what the values are for, e.g. character struct. Change the array of bytes to on starting from the base address. Leaving the 'module name' box blank may give better results.
