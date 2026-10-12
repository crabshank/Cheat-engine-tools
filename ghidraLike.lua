-----------------------------------------------------------------------
-- ghidraLike.lua
--
-- PURPOSE
--   Enumerate the function starts of a loaded Windows module (PE32 / PE32+)
--   from inside Cheat Engine, WITHOUT disassembling anything.
--
-- THE CORE IDEA
--   Instead of decoding instructions, the script harvests addresses from
--   places the compiler or linker has already admitted are code: the x64
--   exception directory, the CFG call-target table, the export table, TLS
--   callbacks, CRT initialisers, the entry point, E8 call byte patterns,
--   padding boundaries, code pointers lying in data sections, and the slots
--   of every RTTI vftable. Each harvested address is a CANDIDATE.
--
-- THE SINGLE INCLUSION RULE
--   A candidate is kept if, and only if, it falls inside an executable
--   section of the module being probed. Nothing is decoded to confirm it and
--   nothing is later deleted. Candidates that happen to sit inside another
--   function's .pdata body are still kept, but flagged status = 'nested' so
--   that you can filter them out at presentation time.
--
-- WHY NO DISASSEMBLY
--   A linear decode pass costs roughly two Cheat Engine calls per
--   instruction -- around seven million calls on a 30 MB .text section --
--   and each memoised result was measured at about 257 bytes of Lua heap.
--   This revision never calls disassemble, getInstructionSize or
--   getPreviousOpcode. Every scan operates on bytes already pulled in 256 KB
--   chunks; CE is asked to do one thing only: read memory.
--
-- MEMORY MODEL
--   One discovered root is stored as ONE number, not one table:
--
--       roots[address] = confidence * CONFSHIFT + sourceMask
--
--   sourceMask has one bit per source tag, so it is bounded by 2^15 - 1,
--   while CONFSHIFT is 2^20. Because 2^15 - 1 < 2^20 the two fields can
--   never bleed into each other, and both are recoverable by pure
--   arithmetic:
--
--       confidence = floor(v / CONFSHIFT)
--       sourceMask = v - confidence * CONFSHIFT
--
--   That is ~32 bytes per entry against ~290 for the old pair of tables.
--
-- ASYNCHRONY
--   probe() does its work inside a coroutine that a 1 ms timer pumps, so the
--   Cheat Engine GUI stays responsive and the progress window repaints.
--   Consequently probe() returns nil immediately and the results only exist
--   once the summary lines have printed.
--
-- HONEST LIMITS
--   "Every function" is undecidable on x86-64: jump tables and indirect
--   calls can hide code that no source here can name. Leaf functions have no
--   .pdata entry at all. Non-.pdata extents are estimates (end = next start).
--   E8 bytes are matched unaligned, so a handful of "call targets" are really
--   immediates or table bytes -- they still satisfy the inclusion rule.
--
-- ENVIRONMENT
--   Cheat Engine's embedded Lua. readBytes with ReturnAsTable = true yields a
--   byte table [[39]]. The arithmetic avoids bit operators and never yields
--   across pcall, so it also runs on Lua 5.1/5.2 apart from the decimal
--   "\232"-style escapes, which all versions accept.
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- CONSTANTS AND LEXICAL SHORTHANDS
-----------------------------------------------------------------------

-- Aliasing the handful of library functions used in hot loops. A local
-- lookup is cheaper than a global one, and these are called per byte.
local floor = math.floor
local find, byte, char, len = string.find, string.byte, string.char, string.len

-- Lua 5.1 keeps unpack in the global table; 5.2+ moved it into "table".
-- This one line papers over the difference.
local unpack = table.unpack or unpack


-- The two single-byte padding opcodes: INT3 (0xCC) and NOP (0x90).
local PADDING = { [0xCC]=true, [0x90]=true }

-- Multi-byte NOP "cores" -- the forms the assembler emits for alignment
-- that are not a bare 0x90. Listed longest-first so that a greedy match
-- consumes the whole instruction rather than a prefix of it. The set is
-- prefix-free: no entry is the start of another, so the first match wins
-- unambiguously. Leading 0x66 (operand-size) prefixes are stripped
-- separately in padItemLen, which is what covers 66 90, 66 0F 1F ..., and
-- the 66 66 2E ... variants real compilers produce.
local NOPCORE = {
{0x2E,0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00},   -- cs nopw [rax+rax*1+0]
{0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00},        -- 8 bytes
{0x0F,0x1F,0x80,0x00,0x00,0x00,0x00},             -- 7 bytes
{0x0F,0x1F,0x44,0x00,0x00},                       -- 5 bytes
{0x0F,0x1F,0x40,0x00},                            -- 4 bytes
{0x0F,0x1F,0x00}                                 -- 3 bytes
}

-- Bytes per Cheat Engine read. 256 KB is large enough that the per-call
-- overhead is negligible and small enough that the resulting Lua table is
-- cheap to build and discard.
local CHUNK         = 262144

-- Look-ahead bytes carried past the end of a window so that a structure
-- straddling a chunk boundary can still be read whole. Must be at least the
-- largest structure read ahead of a slot; the COL is 24 bytes, so 32 is
-- comfortable. (The choice of 32 rather than 24 is inferred: it is a round
-- number with headroom.)
local OVERLAP       = 32

-- Cap on a TypeDescriptor name read. RTTI names are mangled, and a
-- template-heavy name can be long; truncates rather than runs away.
local RTTI_NAME_MAX = 2048

-- Hard cap on a single vftable walk. Guards against a data slot that looks
-- like a run of code pointers but is really a jump table or a filled array.
local VTABLE_SLOTS  = 4096

-- Source tags. The VALUES are the lowercase strings that appear in srcs,
-- in CSV output and in list() rows; the KEYS are the identifiers used in
-- code, so that a typo is a nil rather than a silent miss.
local SRC = {
PDATA='pdata', CALL='call', PAD='pad', ENTRY='entry', EXP='export',
TLS='tls', CRT='crt', PTR='ptr', VTBL='vtable', XDATA='xdata',
RVA='rva', CFG='cfg', DYN='dynamic', JUMP='jump', FRAG='fragment'
}

-- Canonical order. This single list serves two purposes: it is the display
-- order for tag lists, and its index determines the bit position of that
-- tag inside the packed source mask. Changing the order changes the packed
-- representation, which is harmless because nothing persists it.
local TAGORDER = { 'pdata','cfg','export','tls','crt','entry','vtable','dynamic',
'call','rva','pad','ptr','xdata','fragment','jump' }

-- Confidence tiers. Higher means "a compiler or the OS vouches for this".
-- AUTHORITATIVE(4) > HIGH(3) > STRONG(2) > WEAK(1) > SPECULATIVE(0).
local CONF = {
[SRC.PDATA]=4, [SRC.CFG]=4, [SRC.EXP]=4, [SRC.TLS]=4, [SRC.CRT]=4, [SRC.ENTRY]=4,
[SRC.VTBL]=3, [SRC.DYN]=3,
[SRC.CALL]=2,
[SRC.RVA]=1, [SRC.PAD]=1, [SRC.PTR]=1, [SRC.XDATA]=1, [SRC.FRAG]=1,
[SRC.JUMP]=0
}

-- Tier number -> label, indexed as CONFNAME[tier + 1] because Lua arrays
-- are 1-based and the lowest tier is 0.
local CONFNAME = { 'SPECULATIVE','WEAK','STRONG','HIGH','AUTHORITATIVE' }

-- The multiplier that separates the confidence field from the mask field in
-- a packed root. 2^20, comfortably above the 2^15 ceiling of the mask.
local CONFSHIFT = 1048576

-- tag -> bit value (1, 2, 4, 8, ...). Built by repeated doubling rather
-- than by a bit operator, so the file stays runnable on Lua versions whose
-- numbers are doubles with no bit library.
local TAGBIT = {}
do
local bit = 1
for i = 1, #TAGORDER do TAGBIT[TAGORDER[i]] = bit; bit = bit * 2 end
end

-- PE section characteristics and Win32 memory flags, spelled out as
-- constants because the alternative is magic numbers in tests.
local SCN = {
CODE=0x00000020, INITDATA=0x00000040, UNINITDATA=0x00000080,
MEM_READ=0x40000000, MEM_EXEC=0x20000000, MEM_WRITE=0x80000000
}

-- Data-directory indices. Note that TLS is 9, not 4 -- 4 is the
-- certificate/security directory, and confusing the two is the classic
-- PE-parsing slip.
local DD = { EXPORT=0, IMPORT=1, RESOURCE=2, EXCEPTION=3, CERT=4,
RELOC=5, DEBUG=6, TLS=9, LOADCFG=10 }

-- MEM_COMMIT, used by the page-protection fallback.
local MEM_COMMIT = 0x1000

-- The four PAGE_EXECUTE_* protections. Guard variants (0x100, 0x200, ...)
-- are handled by taking Protect % 256 before this lookup, which strips the
-- guard/write-copy modifier bits and leaves the base protection.
local PAGE_EXEC  = { [0x10]=true, [0x20]=true, [0x40]=true, [0x80]=true }

local moduleAddress, moduleName = nil, ''

local function addressOffset(a)
	if moduleAddress==a then
		return string.format('%X',moduleAddress) 
	else
		return string.format('%s+%X',moduleName,a-moduleAddress)
	end
end

-- Test whether bit-value m is set in v. Written as divide-mod rather than
-- a bit operator for portability. Non-numbers are treated as "not set"
-- rather than raising, because callers pass possibly-absent fields.
local function hasBit(v, m)
if type(v) ~= 'number' then return false end
return floor(v / m) % 2 == 1
end

-- True only when EVERY listed bit-value is set. Used for section
-- characteristics, where "readable initialised data" means both bits.
local function hasAll(v, ms)
for i = 1, #ms do if not hasBit(v, ms[i]) then return false end end
return true
end

-- Count entries in a hash table. # is meaningless for non-sequence tables,
-- and most of the tables here are keyed by address.
local function cnt(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Gatekeeper for anything used as a table key that is meant to be an
-- address. Rejects non-numbers and fractional values.
--
-- Scope note: despite the file's former claim, this does not reject
-- infinity -- floor(inf) == inf, so +inf passes. It is harmless in
-- practice because propose() and inExec() both range-check, and an
-- infinite address fails every comparison. NaN, by contrast, IS rejected,
-- because NaN ~= NaN.
local function normAddr(a)
if type(a) ~= 'number' then return nil end
local f = floor(a)
if f ~= a then return nil end
return f
end

-----------------------------------------------------------------------
-- PROGRESS WINDOW
--
-- A tiny non-modal form with one label, used to show which phase is
-- running and how far through it we are. Everything here is wrapped in
-- pcall: a progress display must never be able to kill a scan.
-----------------------------------------------------------------------

-- [1] = the form, [2] = the label. Deliberately NOT a sequence with
-- meaningful length; only these two indices are ever used.
------------------------------------------------------------------ progress window
local gl_w = { nil, nil }
local gl_lastW, gl_lastH = 0, 0

local function spaceSep_int(b)
    if type(b) ~= 'number' then return '0' end
    b = floor(b)
    local g = ''
    if b < 0 then g = '-'; b = -b end
    local n = string.format('%d', b)
    local l = #n
    local c = l
    if l <= 3 then return g .. n end
    local out = {}
    while c > 0 do
        local a = math.max(1, c - 2)
        table.insert(out, 1, n:sub(a, c))
        c = c - 3
    end
    return g .. table.concat(out, ' ')
end

-- Kept under its old public name. There are no memo caches any more; this just asks the
-- collector to hand freed tables back. The transient 256 KB chunk tables are the only
-- sizeable garbage a run produces.
local function gl_freeCaches()
    collectgarbage('collect')
end

-- Return the label's current text extent.
--
-- Prefer the label's own AutoSize bounds. If the host has not updated them yet,
-- fall back to a crude character-count estimate so the window does not collapse
-- to zero size.
local function gl_labelExtent(l)
    local w = tonumber(l.Width) or 0
    local h = tonumber(l.Height) or 0

    if w > 1 and h > 1 then
        return w, h
    end

    local caption = ''
    pcall(function()
        caption = tostring(l.Caption or '')
    end)

    local n = #caption

    -- Rough fallback: about 8 pixels per character at the font size used here.
    -- This is not perfect, but it prevents a zero-width or zero-height form.
    if w <= 1 then
        w = math.max(520, n * 8)
    end

    if h <= 1 then
        h = 20
    end

    return w, h
end

-- Resize the progress form to fit the label text.
--
-- This is manual because TLabel.AutoSize sizes the label, not necessarily the
-- parent TForm / TCustomForm.
local function gl_fit()
    if gl_w[1] == nil or gl_w[2] == nil then
        return
    end

    local f, l = gl_w[1], gl_w[2]

    -- The label must be free-sizing and must not wrap to the form width.
    -- If WordWrap were true, the label width could depend on the form width,
    -- creating circular sizing behaviour.
    pcall(function() l.AutoSize = true end)
    pcall(function() l.WordWrap = false end)

    local lw, lh = gl_labelExtent(l)

    -- Padding around the label. Left/Top are usually 8, so this gives a
    -- comfortable 16-pixel total margin horizontally and vertically.
    local padX, padY = 16, 16

    local wantW = (tonumber(l.Left) or 0) + lw + padX
    local wantH = (tonumber(l.Top) or 0) + lh + padY

    -- Round up to 8-pixel steps. This still fits the text, but avoids the
    -- window twitching by one pixel whenever a percentage changes width.
    wantW = math.ceil(wantW / 8) * 8
    wantH = math.ceil(wantH / 8) * 8

    -- Optional: if you also want the window title text to influence the width,
    -- uncomment these lines.
    --
    -- local title = ''
    -- pcall(function() title = tostring(f.Caption or '') end)
    -- local titleWant = #title * 8 + 96
    -- wantW = math.max(wantW, titleWant)

    if wantW ~= gl_lastW then
        -- Preferred: size the client area, excluding window borders.
        if not pcall(function() f.ClientWidth = wantW end) then
            -- Fallback: size the whole window using a rough border allowance.
            pcall(function() f.Width = wantW + 16 end)
        end
        gl_lastW = wantW
    end

    if wantH ~= gl_lastH then
        if not pcall(function() f.ClientHeight = wantH end) then
            pcall(function() f.Height = wantH + 39 end)
        end
        gl_lastH = wantH
    end
end

local function gl_open(title)
    if gl_w[1] ~= nil then
        -- If the cached form still exists, reuse it.
        if pcall(function() return gl_w[1].Caption end) then
            gl_w[1].Caption = title
            gl_w[1].Show()
            gl_w[2].Caption = '…'

            gl_lastW, gl_lastH = 0, 0
            pcall(function() gl_w[1].Update() end)
            gl_fit()

            -- Prevent the form from re-centring on every resize.
            pcall(function() gl_w[1].Position = 'poDesigned' end)
            return
        end

        -- Cached form was destroyed externally; drop stale handles.
        pcall(function() gl_w[1].destroy() end)
        gl_w[1], gl_w[2] = nil, nil
    end

    local f = createForm(getMainForm())

    -- Start small. gl_fit() will size it to the label.
    f.Width, f.Height = 520, 10
    f.Position, f.BorderStyle = 'poScreenCenter', 'bsSingle'
    f.Caption, f.Color, f.FreeOnClose = title, 0, false

    local l = createLabel(f)
    l.Left, l.Top, l.AutoSize, l.Color = 8, 8, true, 0
    pcall(function() l.WordWrap = false end)
    l.Font.Color, l.Font.Size = 0xFFFFFF, 12
    l.Caption = '…'

    gl_w[1], gl_w[2] = f, l
    gl_lastW, gl_lastH = 0, 0

    f.Show()
    pcall(function() f.Update() end)
    gl_fit()

    -- After the first display, stop using poScreenCenter for later resizes.
    -- Otherwise the window may jump each time the progress text changes width.
    pcall(function() f.Position = 'poDesigned' end)
end

local function gl_phase(p)
    if gl_w[2] == nil then
        return
    end

    gl_w[2].Caption = p
    gl_fit()
end

local function gl_progress(done, total, unit)
    if gl_w[2] == nil then
        return
    end

    unit = unit or 'items'

    if total == nil or total <= 0 then
        gl_w[2].Caption = spaceSep_int(done) .. ' ' .. unit
    else
        if done > total then
            done = total
        end

        gl_w[2].Caption = string.format(
            '%s / %s %s (%d%%)',
            spaceSep_int(done),
            spaceSep_int(total),
            unit,
            floor(done / total * 100)
        )
    end

    gl_fit()
end

local function gl_close()
    local f = gl_w[1]
    gl_w[1], gl_w[2] = nil, nil
    gl_lastW, gl_lastH = 0, 0

    if f ~= nil then
        pcall(function() f.destroy() end)
    end
end

local function gl_yield()
    coroutine.yield()
end

-----------------------------------------------------------------------
-- BYTE READERS
--
-- All multi-byte reads are little-endian and accumulate as
--     v = 256*v + next_byte
-- working from the most significant byte down. With n <= 8 and user-mode
-- addresses below 2^48, every intermediate stays exact in Lua's numbers.
--
-- IMPORTANT: readBytes can return a SHORT table at the edge of a mapping
-- [[39]], so "#b < n" is a real condition, not defensive padding. Every
-- reader returns nil rather than a partial value, and every caller treats
-- nil as "unreadable" rather than as zero.
-----------------------------------------------------------------------

local V256 = 256

local function rd(n, a)
local b = readBytes(a, n, true)
if b == nil or #b < n then return nil end
local v = 0
for i = n, 1, -1 do
local x = b[i]
if x == nil then return nil end     -- a hole inside the table
v = V256 * v + x
end
return v
end

local rd16 = function(a) return rd(2, a) end
local rd32 = function(a) return rd(4, a) end
local rd64 = function(a) return rd(8, a) end

-- The same little-endian assembly, but from a byte table already in hand
-- rather than via a fresh CE call. i is 1-based; psz is 4 or 8.
-- Bounds-checked so a caller can pass a window with no look-ahead left.
local function ptrFromChunk(b, i, psz)
if b == nil or i < 1 or i + psz - 1 > #b then return nil end
local v = 0
for k = i + psz - 1, i, -1 do
local x = b[k]
if x == nil then return nil end
v = V256 * v + x
end
return v
end

-- Read an 8-byte PE section name. The field is space-PADDED rather than
-- NUL-terminated, so both 0x00 and 0x20 end the name.
local function trimName(rb)
local s = {}
for j = 1, 8 do
local c = rb[j]
if c == nil or c == 0 or c == 0x20 then break end
s[#s+1] = char(c)
end
return table.concat(s)
end

-----------------------------------------------------------------------
-- PE HELPERS
--
-- Everything below parses the loaded image from memory, never from disk,
-- so it sees what the loader actually mapped.
-----------------------------------------------------------------------

-- Parse a module's headers into a plain table.
--
-- Returns nil on anything that fails a sanity check, which is the caller's
-- signal to abandon rather than to guess. The checks are deliberately
-- conservative: a bogus e_lfanew or section count would otherwise send the
-- scanner reading megabytes away from any real structure.
--
-- Layout facts relied upon: the 16 data directories sit at opt+0x60 (PE32)
-- or opt+0x70 (PE32+), because PE32+ widens ImageBase from 4 to 8 bytes and
-- everything after it shifts by 4. SizeOfImage happens to land at +56 in
-- BOTH formats, which is a coincidence rather than a rule.
local function peInfo(base)
base = normAddr(base)
if base == nil then return nil end

-- DOS header: e_lfanew at 0x3C points at the NT headers.
local e_lfanew = rd32(base + 0x3C)
if e_lfanew == nil or e_lfanew < 0x40 or e_lfanew > 0x100000 then return nil end

local nt = base + e_lfanew
-- "PE\0\0" -- little-endian, so the dword reads as 0x00004550.
if rd32(nt) ~= 0x00004550 then return nil end

-- COFF header: NumberOfSections at +6, SizeOfOptionalHeader at +20.
local nSec, sizeOpt = rd16(nt + 6), rd16(nt + 20)
if nSec == nil or sizeOpt == nil then return nil end
if nSec > 96 then return nil end          -- implausible; a typo cost here is huge

local opt = nt + 24                        -- optional header follows the 24-byte COFF header
local magic = rd16(opt)
local is64 = (magic == 0x20B)              -- 0x20B = PE32+, 0x10B = PE32
if (not is64) and magic ~= 0x10B then return nil end

-- The optional header must be big enough to contain the data directories,
-- otherwise the directory reads below would run into the section table.
if sizeOpt < (is64 and 0xF0 or 0xE0) then return nil end

local entryRva = rd32(opt + 16)            -- AddressOfEntryPoint
if entryRva == nil then return nil end

local ddOff = opt + (is64 and 0x70 or 0x60)
local out = {
is64 = is64, base = base,
entry = base + entryRva,
size = rd32(opt + 56) or 0,                -- SizeOfImage (same offset in both)
imageBase = is64 and rd64(opt + 24) or rd32(opt + 28),
secs = {}, dd = {}
}

-- Each directory entry is 8 bytes: RVA then Size.
for i = 0, 15 do
out.dd[i] = { rva = rd32(ddOff + i * 8), size = rd32(ddOff + i * 8 + 4) }
end

-- Section table: 40 bytes per entry, immediately after the optional header.
local tbl = opt + sizeOpt
for i = 0, nSec - 1 do
local s = tbl + i * 40
local rb = readBytes(s, 8, true)           -- the 8-byte name field
if rb then
local va = rd32(s + 12)                -- VirtualAddress
if va ~= nil then
out.secs[#out.secs+1] = {
name = trimName(rb), rva = va, va = base + va,
vsz = rd32(s + 8),                     -- VirtualSize
rawsz = rd32(s + 16),                  -- SizeOfRawData
rawptr = rd32(s + 20),                 -- PointerToRawData (unused: we read memory)
chr = rd32(s + 36)                     -- Characteristics
}
end
end
end
return out
end

-- Resolve a data directory to (absolute address, size). Returns nil, nil
-- when the directory is absent or empty, which is the common case for TLS,
-- load config and the exception directory in small modules.
local function ddAddr(pe, idx)
local d = pe.dd[idx]
if d == nil or d.rva == nil or d.rva == 0 or d.size == nil or d.size == 0 then
return nil, nil
end
return pe.base + d.rva, d.size
end

-- Effective mapped size of a section. The loader treats VirtualSize == 0
-- as "use SizeOfRawData". A corrupt 0xFFFFFFFF would wrap a Lua 5.3
-- integer into nonsense, so a single section is capped at 512 MB -- larger
-- than any real .text, smaller than any accident.
local function secSize(s)
local sz = 0
if s.vsz and s.vsz > 0 then sz = s.vsz
elseif s.rawsz and s.rawsz > 0 then sz = s.rawsz end
if sz > 0x20000000 then sz = 0x20000000 end
return sz
end

-- Find the executable ranges. Three strategies, in order of trustworthiness:
--   1. section characteristics (the normal path)
--   2. OS page protection (when the section table lies or is stripped)
--   3. nothing at all, which the caller turns into a hard error
--
-- Note that this never assumes the section is called ".text".
local function execSections(pe, base, modSize)
local out = {}
for i = 1, #pe.secs do
local s = pe.secs[i]
local sz = secSize(s)
if sz > 0 and hasBit(s.chr or 0, SCN.MEM_EXEC) then
out[#out+1] = { lo = s.va, hi = s.va + sz - 1, name = s.name, how = 'characteristics' }
end
end
if #out > 0 then return out, 'section table' end

-- Fallback. Bound the search so a wild module size cannot send
-- enumMemoryRegions() scanning the whole address space.
local lim = modSize
if type(lim) ~= 'number' or lim <= 0 then lim = pe.size end
if type(lim) ~= 'number' or lim <= 0 then lim = 0x40000000 end

local rt
-- Wrapped in pcall because enumMemoryRegions is a CE call that can fail on
-- a locked or 64-bit-mismatched target.
if pcall(function() rt = enumMemoryRegions() end) and type(rt) == 'table' then
for _, v in pairs(rt) do
if type(v) == 'table' and type(v.BaseAddress) == 'number'
and type(v.RegionSize) == 'number' and type(v.State) == 'number'
and type(v.Protect) == 'number'
and v.State == MEM_COMMIT and PAGE_EXEC[v.Protect % 256]
and v.BaseAddress >= base and v.BaseAddress < base + lim then
-- Clamp the region to the module: the last region of an image can
-- technically extend past it.
out[#out+1] = { lo = v.BaseAddress,
hi = math.min(v.BaseAddress + v.RegionSize - 1, base + lim - 1),
name = '(unnamed)', how = 'OS page protection' }
end
end
end
return out, #out > 0 and 'OS' or 'NONE'
end

-- Every section whose name STARTS WITH one of pats, in PE order.
-- "Starts with" matters: MSVC emits several .CRT$X* sections and a packer
-- may split .rdata, so matching only the first hit would lose data.
-- plain = true, so the dots are literal rather than Lua pattern wildcards.
local function secSpans(pe, pats)
local spans = {}
if pe == nil or pe.secs == nil then return spans end
for i = 1, #pe.secs do
local s = pe.secs[i]
if s.name then
for j = 1, #pats do
if s.name:find(pats[j], 1, true) == 1 then
local sz = secSize(s)
if sz > 0 then spans[#spans+1] = { lo = s.va, hi = s.va + sz - 1, name = s.name } end
break                              -- one span per section, first pattern wins
end
end
end
end
return spans
end

-- Convert span records into the {lo, hi} pairs the chunk walker wants.
local function spansToRanges(sp)
local r = {}
for i = 1, #sp do r[#r+1] = { sp[i].lo, sp[i].hi } end
return r
end

-- Readable, initialised, NON-executable data: the hunting ground for the
-- pointer scan. Falls back to a characteristics test when the section names
-- have been stripped, because an unnamed but readable data section still
-- holds pointers.
local function dataRanges(pe)
local ranges = {}
for _, pat in ipairs({ '.rdata', '.data', '.didat', '.idata' }) do
local sp = secSpans(pe, { pat })
for i = 1, #sp do ranges[#ranges+1] = { sp[i].lo, sp[i].hi } end
end
if #ranges == 0 then
for i = 1, #pe.secs do
local s = pe.secs[i]
if hasAll(s.chr or 0, { SCN.INITDATA, SCN.MEM_READ })
and not hasBit(s.chr or 0, SCN.MEM_EXEC) then
ranges[#ranges+1] = { s.va, s.va + secSize(s) - 1 }
end
end
end
return ranges
end

-----------------------------------------------------------------------
-- SMALL HELPERS
-----------------------------------------------------------------------

-- Read a printable-ASCII, NUL-free string at addr.
--
-- The three decreasing read sizes are the interesting part: if a 256-byte
-- read fails because the name sits near the end of a mapping, retrying at
-- 64 and then 16 still gets the string rather than giving up. "want <=
-- maxLen" prevents a larger fallback from being tried after a smaller
-- requested size.
--
-- Any byte outside 0x20..0x7E ends the string, which is what stops us at
-- the NUL and at the start of the next field.
local function readCString(addr, maxLen)
addr = normAddr(addr)
if addr == nil then return nil end
maxLen = maxLen or RTTI_NAME_MAX
local b = nil
for _, want in ipairs({ maxLen, 64, 16 }) do
if want <= maxLen then
local r = readBytes(addr, want, true)
if r ~= nil then b = r break end
end
end
if b == nil then return nil end
local s = {}
for i = 1, #b do
local c = b[i]
if c == nil or c < 0x20 or c > 0x7E then break end
s[#s+1] = char(c)
end
if #s == 0 then return nil end
return table.concat(s)
end

-- ".?AVFoo@@" -> "class", "Foo".
--
-- Only a TRAILING "@@" is the terminator; inside a template name "@@"
-- legitimately closes a nested argument, which is why this uses gsub with
-- an anchored pattern rather than a naive split.
--
-- Returns (nil, m) for anything that is not an MSVC type name, so callers
-- can fall back to the raw string.
local function demangle(m)
if m == nil then return nil, nil end
local k, name = m:match('^%.%?A([VUWT])(.+)$')
if k == nil then return nil, m end
name = name:gsub('@@$', '')
return ({ V='class', U='struct', W='enum', T='union' })[k] or '?', name
end

-- Length of ONE padding item starting at b[i], or 0 if there is none.
--
-- Handles: a bare int3/nop; any number of leading 0x66 prefixes followed by
-- 0x90; and the multi-byte NOP cores. limit is the last valid index, so a
-- run cannot read past the window.
--
-- The np > 8 cap exists because an unbounded 0x66 sled is either
-- compression or malice, and either way it is not alignment padding.
local function padItemLen(b, i, limit)
local v = b[i]
if v == nil or i > limit then return 0 end
if PADDING[v] then return 1 end
local j = i
while j <= limit and b[j] == 0x66 do j = j + 1 end
local np = j - i
if np > 8 or j > limit then return 0 end
if np > 0 and b[j] == 0x90 then return np + 1 end          -- 66 90, 66 66 90 ...
for p = 1, #NOPCORE do
local sig = NOPCORE[p]
if j + #sig - 1 <= limit then
local ok = true
for k = 1, #sig do
if b[j + k - 1] ~= sig[k] then ok = false break end
end
if ok then return np + #sig end
end
end
return 0
end

-- Turn a byte table into a Lua string so that string.find can hop between
-- interesting bytes at C speed. Without this, scanning a 30 MB section
-- means 30 million Lua-level iterations; with it, the Lua work is
-- proportional to the number of CANDIDATES.
--
-- The 4096-per-call batching is defensive rather than mandatory: the manual
-- places no documented cap on string.char's argument count [[30]], but a
-- single call with 262144 arguments is a large C-stack demand, and chunking
-- costs nothing.
local function chunkString(b, n)
local parts, np = {}, 0
for i = 1, n, 4096 do
local j = i + 4095
if j > n then j = n end
np = np + 1
parts[np] = char(unpack(b, i, j))
end
return table.concat(parts)
end

-----------------------------------------------------------------------
-- PROPOSAL STORE
--
-- The set of candidate roots, packed. The ONLY acceptance test is inExec():
-- is the address inside an executable section of the module being probed?
-----------------------------------------------------------------------

local roots, callers = {}, {}

-- The executable ranges for the current run, and their bounding box.
-- EXLO/EXHI give a cheap reject before the (still cheap, but not free)
-- per-section loop.
local curSecs = {}
local EXLO, EXHI = 0, -1          -- empty box until a probe sets it

-- The inclusion rule, in four lines.
local function inExec(a)
for i = 1, #curSecs do
local s = curSecs[i]
if a >= s.lo and a <= s.hi then return true end
end
return false
end

-- Record a candidate. Returns true when it was ACCEPTED, which callers use
-- for counting and, in the E8 case, for tallying callers.
local function propose(a, tag)
if type(a) ~= 'number' then return false end
local f = floor(a)
if f ~= a then return false end          -- fractional address
a = f
if a < EXLO or a > EXHI or not inExec(a) then return false end
local bit, cf = TAGBIT[tag], CONF[tag] or 0
local v = roots[a]
if v == nil then
roots[a] = cf * CONFSHIFT + bit
return true
end
local conf = floor(v / CONFSHIFT)
local mask = v - conf * CONFSHIFT
-- Set the tag bit if clear. Adding is safe precisely because we have just
-- tested that the bit is 0, so no carry can propagate.
if floor(mask / bit) % 2 == 0 then mask = mask + bit end
if cf > conf then conf = cf end
roots[a] = conf * CONFSHIFT + mask
return true
end

-----------------------------------------------------------------------
-- CHUNKED DATA WALKER
--
-- Calls fn(b, len, have, a) for every CHUNK-sized window of every range.
--
--   a    = absolute address of the window start
--   b    = byte table (may be longer than len*psz thanks to OVERLAP)
--   len  = whole number of bytes in the window, a multiple of psz
--   have = #b, i.e. bytes actually available including look-ahead
--
-- Windows start psz-aligned, aligned UP, so nothing below the range is ever
-- read. An unreadable window is SKIPPED, not fatal: a module can contain
-- guard pages or holes, and losing 256 KB beats losing the whole scan.
--
-- gl_yield() after each window is what keeps the GUI alive -- this is the
-- cooperative multitasking seam of the entire script.
-----------------------------------------------------------------------
local function eachChunk(ranges, psz, fn, label)
local total = 0
for r = 1, #ranges do total = total + (ranges[r][2] - ranges[r][1] + 1) end
local done = 0
gl_progress(0, total, label)
for r = 1, #ranges do
local lo, hi = ranges[r][1], ranges[r][2]
-- Round the start up to a slot boundary. The double modulo handles
-- lo already being aligned without producing psz.
local a = lo + ((psz - (lo % psz)) % psz)
while a < hi do
local avail = hi - a + 1
local len = math.min(CHUNK, avail)
len = len - (len % psz)              -- truncate to whole slots
if len <= 0 then break end
-- Ask for look-ahead; settle for the bare window if the range ends.
local b = readBytes(a, math.min(len + OVERLAP, avail), true) or readBytes(a, len, true)
if b ~= nil then fn(b, len, #b, a) end
a = a + len; done = done + len
gl_progress(done, total, label); gl_yield()
end
end
end

-----------------------------------------------------------------------
-- S1: THE x64 EXCEPTION DIRECTORY (.pdata)
--
-- RUNTIME_FUNCTION records, 12 bytes each: BeginAddress, EndAddress,
-- UnwindData. EndAddress is the first byte AFTER the function, so extents
-- from this source are EXACT rather than guessed.
--
-- Two caveats shape this whole function:
--   * Only non-leaf functions have an entry -- a function that allocates no
--     stack and calls nothing is simply absent. So .pdata is exact for what
--     it lists but is not a complete list.
--   * The table is specified to be sorted by BeginAddress. That is CHECKED,
--     not trusted, and repaired if violated, because a packer can rewrite
--     it.
--
-- Storage is three parallel number arrays (~32 bytes per record) rather
-- than a table per record.
-----------------------------------------------------------------------
local pdStart, pdEnd, pdChained = {}, {}, {}
local function srcPdata(pe, chainCheck)
pdStart, pdEnd, pdChained = {}, {}, {}
local addr, size = ddAddr(pe, DD.EXCEPTION)
-- The 12-byte RUNTIME_FUNCTION is an x64 structure; PE32 uses a different
-- exception scheme entirely.
if addr == nil or not pe.is64 then return 0 end
local n = floor(size / 12)
if n > 5000000 then n = 5000000 end                 -- corrupt-header cap
-- One CE call per 21845 records (262144 / 12, truncated).
local per = floor(CHUNK / 12)
local base, count, i = pe.base, 0, 0
local sorted, lastLo = true, -1

while i < n do
local m = math.min(per, n - i)
local b = readBytes(addr + i * 12, m * 12, true)
if b == nil then break end
-- A short read means fewer complete records than requested.
m = math.min(m, floor(#b / 12))
if m <= 0 then break end

for r = 0, m - 1 do
local o = r * 12
-- Little-endian dword decode, written inline because doing it via rd32
-- would cost one CE call per field.
local bg = b[o+1] + 256 * b[o+2] + 65536 * b[o+3] + 16777216 * b[o+4]
local en = b[o+5] + 256 * b[o+6] + 65536 * b[o+7] + 16777216 * b[o+8]

-- bg == 0 or en <= bg is the zero padding that terminates the table,
-- not a function. Treating it as data rather than as an error is what
-- lets a padded table scan cleanly.
if bg ~= 0 and en > bg then
local lo = base + bg

-- Is this a secondary fragment (a cold block) rather than a real
-- function entry? Two signals:
--   * UnwindData odd => RUNTIME_FUNCTION_INDIRECT.
--   * UNW_FLAG_CHAININFO, which is flag value 4 sitting in bits 3..5
--     of the UNWIND_INFO first byte => 4 << 3 = 32 = 0x20.
-- Reading ONE byte per record is the whole cost of chainCheck.
local chained = false
if chainCheck then
local u = b[o+9] + 256 * b[o+10] + 65536 * b[o+11] + 16777216 * b[o+12]
if u ~= 0 then
if u % 2 == 1 then
chained = true
else
local ub = readBytes(base + u, 1, true)
if ub ~= nil and ub[1] ~= nil and floor(ub[1] / 32) % 2 == 1 then
chained = true
end
end
end
end

count = count + 1
pdStart[count], pdEnd[count] = lo, base + en
if lo < lastLo then sorted = false end
lastLo = lo
if chained then pdChained[lo] = true end

-- A fragment is tagged FRAG (tier 1); a genuine entry is PDATA (tier 4).
-- This is the single place where cold code is separated from functions.
propose(lo, chained and SRC.FRAG or SRC.PDATA)
end
end
i = i + m
gl_progress(i, n, 'pdata records'); gl_yield()
end

-- Repair an unsorted table by sorting INDEX arrays rather than the records
-- themselves, so pdStart/pdEnd stay in step.
if not sorted then
local idx = {}
for k = 1, count do idx[k] = k end
table.sort(idx, function(x, y) return pdStart[x] < pdStart[y] end)
local s2, e2 = {}, {}
for k = 1, count do s2[k], e2[k] = pdStart[idx[k]], pdEnd[idx[k]] end
pdStart, pdEnd = s2, e2
end
return count
end

-----------------------------------------------------------------------
-- S2/S3: THE BYTE SWEEP
--
-- One pass per executable section, harvesting three things:
--   * targets of E8 rel32 (call)
--   * the first byte after a run of padding
--   * optionally, targets of E9 rel32 (jmp)
--
-- Deliberately NOT instruction-aligned, because aligning requires decoding.
-- The consequence is honest and documented: some E8 hits are immediates or
-- bytes inside a table. Their targets are still inside the module, which is
-- the rule in force.
--
-- Cost model: string.find does the scanning in C, so Lua-level work scales
-- with the number of CANDIDATES, not with section size.
-----------------------------------------------------------------------
local function sweepChunk(a, len, have, b, s, withJumps)
-- ── E8 rel32 ────────────────────────────────────────────────────────
-- Address of the opcode = a + i - 1. The instruction is 5 bytes, so the
-- next instruction -- the base for a relative displacement -- is a + i + 4.
local pos = 1
while true do
local i = find(s, '\232', pos, true)          -- 232 decimal = 0xE8
if i == nil or i > len then break end
if i + 4 <= have then                     -- the displacement must be in-window
local b1, b2, b3, b4 = byte(s, i + 1, i + 4)
local rel = b1 + 256 * b2 + 65536 * b3 + 16777216 * b4
-- Reinterpret as signed: a negative displacement has the top bit set.
if rel >= 2147483648 then rel = rel - 4294967296 end
local t = a + i + 4 + rel
-- callers[] counts DISTINCT E8 sites per target, which later becomes the
-- "called function (N sites)" label and a useful hotness signal.
if propose(t, SRC.CALL) then callers[t] = (callers[t] or 0) + 1 end
end
pos = i + 1                                  -- advance by ONE, not five:
end                                          -- overlapping matches are real

-- ── E9 rel32 (opt-in) ───────────────────────────────────────────────
-- Tail calls and incremental-link thunks. Off by default because in a
-- release build most E9 hits are inside data or are unconditional jumps
-- between blocks of the same function.
if withJumps then
pos = 1
while true do
local i = find(s, '\233', pos, true)          -- 233 decimal = 0xE9
if i == nil or i > len then break end
if i + 4 <= have then
local b1, b2, b3, b4 = byte(s, i + 1, i + 4)
local rel = b1 + 256 * b2 + 65536 * b3 + 16777216 * b4
if rel >= 2147483648 then rel = rel - 4294967296 end
propose(a + i + 4 + rel, SRC.JUMP)
end
pos = i + 1
end
end

-- ── Padding boundaries ──────────────────────────────────────────────
-- The byte AFTER a run of int3/nop/multi-byte nop starts a function.
--
-- Acceptance is deliberately asymmetric, and this is the subtlest rule in
-- the file:
--   * a run of >= 2 pad bytes counts ANYWHERE;
--   * a LONE pad byte counts only when the following address is 16-aligned.
-- Reason: a single 0x90 or 0xCC is far more often an immediate operand or a
-- ModRM byte than it is alignment. Without the alignment proviso the pad
-- source would drown the result set in noise.
--
-- padUntil memoises the end of the last run handled, so a subsequent hit
-- inside an already-consumed run is skipped rather than re-measured.
local padUntil = 0

local function handle(i)
local pl = padItemLen(b, i, have)
if pl == 0 then return false end
local j = i
while pl > 0 do j = j + pl; pl = padItemLen(b, j, have) end  -- consume the run
padUntil = j - 1
if j <= have then
local t = a + j - 1                          -- address of the first byte after
if j - i >= 2 or t % 16 == 0 then propose(t, SRC.PAD) end
end
return true
end

-- Back off over leading 0x66 prefixes so that a prefixed NOP is measured
-- from its true start. Bounded at 8, matching padItemLen's own limit.
local function hit(i)
if i <= padUntil then return end
local s0, n = i, 0
while s0 > 1 and n < 8 and s0 - 1 > padUntil and b[s0 - 1] == 0x66 do
s0 = s0 - 1; n = n + 1
end
-- If prefixes were found, try to handle the whole item from the start; if
-- that fails (it was not a NOP after all), fall through to the original
-- index so a plain 0x66 immediate is still considered.
if s0 ~= i and handle(s0) then return end
handle(i)
end

pos = 1
while true do                                        -- int3 / nop bytes
-- Pattern (not plain) form: a character class holding 0xCC and 0x90.
local i = find(s, '[\204\144]', pos)
if i == nil or i > len then break end
hit(i)
-- Skip past anything just consumed, but never backwards.
pos = math.max(i + 1, padUntil + 1)
end
padUntil = 0                                         -- fresh state for pass 2
pos = 1
while true do                                        -- 0F 1F multi-byte nops
local i = find(s, '\15\31', pos, true)
if i == nil or i > len then break end
local s0 = i
-- The cs segment prefix 0x2E is PART OF the NOP core, not a stray, so
-- step back onto it before measuring.
if s0 > 1 and b[s0 - 1] == 0x2E then s0 = s0 - 1 end
hit(s0)
pos = math.max(i + 1, padUntil + 1)
end
end

-- Drive sweepChunk over every executable section, in CHUNK windows.
local function sweepCode(secs, withJumps)
for si = 1, #secs do
local lo, hi = secs[si].lo, secs[si].hi
local total = hi - lo + 1
local label = 'bytes (S2/S3 sweep, section ' .. si .. ')'
gl_progress(0, total, label)
local a = lo
while a <= hi do
local avail = hi - a + 1
local len = math.min(CHUNK, avail)
local b = readBytes(a, math.min(len + OVERLAP, avail), true) or readBytes(a, len, true)
if b ~= nil then
-- Never look past the end of the section, even if the read gave more.
local have = math.min(#b, avail)
-- pcall because char(unpack(...)) on a malformed table would otherwise
-- abort the entire scan at the offending chunk.
local ok, s = pcall(chunkString, b, have)
if ok then sweepChunk(a, len, have, b, s, withJumps) end
end
a = a + len
gl_progress(a - lo, total, label); gl_yield()
end
end
end

-----------------------------------------------------------------------
-- S4..S7: ENTRY POINT, EXPORTS, TLS CALLBACKS, CRT INITIALISERS
-----------------------------------------------------------------------

-- The single easiest root to find, and always authoritative.
local function srcEntry(pe) propose(pe.entry, SRC.ENTRY) end

-- AddressOfFunctions is indexed by ORDINAL and has NumberOfFunctions
-- entries. Ordinal-only exports exist exactly when that exceeds
-- NumberOfNames, which is why this walks the function array rather than the
-- (smaller, name-indexed) one.
--
-- Two filters: a 0 entry is a gap; an entry pointing INTO the export
-- directory itself is a forwarder STRING, not code, and must be skipped or
-- it becomes a bogus "function" in the middle of the table.
local function srcExports(pe)
local addr, size = ddAddr(pe, DD.EXPORT)
if addr == nil then return 0 end
local nFuncs = rd32(addr + 20)          -- NumberOfFunctions
local atRva  = rd32(addr + 28)          -- AddressOfFunctions
if nFuncs == nil or atRva == nil or atRva == 0 or nFuncs > 0x100000 then return 0 end
local tbl = pe.base + atRva
local eLo, eHi = addr, addr + size
local n, i, per = 0, 0, 16384

while i < nFuncs do
local m = math.min(per, nFuncs - i)
local b = readBytes(tbl + i * 4, m * 4, true)   -- chunked, not rd32 per entry
if b == nil then break end
m = math.min(m, floor(#b / 4))
if m <= 0 then break end
for k = 0, m - 1 do
local o = k * 4
local rva = b[o+1] + 256 * b[o+2] + 65536 * b[o+3] + 16777216 * b[o+4]
if rva ~= 0 then
local t = pe.base + rva
if not (t >= eLo and t < eHi) and propose(t, SRC.EXP) then n = n + 1 end
end
end
i = i + m
gl_progress(i, nFuncs, 'exports'); gl_yield()
end
return n
end

-- IMAGE_TLS_DIRECTORY64: Start +0x00, End +0x08, Index +0x10, CallBacks +0x18
-- IMAGE_TLS_DIRECTORY32: Start +0x00, End +0x04, Index +0x08, CallBacks +0x0C
--
-- AddressOfCallBacks is a VA, not an RVA, and the array is
-- NUL-terminated. The 64-entry guard is belt-and-braces: a missing
-- terminator would otherwise walk off into whatever follows. TLS callbacks
-- run BEFORE the entry point, so they are functions that no call
-- instruction ever references.
local function srcTLS(pe)
local addr, size = ddAddr(pe, DD.TLS)
if addr == nil then return 0 end
local psz = pe.is64 and 8 or 4
local cbOff = pe.is64 and 0x18 or 0x0C
if size < cbOff + psz then return 0 end
local cb = pe.is64 and rd64(addr + cbOff) or rd32(addr + cbOff)
if cb == nil or cb == 0 then return 0 end
local n, guard, a = 0, 0, cb
while guard < 64 do
local f = pe.is64 and rd64(a) or rd32(a)
if f == nil or f == 0 then break end
if propose(f, SRC.TLS) then n = n + 1 end
a = a + psz; guard = guard + 1
end
return n
end

-- MSVC merges .CRT into .rdata by default, so this usually finds nothing
-- and the initialisers are picked up by the data-pointer scan (S8) instead.
-- It is kept because a custom link layout does produce real .CRT$X*
-- sections, and those pointers are authoritative.
--
-- Prefix matching matters: there are MANY .CRT$Xca / $Xcz / $Xyb sections,
-- ordered by name, and taking only the first would lose most initialisers.
local function srcCRT(pe)
local spans = secSpans(pe, { '.CRT', '.00CRT', 'CRT' })
if #spans == 0 then spans = secSpans(pe, { '.init' }) end   -- clang/gcc style
if #spans == 0 then return 0 end
local psz = pe.is64 and 8 or 4
local n = 0
eachChunk(spansToRanges(spans), psz, function(b, len, have, a)
local lim = math.min(len, have - psz + 1)
for k = 1, lim, psz do
local q = ptrFromChunk(b, k, psz)
if q ~= nil and q ~= 0 and propose(q, SRC.CRT) then n = n + 1 end
end
end, 'bytes (S7 CRT initialisers)')
return n
end

-----------------------------------------------------------------------
-- S11: CFG CALL-TARGET LIST
--
-- Control Flow Guard makes the compiler publish every legitimate indirect
-- call target. That list is a gift to a function finder: it is authoritative
-- and it includes functions nothing calls.
--
-- IMAGE_LOAD_CONFIG_DIRECTORY field offsets:
--     x86     x64
--   GuardCFFunctionTable (VA)   +0x50   +0x80
--   GuardCFFunctionCount        +0x54   +0x88
--   GuardFlags                  +0x58   +0x90
--
-- Entries are (4 + n) bytes: a 32-bit RVA then n metadata bytes, where
-- n = (GuardFlags >> 28) & 0xF. The stride is therefore NOT fixed, and
-- getting it wrong desynchronises the whole table -- hence reading the
-- structure's own Size field first and refusing to parse if the structure
-- predates these fields.
--
-- Caution for future readers: x64 GuardCFFunctionTable parsing has a
-- respectable history of being implemented incorrectly, Ghidra included.
-- Treat the offsets above as the file's claim, verified against the table
-- contents rather than assumed.
-----------------------------------------------------------------------
local function srcCFG(pe)
local addr = ddAddr(pe, DD.LOADCFG)     -- size discarded: not needed here
if addr == nil then return 0 end
local oTbl, oCnt, oFlg
if pe.is64 then oTbl, oCnt, oFlg = 0x80, 0x88, 0x90
else            oTbl, oCnt, oFlg = 0x50, 0x54, 0x58 end
local lcSize = rd32(addr)               -- the structure's own Size field
if lcSize == nil or lcSize < oFlg + 4 then return 0 end
-- The table pointer and count are VA-sized on x64, dword-sized on x86.
local tbl   = pe.is64 and rd64(addr + oTbl) or rd32(addr + oTbl)
local count = pe.is64 and rd64(addr + oCnt) or rd32(addr + oCnt)
local flags = rd32(addr + oFlg)
if tbl == nil or count == nil or flags == nil or tbl == 0 or count == 0 then return 0 end
if count > 4000000 then return 0 end            -- implausible: corrupt header

local stride = 4 + (floor(flags / 268435456) % 16)     -- 268435456 = 2^28
local per = math.max(1, floor(CHUNK / stride))
local n, i = 0, 0
while i < count do
local m = math.min(per, count - i)
local b = readBytes(tbl + i * stride, m * stride, true)
if b == nil then break end
for k = 0, m - 1 do
local rva = ptrFromChunk(b, k * stride + 1, 4)
if rva ~= nil and rva ~= 0 and propose(pe.base + rva, SRC.CFG) then n = n + 1 end
end
i = i + m
gl_progress(i, count, 'cfg targets'); gl_yield()
end
return n
end

-----------------------------------------------------------------------
-- S8: CODE POINTERS IN DATA
--
-- A qword (dword on PE32) in .rdata/.data/.didat/.idata whose value lands in
-- the module's code. This is the catch-all for callbacks, thread procs,
-- window procedures and std::function targets -- things that are entered
-- indirectly and so may appear in no other list.
--
-- The performance trick is the PRE-FILTER: before assembling a 64-bit value
-- from eight bytes, check that the two middle bytes of the UPPER dword match
-- the module's address window. On a typical x64 image the whole module lives
-- inside one 4 GB window, so this rejects almost every slot after reading
-- just two table entries.
-----------------------------------------------------------------------
local function scanPtrs(pe, ranges)
local is64 = pe.is64
local psz = is64 and 8 or 4
local n = 0
local fast, U4, U5 = false, 0, 0
if is64 then
-- fast is only available when the bounding box does not straddle a 4 GB
-- boundary; otherwise the high dword varies and the test would be wrong.
local ulo, uhi = floor(EXLO / 4294967296), floor(EXHI / 4294967296)
if ulo == uhi then fast = true; U4 = ulo % 256; U5 = floor(ulo / 256) % 256 end
end
-- PE32 pre-filter: the TOP BYTE of a dword must lie in the module's 16 MB
-- bucket range. Coarser, but the same idea.
local tbLo, tbHi = floor(EXLO / 16777216), floor(EXHI / 16777216)

eachChunk(ranges, psz, function(b, len, have, a)
local lim = math.min(len, have - psz + 1)
if is64 then
for k = 1, lim, 8 do
if (not fast) or (b[k+4] == U4 and b[k+5] == U5) then
local q = (b[k] + 256 * b[k+1] + 65536 * b[k+2] + 16777216 * b[k+3])
+ (b[k+4] + 256 * b[k+5] + 65536 * b[k+6] + 16777216 * b[k+7]) * 4294967296
if q >= EXLO and q <= EXHI and propose(q, SRC.PTR) then n = n + 1 end
end
end
else
for k = 1, lim, 4 do
local t = b[k+3]
if t >= tbLo and t <= tbHi then
local q = b[k] + 256 * b[k+1] + 65536 * b[k+2] + 16777216 * t
if q >= EXLO and q <= EXHI and propose(q, SRC.PTR) then n = n + 1 end
end
end
end
end, 'bytes (S8 data pointers)')
return n
end

-- OPT-IN. Every dword in (0, SizeOfImage) that lands in code qualifies, so
-- switch-case labels, EH tables and plain integers all flood in. Without
-- verification -- which would need decoding, and we do not decode -- that is
-- mostly noise. Hence off by default, and tagged separately (RVA / XDATA)
-- so it can be filtered out again.
--
-- x64 only: on PE32 an RVA is indistinguishable from a small integer, so the
-- signal-to-noise ratio collapses entirely.
local function scanRvas(pe, ranges, tag, label)
if not pe.is64 then return 0 end
local limit = pe.size
local topMax = floor(limit / 16777216)
local base, n = pe.base, 0
eachChunk(ranges, 4, function(b, len, have, a)
local lim = math.min(len, have - 3)
for k = 1, lim, 4 do
if b[k+3] <= topMax then                 -- cheap reject on the top byte
local r = b[k] + 256 * b[k+1] + 65536 * b[k+2] + 16777216 * b[k+3]
if r > 0 and r < limit then
local t = base + r
if t >= EXLO and t <= EXHI and propose(t, tag) then n = n + 1 end
end
end
end
end, label)
return n
end

-----------------------------------------------------------------------
-- RTTI  (MSVC / clang-cl ABI only; MinGW's Itanium RTTI has a different
--       layout and will simply produce no COLs)
--
--   x64: signature = 1, and every COL/CHD/BCD/TypeDescriptor reference is a
--        32-bit RVA. The COL is 24 bytes and ends with pSelf, the COL's own
--        RVA. The class name sits at TD+0x10.
--   x86: signature = 0, references are absolute 32-bit pointers, the COL is
--        20 bytes, and the name sits at TD+0x08.
--
--   COL  = { signature +0x00, offset +0x04, cdOffset +0x08,
--            pTypeDescriptor +0x0C, pClassHierarchyDescriptor +0x10,
--            [x64: pSelf +0x14] }
--   CHD  = { signature +0x00, attributes +0x04, numBaseClasses +0x08,
--            pBaseClassArray +0x0C }
--   BCD  = { pTypeDescriptor +0x00, numContainedBases +0x04, PMD +0x08,
--            attributes +0x14 }
--
--   A vftable is PRECEDED by a pointer to its COL, at vftable - psz.
--   That single relationship is what turns "a class name" into "the
--   addresses of its virtual methods".
-----------------------------------------------------------------------
local cols, hierarch, vtblMap, funcToClass = {}, {}, {}, {}

-- Turn a stored reference into an absolute address: on x64 it is an RVA and
-- must be based; on x86 it is already absolute.
local function ptrRef(pe, v)
if v == nil then return nil end
if pe.is64 then return pe.base + v end
return v
end

-- Extract a base class's type name from a BCD.
--
-- Rather than trusting one offset, this PROBES the plausible 4-byte-aligned
-- positions 0x00..0x14 and accepts the first that resolves to a string
-- matching the MSVC type-name pattern. +0x00 is tried first because that IS
-- the Microsoft field; the probing exists because toolchains disagree about
-- padding inside the PMD, and a wrong guess here loses only one base class
-- rather than the whole hierarchy.
local function bcdTypeName(pe, bcdVA, nameOff)
bcdVA = normAddr(bcdVA)
if bcdVA == nil then return nil end
for off = 0, 0x14, 4 do
local v = rd32(bcdVA + off)
if v ~= nil and v ~= 0 then
local td = ptrRef(pe, v)
if td ~= nil then
local nm = readCString(td + nameOff, RTTI_NAME_MAX)
if nm ~= nil and nm:match('^%.%?A[VUWT]') then return nm end
end
end
end
return nil
end

-- PASS 1: find every Complete Object Locator from bytes ALREADY in memory.
--
-- This is the fix for the old revision's biggest cost: it used to call
-- looksLikeCOL() -> rd32() (a CE call) for every pointer-sized slot of
-- .rdata. Now all structural tests run on the chunk table, and CE is called
-- once per SURVIVING candidate -- roughly one call per class instead of one
-- per slot.
--
-- Two modes:
--   strict -- x64 only, requires pSelf to equal the COL's own RVA. This is
--             a very strong discriminator: it is essentially self-addressing
--             proof, and it eliminates almost every accidental match.
--   loose  -- drops the pSelf test. Retried only if strict found NOTHING,
--             in case a toolchain omitted the field.
--
-- The candidate tests, in order of increasing cost:
--   1. first byte == signature, next three == 0        (one table lookup)
--   2. top byte of pTypeDescriptor in range            (one comparison)
--   3. offset-to-top and CD offset < 1 MB              (sane object layout)
--   4. td/chd inside the image (x64) or the module (x86)
--   5. strict: pSelf == own RVA
--   6. the name at TD+nameOff matches '^%.%?A[VUWT]'  (the CE call)
-- Interpret a 32-bit unsigned quantity as a signed two's-complement number.
-- This is used for RTTI offset fields that may legitimately contain small
-- negative values.
local function asSigned32(v)
    if v >= 0x80000000 then
        return v - 0x100000000
    end
    return v
end

local function scanCols(pe, ranges, strict)
    local base, size, is64 = pe.base, pe.size, pe.is64
    local nameOff = is64 and 0x10 or 0x08
    local sig = is64 and 1 or 0

    -- x64 strict needs pSelf at +0x14, so 24 bytes.
    -- x86 COL is 20 bytes.
    -- x64 loose does not read pSelf, so 20 bytes is enough.
    local need = (is64 and strict) and 24 or 20

    -- Top-byte acceptance windows for pTypeDescriptor.
    --
    -- x64: pTypeDescriptor is a 32-bit RVA, so acceptable top bytes are
    --      those belonging to RVAs in [0, size).
    -- x86: pTypeDescriptor is an absolute 32-bit pointer, so acceptable
    --      top bytes are those belonging to addresses in [base, base+size).
    local tLo, tHi
    if size <= 0 then
        tLo, tHi = 1, 0
    elseif is64 then
        tLo = 0
        tHi = floor((size - 1) / 16777216)
    else
        tLo = floor(base / 16777216)
        tHi = floor((base + size - 1) / 16777216)
    end

    local found = 0

    eachChunk(ranges, 4, function(b, len, have, a)
        -- A candidate COL starting at b[k] needs `need` bytes:
        --
        --   k + need - 1 <= have
        --
        -- therefore:
        --
        --   k <= have - (need - 1)
        local lim = math.min(len, have - (need - 1))

        for k = 1, lim, 4 do
            -- Test 1: signature dword.
            --
            -- x64 COL signature is 1:
            --   01 00 00 00
            --
            -- x86 COL signature is 0:
            --   00 00 00 00
            if b[k] == sig and b[k + 1] == 0 and b[k + 2] == 0 and b[k + 3] == 0 then

                -- Test 2: top byte of pTypeDescriptor.
                --
                -- pTypeDescriptor is at COL + 0x0C:
                --   bytes k+12, k+13, k+14, k+15
                --
                -- The top byte is k+15.
                local tb = b[k + 15]

                if tb >= tLo and tb <= tHi then

                    -- offset is at COL + 0x04.
                    local off = b[k + 4]
                        + 256 * b[k + 5]
                        + 65536 * b[k + 6]
                        + 16777216 * b[k + 7]

                    -- cdOffset is at COL + 0x08.
                    local cd = b[k + 8]
                        + 256 * b[k + 9]
                        + 65536 * b[k + 10]
                        + 16777216 * b[k + 11]

                    -- Treat these as signed 32-bit values for the sanity
                    -- bound. Small negative offsets should not be rejected
                    -- merely because their unsigned representation is huge.
                    local soff = asSigned32(off)
                    local scd  = asSigned32(cd)

                    if soff > -0x100000 and soff < 0x100000
                       and scd  > -0x100000 and scd  < 0x100000 then

                        -- Reconstruct pTypeDescriptor.
                        local td = b[k + 12]
                            + 256 * b[k + 13]
                            + 65536 * b[k + 14]
                            + 16777216 * tb

                        -- pClassHierarchyDescriptor is at COL + 0x10.
                        local chd = b[k + 16]
                            + 256 * b[k + 17]
                            + 65536 * b[k + 18]
                            + 16777216 * b[k + 19]

                        local ok

                        if is64 then
                            -- Test 4a: x64 RTTI references are RVAs.
                            ok = td > 0 and td < size
                               and chd > 0 and chd < size

                            if ok and strict then
                                -- Test 5: x64 strict checks pSelf.
                                --
                                -- pSelf is at COL + 0x14 and should equal
                                -- the COL's own RVA.
                                local selfRva = b[k + 20]
                                    + 256 * b[k + 21]
                                    + 65536 * b[k + 22]
                                    + 16777216 * b[k + 23]

                                ok = (selfRva == a + k - 1 - base)
                            end
                        else
                            -- Test 4b: x86 RTTI references are absolute
                            -- 32-bit pointers.
                            ok = td >= base and td < base + size
                               and chd >= base and chd < base + size
                        end

                        if ok then
                            local tdVA, chdVA = ptrRef(pe, td), ptrRef(pe, chd)

                            -- Test 6: read the TypeDescriptor name.
                            --
                            -- x64 name is at TD + 0x10.
                            -- x86 name is at TD + 0x08.
                            local nm = readCString(tdVA + nameOff, RTTI_NAME_MAX)

                            if nm ~= nil and nm:match('^%.%?A[VUWT]') then
                                local col = a + k - 1

                                if cols[col] == nil then
                                    cols[col] = {
                                        tdAddr  = tdVA,
                                        tdName  = nm,
                                        chdAddr = chdVA
                                    }
                                    found = found + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end, 'bytes (RTTI COL scan' .. (strict and '' or ', loose') .. ')')

    return found
end

-- Walk one vftable: every CONSECUTIVE code pointer after the first slot is
-- a virtual method.
--
-- Reads 16 slots at a time rather than one CE call per slot, because typical
-- vftables are short and the batched read is nearly free. Falls back to a
-- single-slot read at a mapping edge.
--
-- Stops at the first slot that is not an in-module code address. That is
-- both the natural end of the table and the safety net against a data array
-- that merely looks like one.
--
-- Note the design decision recorded in the original: vtable slots are ROOTS,
-- not just names. Discovering a class is useless unless its methods enter
-- the function list.
local function walkVtable(pe, vslot, nm)
local psz = pe.is64 and 8 or 4
local slot, c = vslot, 0
while c < VTABLE_SLOTS do
local b = readBytes(slot, 16 * psz, true)
if b == nil then b = readBytes(slot, psz, true) end    -- edge of a mapping
if b == nil then break end
local got = floor(#b / psz)
if got == 0 then break end
for i = 0, got - 1 do
local fa = ptrFromChunk(b, i * psz + 1, psz)
if fa == nil or fa < EXLO or fa > EXHI or not inExec(fa) then return c end
-- First class to claim a method keeps it. Two vftables can share a
-- slot value (a common tail, or a thunk), and the first winner is as
-- good an answer as any.
if funcToClass[fa] == nil then funcToClass[fa] = nm end
propose(fa, SRC.VTBL)
c = c + 1
if c >= VTABLE_SLOTS then return c end
end
slot = slot + got * psz
end
return c
end

-- PASS 2: a slot whose VALUE is a known COL address is the slot at
-- vftable - psz, so the vftable begins one pointer later.
--
-- vslot = a + k - 1 + psz   ==>   mem[vftable − psz] = col
--
-- which is the invariant worth remembering: on x64, subtract 8 from a
-- reported vftable address and you must land on its COL.
local function scanVtables(pe, ranges)
local is64 = pe.is64
local psz = is64 and 8 or 4
local lo, hi = pe.base, pe.base + pe.size - 1
-- Same pre-filter as scanPtrs, same rationale.
local fast, U4, U5 = false, 0, 0
if is64 then
local ulo, uhi = floor(lo / 4294967296), floor(hi / 4294967296)
if ulo == uhi then fast = true; U4 = ulo % 256; U5 = floor(ulo / 256) % 256 end
end
local tbLo, tbHi = floor(lo / 16777216), floor(hi / 16777216)
local nv = 0
eachChunk(ranges, psz, function(b, len, have, a)
local lim = math.min(len, have - psz + 1)
for k = 1, lim, psz do
local q = nil
if is64 then
if (not fast) or (b[k+4] == U4 and b[k+5] == U5) then
q = (b[k] + 256 * b[k+1] + 65536 * b[k+2] + 16777216 * b[k+3])
+ (b[k+4] + 256 * b[k+5] + 65536 * b[k+6] + 16777216 * b[k+7]) * 4294967296
end
else
local t = b[k+3]
if t >= tbLo and t <= tbHi then
q = b[k] + 256 * b[k+1] + 65536 * b[k+2] + 16777216 * t
end
end
if q ~= nil then
-- The hash lookup is the whole test: is this value a COL we found?
local c = cols[q]
if c ~= nil then
local vslot = a + k - 1 + psz
vtblMap[vslot] = { colAddr = q, className = c.tdName }
walkVtable(pe, vslot, c.tdName)
nv = nv + 1
end
end
end
end, 'bytes (RTTI vtable walk)')
return nv
end

-- Build the inheritance map: class -> { bases = {...}, attrs = ... }.
--
-- One read fetches the WHOLE base-class array (nb * 4 bytes) rather than
-- one read per base. nb is capped at 4096 because a corrupt count would
-- otherwise ask for a gigantic read.
--
-- Keyed by the MANGLED name, since that is what cols[] holds -- which is
-- why base() does not compose directly with classOf().
local function buildHierarchy(pe)
local nameOff = pe.is64 and 0x10 or 0x08
for _, col in pairs(cols) do
if col.chdAddr then
local nb = rd32(col.chdAddr + 0x08)          -- numBaseClasses
local ar = rd32(col.chdAddr + 0x0C)          -- pBaseClassArray (RVA on x64)
if nb and ar and nb > 0 and nb < 4096 then
local arr = ptrRef(pe, ar)
local bases = {}
if arr ~= nil then
local ab = readBytes(arr, nb * 4, true)
if ab ~= nil then
for i = 0, floor(#ab / 4) - 1 do
local v = ab[i*4+1] + 256 * ab[i*4+2] + 65536 * ab[i*4+3] + 16777216 * ab[i*4+4]
local bn = bcdTypeName(pe, ptrRef(pe, v), nameOff)
if bn then bases[#bases+1] = bn end
end
end
end
hierarch[col.tdName] = { bases = bases, attrs = rd32(col.chdAddr + 0x04) or 0 }
end
end
end
end

-----------------------------------------------------------------------
-- RESULTS
--
-- The durable output is SIX PARALLEL NUMBER ARRAYS (~100 bytes per function)
-- rather than one ~650-byte table per function. Parallel arrays are the
-- price of that: there is no per-row allocation, but every reader must
-- remember that index i means the same function in all six.
--
--   fStart[i]    absolute address of the function
--   fEnd[i]      first byte AFTER it (exclusive) (-1 for output files)
--   fMask[i]     packed source-bit mask
--   fConf[i]     confidence tier 0..4
--   fCallers[i]  number of distinct E8 sites targeting it
--   fKind[i]     extent class: 0 = guessed, 1 = exact .pdata, 2 = nested
--
-- confA/confB hold the nested pairs (enclosing .pdata start, nested start)
-- for the conflicts() listing.
-----------------------------------------------------------------------
local fStart, fEnd, fMask, fConf, fCallers, fKind = {}, {}, {}, {}, {}, {}
local confA, confB = {}, {}

-- Turn the unordered candidate hash into the sorted result arrays, and
-- assign an extent to every function.
--
-- EXTENT POLICY, in order of preference:
--   1. exact, when the start is itself a .pdata BeginAddress -> use EndAddress
--   2. clipped, when it lies inside a .pdata body -> min(next candidate, body end)
--   3. guessed, otherwise -> next candidate, or the section end
--
-- The merge between the sorted candidate list and the sorted .pdata arrays
-- is a single linear walk with one cursor (p) that only ever advances, so
-- the whole thing is O(n log n) for the sort and O(n + m) after it.
--
-- No instruction is decoded anywhere in this function.
local function analyze(secs, nroot)
gl_phase('Sorting candidates')
local cand, n = {}, 0
for a in pairs(roots) do n = n + 1;  cand[n] = a end
table.sort(cand)                       -- ascending by address; ties impossible
gl_phase('Computing extents and status')
fStart, fEnd, fMask, fConf, fCallers, fKind= {}, {}, {}, {}, {}, {}
confA, confB = {}, {}
local p, np = 1, #pdStart
local nNested, nExact, nAuth, guessed = 0, 0, 0, 0

for k = 1, n do
local st = cand[k]
local v = roots[st]
local conf = floor(v / CONFSHIFT)
local mask = v - conf * CONFSHIFT

-- Advance the .pdata cursor past every record that ends at or before st.
-- On exit, pdStart[p] is the first record beginning at or after st, so
-- "pdStart[p] < st" is exactly the test for "st is inside a body".
while p <= np and pdEnd[p] <= st do p = p + 1 end

-- Upper bound: the end of the section containing st. (Initialised to st
-- so that a candidate in no section -- which cannot happen, since
-- propose() checked -- still yields a non-empty extent.)
local secHi = st
for s = 1, #secs do
if st >= secs[s].lo and st <= secs[s].hi then secHi = secs[s].hi break end
end
local limit = secHi + 1
local nxt = cand[k + 1]
if nxt ~= nil and nxt < limit then limit = nxt end

local en, kv
if p <= np and pdStart[p] == st then
-- Case 1: the compiler told us exactly where this function ends.
en, kv = pdEnd[p], 1
nExact = nExact + 1
elseif p <= np and pdStart[p] < st then
-- Case 2: inside somebody else's body.
en = math.min(limit, pdEnd[p])
if conf >= 3 then
-- Strong enough to be its own function (a thunk, a hot path
-- outlined separately). Kept, not flagged.
kv = 0
else
-- Weak: reported as nested so it can be filtered out.
kv = 2
nNested = nNested + 1
confA[#confA + 1], confB[#confB + 1] = pdStart[p], st
end
else
-- Case 3: no .pdata information at all.
en, kv = limit, 0
end

-- Accounting. Note that case 2 with conf >= 3 is counted as guessed even
-- though its bound is real: the count is deliberately conservative, so
-- "guessed-extent bytes" never understates uncertainty.
if kv == 0 then guessed = guessed + (en - st) end
if conf >= 3 and kv ~= 2 then nAuth = nAuth + 1 end

fStart[k], fEnd[k], fMask[k], fConf[k] = st, en, mask, conf
fCallers[k], fKind[k] = callers[st] or 0, kv
-- Progress every 8192 functions: frequent enough to feel live, rare
-- enough that the UI update is not the cost of the scan.
if k % 8192 == 0 then gl_progress(k, n, 'functions'); gl_yield() end
end
gl_progress(n, n, 'functions')
return { nroot = nroot, nfuncs = n, nested = nNested, exact = nExact,
auth = nAuth, guessed = guessed }
end

-----------------------------------------------------------------------
-- DRIVER
--
-- The coroutine/timer pair is what keeps Cheat Engine responsive. The
-- coroutine holds the scan state; the timer resumes it once per millisecond;
-- every gl_yield() inside a scan returns control to the GUI between chunks.
-----------------------------------------------------------------------
local gl_co, gl_tmr, gl_busy = nil, nil, false

-- Single exit point for both success and failure. Clears every large
-- structure -- including on the error path, so nothing is left half-built --
-- then prints the summary.
local function gl_stop(err, stat)
if gl_tmr then pcall(function() gl_tmr.destroy() end); gl_tmr = nil end
gl_co = nil
gl_close()
roots, callers = {}, {}
pdStart, pdEnd, pdChained = {}, {}, {}
cols = {}
gl_freeCaches()
if err then
print('ghidraLike failed: ' .. tostring(err))
return
end
print('Done!')
end

local function _endWindow()
	gl_stop()
end

-- Public entry point. ALWAYS returns nil -- success, failure and "already
-- running" alike -- because the work is asynchronous. Poll count() or watch
-- for the summary lines.
local function _probe()
if gl_co ~= nil then print('ghidraLike already running'); return nil end

local module0 = process       -- CE global: main module of the opened process
if module0 == nil then
print('ghidraLike: pass a module name (e.g. "game.exe") or open a process first')
return nil
end

moduleName=tostring(module0)

roots, callers = {}, {}
pdStart, pdEnd, pdChained = {}, {}, {}
fStart, fEnd, fMask, fConf, fCallers, fKind = {}, {}, {}, {}, {}, {}
confA, confB = {}, {}
cols, hierarch, vtblMap, funcToClass = {}, {}, {}, {}
lastStat = nil

gl_open('ghidraLike - ' .. tostring(module0))

gl_co = coroutine.create(function()
local t0 = os.clock()
local base = normAddr(getAddress(module0))
moduleAddress=base
local modSize = normAddr(getModuleSize(module0))
if base == nil then
error('getAddress("' .. tostring(module0) .. '") returned no address')
end

local pe = peInfo(base)
if pe == nil then error('PE parse failed for ' .. tostring(module0)) end
pe.moduleName = module0

-- SizeOfImage can be zero in a hand-crafted or damaged header. Fall back
-- first to the module size CE reports, then to the largest section end.
if pe.size == nil or pe.size == 0 then pe.size = modSize or 0 end
if pe.size == 0 then
for i = 1, #pe.secs do
local e = pe.secs[i].rva + secSize(pe.secs[i])
if e > pe.size then pe.size = e end
end
end

gl_phase('Resolving executable sections')
local secs, how = execSections(pe, base, modSize)
if #secs == 0 then error('no executable region in ' .. tostring(module0)) end

-- THE INCLUSION RULE LIVES HERE. These ranges, and nothing else, define
-- what counts as code for the rest of the run.
curSecs = secs
EXLO, EXHI = secs[1].lo, secs[1].hi
local tot = 0
for i = 1, #secs do
tot = tot + (secs[i].hi - secs[i].lo + 1)
if secs[i].lo < EXLO then EXLO = secs[i].lo end
if secs[i].hi > EXHI then EXHI = secs[i].hi end
print(string.format('  exec[%d] %-10s %X-%X (%.1f MB) via %s',
i, secs[i].name, secs[i].lo, secs[i].hi,
(secs[i].hi - secs[i].lo + 1) / 1048576, secs[i].how))
end
print(string.format('%s  executable total %.1f MB (%d section(s), source: %s)',
module0, tot / 1048576, #secs, how))
-- Page-protection resolution means the section table was unusable. If the
-- image is still decrypting, some of it may not be mapped yet.
if how == 'OS' then
print('  WARNING: resolved by page protection - if the image is still being'
.. ' decrypted, re-run after the game has fully started.')
end

-- ── sources ─────────────────────────────────────────────────────
gl_phase('S1  .pdata (exception directory)')
print('S1 pdata records: ' .. srcPdata(pe, true))

gl_phase('S2/S3  code sweep (E8 + padding' .. ' + E9' .. ')')
sweepCode(secs, true)
print('S2/S3 sweep done  candidates so far: ' .. cnt(roots))

gl_phase('S4  entry point');  srcEntry(pe)
gl_phase('S5  export table'); print('S5 exports: ' .. srcExports(pe))
gl_phase('S6  TLS callbacks'); print('S6 tls: ' .. srcTLS(pe))
gl_phase('S7  .CRT initialisers'); print('S7 crt: ' .. srcCRT(pe))

-- Computed once: used by S8 and as the RTTI fallback when .rdata is absent.
local dr = dataRanges(pe)

gl_phase('S8  data pointers')
print('S8 data ptrs: ' .. scanPtrs(pe, dr))

gl_phase('S9  32-bit RVA pointers (opt-in)')
local n9 = 0
local rs = secSpans(pe, { '.rdata' })
for si = 1, #rs do
n9 = n9 + scanRvas(pe, { { rs[si].lo, rs[si].hi } }, SRC.RVA, 'bytes (S9 rvas)')
end
local xs = secSpans(pe, { '.xdata' })
for si = 1, #xs do
n9 = n9 + scanRvas(pe, { { xs[si].lo, xs[si].hi } }, SRC.XDATA, 'bytes (S9b xdata rvas)')
end
print('S9 rvas: ' .. n9)


gl_phase('S11 CFG call-target list')
print('S11 cfg: ' .. srcCFG(pe))

gl_phase('RTTI: COL scan')
-- COLs live in .rdata; if that section has been renamed or merged, fall
-- back to the general data ranges.
local rr = spansToRanges(secSpans(pe, { '.rdata' }))
if #rr == 0 then rr = dr end
local nc = scanCols(pe, rr, true)
if nc == 0 and pe.is64 then nc = scanCols(pe, rr, false) end
if nc == 0 then
print('RTTI: no Complete Object Locators found (built with /GR-, stripped, or an'
  .. ' Itanium-ABI/MinGW module).')
else
gl_phase('RTTI: vtable walk')
local nv = scanVtables(pe, rr)
gl_phase('RTTI: hierarchy')
buildHierarchy(pe)
print(string.format('RTTI: cols=%d  vtables=%d  funcToClass=%d  hierarchies=%d',
  nc, nv, cnt(funcToClass), cnt(hierarch)))
end


-- ── results ─────────────────────────────────────────────────────
local nroot = cnt(roots)          -- proposed, before the inclusion filter's
local stat = analyze(secs, nroot) -- nroot vs nfuncs shows how many were dropped

-- Release the scan inputs now that the flat arrays hold everything.
roots, callers = {}, {}
pdStart, pdEnd, pdChained = {}, {}, {}
cols = {}

return stat
end)

-- The pump. Interval 1 ms: fast enough to feel instantaneous, and the
-- coroutine does the real work between ticks.
gl_tmr = createTimer(getMainForm())
gl_tmr.Interval = 1
gl_tmr.OnTimer = function()
if gl_busy or gl_co == nil then return end
gl_busy = true                       -- re-entrancy guard
local ok, res = coroutine.resume(gl_co)
gl_busy = false
if not ok then
-- Build the traceback from the DEAD coroutine so the message names the
-- function and line that actually failed, not the timer callback.
local msg = tostring(res)
if debug and debug.traceback then
local okTb, tb = pcall(debug.traceback, gl_co, msg)
if okTb and type(tb) == 'string' then msg = tb end
end
gl_stop(msg, nil)
elseif coroutine.status(gl_co) == 'dead' then
gl_stop(nil, res)                    -- res is the stat table
end
end
return nil
end

-----------------------------------------------------------------------
-- OUTPUT
-----------------------------------------------------------------------

-----------------------------------------------------------------------
-- OUTPUT
-----------------------------------------------------------------------

-- Is this tag present in a packed mask?
local function hasTag(mask, tag) return floor(mask / TAGBIT[tag]) % 2 == 1 end

-- Mask -> ordered list of tag names. Order comes from TAGORDER, so two runs
-- produce identical strings for identical input.
local function tagsOf(mask)
local t = {}
for i = 1, #TAGORDER do
if hasTag(mask, TAGORDER[i]) then t[#t+1] = TAGORDER[i] end
end
return t
end

-- status: 'nested' is a FLAG, not a rejection -- the file's rule is that
-- nothing is deleted. A weak candidate inside a .pdata body is nested;
-- anything with tier >= 3 elsewhere is authoritative; the rest is included.
local function statusOf(kv, conf)
if kv == 2 then return 'nested' end
if conf >= 3 then return 'authoritative' end
return 'included'
end

-- Human label for a function. FIRST MATCH WINS, in this precedence order,
-- which is why a virtual method that is also in .pdata reports as
-- "vtable method" -- check srcs for 'pdata' if you want the stronger claim.
local function kindOf(mask, nCallers, cls)
if hasTag(mask, SRC.VTBL) then
if cls then
local _, name = demangle(cls)
return 'vtable method [' .. (name or cls) .. ']'
end
return 'vtable method'
elseif hasTag(mask, SRC.PDATA) then return 'function (compiler-recorded)'
elseif hasTag(mask, SRC.CFG)   then return 'CFG call target'
elseif hasTag(mask, SRC.EXP)   then return 'export'
elseif hasTag(mask, SRC.TLS)   then return 'TLS callback'
elseif hasTag(mask, SRC.CRT)   then return 'global constructor'
elseif hasTag(mask, SRC.ENTRY) then return 'entry point'
elseif hasTag(mask, SRC.DYN)   then return 'observed indirect target'
elseif hasTag(mask, SRC.FRAG)  then return 'function fragment (chained unwind)'
elseif hasTag(mask, SRC.CALL)  then return 'called function'
elseif hasTag(mask, SRC.XDATA) then return 'exception/unwind target'
elseif hasTag(mask, SRC.PTR) or hasTag(mask, SRC.RVA) then
return 'pointer-referenced (callback / thread entry / indirect)'
elseif hasTag(mask, SRC.PAD)   then return 'isolated (after padding)'
elseif hasTag(mask, SRC.JUMP)  then return 'jump target (tail call / thunk)'
end
return 'unknown'
end

-- Build a transient record for index i.
--
-- list(), csv() and user filters all receive records of this shape; the
-- DURABLE store remains the six flat arrays. The allocation is deliberate:
-- one throwaway table per displayed row is cheap, and it keeps the filter
-- API pleasant.
--
-- Note ['end'] -- "end" is a Lua keyword, so the field is only reachable
-- through bracket syntax.
local function recAt(i)
local st, conf, mask, kv = fStart[i], fConf[i], fMask[i], fKind[i]
local ed=fEnd[i]-1


local sr, er = addressOffset(st), addressOffset(ed)

return {
start = st, ['end'] = ed, size = fEnd[i] - st,
srcs = tagsOf(mask), conf = conf, status = statusOf(kv, conf),
callers = fCallers[i], fromPdata = (kv == 1), nested = (kv == 2),
class = funcToClass[st], kind = kindOf(mask, fCallers[i], funcToClass[st]),
startRel=sr, endRel=er
}
end

-- RFC-4180 escaping. Quotes a field if it contains a quote, a comma, CR or
-- LF, doubling any embedded quotes.
local function csvEsc(s)
s = tostring(s or '')
if s:find('[",\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
return s
end

-- Write the whole result set: ONE ROW PER FUNCTION.
--
-- Addresses are hex; size, callers and confidence are DECIMAL. The class
-- column here is DEMANGLED, unlike the class field of a list() record,
-- which is mangled.
local function _csv(path)
local fh = io.open(path, 'w')
if fh == nil then print('cannot open ' .. tostring(path)); return end
fh:write('start,end,size,directCallSites,status,confidence,sources,kind,fromPdata,class\n')
for i = 1, #fStart do
local f = recAt(i)
local _, cn = demangle(f.class)      -- nil-safe: demangle(nil) -> nil, nil
fh:write(table.concat({
f.startRel, f.endRel,
tostring(f.size), tostring(f.callers), csvEsc(f.status), CONFNAME[f.conf+1],
csvEsc(table.concat(f.srcs, '|')), csvEsc(f.kind),
tostring(f.fromPdata), csvEsc(cn or ''),
}, ',') .. '\n')
end
fh:close(); print('wrote ' .. path .. ' (' .. #fStart .. ' rows)')
end

-- Sorted key list. vtblMap is keyed by slot address, so iteration order
-- would otherwise be arbitrary; rtti() and rtticsv() promise ascending.
local function sortedKeys(t)
local ks = {}
for k in pairs(t) do ks[#ks+1] = k end
table.sort(ks)
return ks
end

-- Write the class map: ONE ROW PER VFTABLE, not per class.
--
-- A class with virtual bases, or one reached through adjustor thunks, owns
-- several COLs, so the same class name legitimately repeats across rows.
-- Deduplicate on "class" only when you want the SET of types.
--
-- Columns: vftable, col, kind, class, bases. Both addresses are hex; kind
-- here is the RTTI type kind (class/struct/enum/union), which is NOT the
-- same thing as the "kind" column of csv().
local function _rtticsv(path)
local fh = io.open(path, 'w')
if fh == nil then print('cannot open ' .. tostring(path)); return end
fh:write('vftable,col,kind,class,bases\n')
local ks = sortedKeys(vtblMap)


for n = 1, #ks do
local v = vtblMap[ks[n]]
local label, name = demangle(v.className)
local h = hierarch[v.className]
local names = {}
if h then
for bi = 1, #h.bases do
local _, bn = demangle(h.bases[bi])
names[#names+1] = bn or h.bases[bi]
end
end

local ad, cad = addressOffset(ks[n]), addressOffset(v.colAddr)

fh:write(table.concat({
ad, cad,
csvEsc(label or '?'), csvEsc(name or v.className), csvEsc(table.concat(names, '|')),
}, ',') .. '\n')
end
fh:close(); print('wrote ' .. path .. ' (' .. #ks .. ' rows)')
end


-- Dump the PE section table. Re-parses the header, so it does NOT require a
-- completed probe().
--
-- Reach for this first when a scan looks wrong: it tells you whether the
-- section table lies, and therefore whether the OS-page-protection fallback
-- is about to kick in.
local function _sections(module)
module = module or process
local base = normAddr(getAddress(module))
if base == nil then print('PE parse failed'); return end
local pe = peInfo(base)
if pe == nil then print('PE parse failed'); return end
for i = 1, #pe.secs do
local s = pe.secs[i]
local c = s.chr or 0
print(string.format('%-9s %X-%X vsz=%X chr=%08X %s%s%s',
(s.name == nil or s.name == '') and '(unnamed)' or s.name,
s.va, s.va + secSize(s) - 1,
s.vsz or 0, c,
hasBit(c, SCN.CODE) and 'CODE ' or '',
hasBit(c, SCN.MEM_EXEC) and 'EXEC ' or '',
hasBit(c, SCN.MEM_WRITE) and 'WRITE' or ''))
end
end

--------------------------------------------------------------------
-- JSON helper
--------------------------------------------------------------------

-- Encode a Lua string as a JSON string.
--
-- Important: '<' and '>' are escaped as \u003c and \u003e. This prevents a
-- class name containing something like "</script>" from breaking the HTML
-- page when the JSON is embedded inside a <script type="application/json">
-- element.
local function jsonStr(s)
    s = tostring(s or '')
    local out = {}
    for i = 1, #s do
        local c = s:byte(i)
        if c == 34 then
            out[#out + 1] = '\\"'
        elseif c == 92 then
            out[#out + 1] = '\\\\'
        elseif c == 8 then
            out[#out + 1] = '\\b'
        elseif c == 9 then
            out[#out + 1] = '\\t'
        elseif c == 10 then
            out[#out + 1] = '\\n'
        elseif c == 12 then
            out[#out + 1] = '\\f'
        elseif c == 13 then
            out[#out + 1] = '\\r'
        elseif c == 60 then
            out[#out + 1] = '\\u003c'
        elseif c == 62 then
            out[#out + 1] = '\\u003e'
        elseif c < 32 or c == 127 then
            out[#out + 1] = string.format('\\u%04x', c)
        else
            out[#out + 1] = char(c)
        end
    end
    return '"' .. table.concat(out) .. '"'
end

--------------------------------------------------------------------
-- ghidraLike.html(path)
--
-- Writes a self-contained HTML file showing RTTI class hierarchies.
--
-- Design decisions:
--   * HTML is used because <details>/<summary> gives native collapsible
--     panes without external JavaScript frameworks.
--   * Data is embedded as JSON so the file works offline from file://.
--   * Unknown base classes become placeholder nodes. They can be hidden
--     in the UI without losing the derived classes attached to them.
--   * Multiple inheritance is a graph, not necessarily a tree. The default
--     view is "top-level panes with flat descendant lists" because that
--     avoids exponential duplication in diamond hierarchies. A nested tree
--     mode is also provided.
--------------------------------------------------------------------

-- ghidraLike.html(path)
-- Writes a self-contained HTML file showing RTTI class hierarchies.
--
-- Design decisions:
--   * HTML is used because <details>/<summary> gives native collapsible
--     panes without external JavaScript frameworks.
--   * Data is embedded as JSON so the file works offline from file://.
--   * Unknown base classes become placeholder nodes. They can be hidden
--     in the UI without losing the derived classes attached to them.
--   * Multiple inheritance is a graph, not necessarily a tree. The default
--     view is "top-level panes with flat descendant lists" because that
--     avoids exponential duplication in diamond hierarchies. A nested tree
--     mode is also provided.
--   * FILTER SEMANTICS: the search box selects PANES, not rows. A
--     details.rootPane is shown if ANY row it would display contains the
--     substring; once shown, the pane displays all of its rows. Matching
--     rows are highlighted so the trigger is visible.
--   * The searchable text is exactly the three rendered places:
--       span.classLabel > strong              -> c.name
--       span.classLabel > code[title=...]     -> c.mangled
--       pre.bases                             -> base names, joined as shown
--     The "Directly inherits from:" chrome label is NOT searchable, and
--     neither is c.kind (see the re-add note on rowHaystack).
--   * render() reads visiblePanes(), so the export
--     cannot drift from the page by construction rather than by discipline.
local function _html(path)
    local fh = io.open(path, 'w')
    if fh == nil then
        print('cannot open ' .. tostring(path))
        return
    end

    -- Gather class names from every RTTI structure that still survives after
    -- probe(). hierarch alone can miss root classes with no bases, so also
    -- use vtblMap and funcToClass.
    local names = {}
    local function addName(n)
        if type(n) == 'string' and n ~= '' and names[n] == nil then
            names[n] = true
        end
    end

    for m in pairs(hierarch) do
        addName(m)
        local h = hierarch[m]
        if h and h.bases then
            for i = 1, #h.bases do
                addName(h.bases[i])
            end
        end
    end

    for _, v in pairs(vtblMap) do
        addName(v.className)
    end

    for _, m in pairs(funcToClass) do
        addName(m)
    end
	
	--------------------------------------------------------------------
	-- Collect addresses for each RTTI type.
	--
	-- Reliable sources after probe():
	--   vtblMap      -> vftable address and COL address
	--   funcToClass  -> virtual method/function addresses
	--   typeRecords  -> TD/CHD addresses, if the retention patch was applied
	--------------------------------------------------------------------
	-- Group vftables by class, then take the PRIMARY one as the lowest address.
-- Secondary vftables are laid out immediately after the primary, so the
-- minimum is the primary vftable, and its COL is the class's own locator
-- rather than a subobject's.

local byName = {}
for vslot, v in pairs(vtblMap) do
    local l = byName[v.className]
    if l == nil then l = {}; byName[v.className] = l end
    l[#l + 1] = { vft = vslot, col = v.colAddr }
end

local classAddrs = {}
for m, l in pairs(byName) do
    table.sort(l, function(a, b) return a.vft < b.vft end)

    local r = { col = addressOffset(l[1].col), vftables = {}, methods = {} }
    for i = 1, #l do r.vftables[i] = l[i].vft end
    classAddrs[m] = r
end

for fa, m in pairs(funcToClass) do
    local r = classAddrs[m]
    if r == nil then
        r = { vftables = {}, methods = {} }
        classAddrs[m] = r
    end
    r.methods[#r.methods + 1] = fa
end
	
    local classes = {}
    for m, v in pairs(names) do
		local mdr=classAddrs[m]
		local kind, name = demangle(m)
		if mdr==nil then mdr=classAddrs[name] end
			if mdr~=nil then
				 for k1, v1 in pairs(mdr.vftables) do
					mdr.vftables[k1]=addressOffset(v1)
				 end
				 for k1, v1 in pairs(mdr.methods) do
					mdr.methods[k1]=addressOffset(v1)
				 end
			end
		
        
        local h = hierarch[m]
        local bases = {}
        if h and h.bases then
            for i = 1, #h.bases do
                bases[#bases + 1] = h.bases[i]
            end
        end
		
		if mdr~=nil then
        classes[#classes + 1] = {
            mangled = m,
            name = name or m,
            kind = kind or 'type',
            bases = bases,
            attrs = h and h.attrs or nil,
			addrs_col=mdr.col,
			addrs_vftables=mdr.vftables,
			addrs_methods=mdr.methods  
        }
		else
	        classes[#classes + 1] = {
            mangled = m,
            name = name or m,
            kind = kind or 'type',
            bases = bases,
            attrs = h and h.attrs or nil
        }
		end
    end

    table.sort(classes, function(a, b)
        return a.mangled < b.mangled
    end)
	

    -- Build JSON manually. This avoids requiring a Lua JSON library.
    local parts = {}
    parts[#parts + 1] = '{"generated":'
    parts[#parts + 1] = jsonStr(os.date('!%Y-%m-%dT%H:%M:%SZ') or '')
    parts[#parts + 1] = ',"module":'
    parts[#parts + 1] = jsonStr(moduleName or '')
    parts[#parts + 1] = ',"classes":['

    for i, c in ipairs(classes) do
        if i > 1 then parts[#parts + 1] = ',' end
        parts[#parts + 1] = '{"mangled":'
        parts[#parts + 1] = jsonStr(c.mangled)
        parts[#parts + 1] = ',"name":'
        parts[#parts + 1] = jsonStr(c.name)
        parts[#parts + 1] = ',"kind":'
        parts[#parts + 1] = jsonStr(c.kind)
		
        parts[#parts + 1] = ',"bases":['
        for j, b in ipairs(c.bases) do
            if j > 1 then parts[#parts + 1] = ',' end
            parts[#parts + 1] = jsonStr(b)
        end
        parts[#parts + 1] = ']'
		
		if c.addrs_vftables ~= nil then
			parts[#parts + 1] = ',"vftables":['
			for j, b in ipairs(c.addrs_vftables) do
				if j > 1 then parts[#parts + 1] = ',' end
				parts[#parts + 1] = jsonStr(b)
			end
			parts[#parts + 1] = ']'
		end
		
		
		if c.addrs_methods ~= nil then
			parts[#parts + 1] = ',"methods":['
			for j, b in ipairs(c.addrs_methods) do
				if j > 1 then parts[#parts + 1] = ',' end
				parts[#parts + 1] = jsonStr(b)
			end
			parts[#parts + 1] = ']'
		end
		
		if c.addrs_col ~= nil then
			parts[#parts + 1] = ',"col":'
			parts[#parts + 1] = jsonStr(c.addrs_col)
		end

        if c.attrs ~= nil then
            parts[#parts + 1] = ',"attrs":'
            parts[#parts + 1] = tostring(c.attrs)
        end
        parts[#parts + 1] = '}'
    end

    parts[#parts + 1] = ']}'
    local json = table.concat(parts)

    ----------------------------------------------------------------
    -- HTML part 1: head, styles, toolbar, opening JSON script tag.
    --
    -- NOTE: every attribute value below must have NO space between the
    -- quotes and the value. id="tree " makes getElementById('tree') return
    -- null and the whole page dies silently.
    ----------------------------------------------------------------
    fh:write([==[
<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>RTTI class hierarchies</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #ffffff;
  --fg: #111111;
  --muted: #666666;
  --line: #dddddd;
  --pane: #f7f7f7;
  --accent: #0b5fbf;
}

@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111111;
    --fg: #eeeeee;
    --muted: #aaaaaa;
    --line: #333333;
    --pane: #1b1b1b;
    --accent: #7cc4ff;
  }
}

body {
  margin: 0;
  font: 14px/1.45 system-ui, -apple-system, "Segoe UI", Roboto, Arial, sans-serif;
  background: var(--bg);
  color: var(--fg);
}

header {
  position: sticky;
  top: 0;
  z-index: 2;
  background: var(--bg);
  border-bottom: 1px solid var(--line);
  padding: 10px 14px;
}

h1 {
  font-size: 18px;
  margin: 0 0 8px 0;
}

.toolbar {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  align-items: center;
}

.toolbar input[type="search"] {
  min-width: 260px;
  padding: 6px 8px;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: var(--pane);
  color: var(--fg);
}

.toolbar label,
.toolbar button {
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 6px 8px;
  background: var(--pane);
  color: var(--fg);
  cursor: pointer;
  user-select: none;
}

.toolbar button:hover {
  border-color: var(--accent);
}

#stats {
  color: var(--muted);
  margin-left: auto;
  white-space: nowrap;
}

main {
  padding: 12px 14px 40px 14px;
}

details.rootPane {
  border: 1px solid var(--line);
  border-radius: 8px;
  margin: 8px 0;
  background: var(--pane);
  overflow: hidden;
}

details.rootPane > summary {
  cursor: pointer;
  padding: 9px 10px;
  font-weight: 600;
  list-style: none;
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
}

details.rootPane > summary::-webkit-details-marker {
  display: none;
}

details.rootPane[open] > summary {
  border-bottom: 1px solid var(--line);
}

.classLabel {
  display: inline-flex;
  gap: 6px;
  align-items: baseline;
  flex-wrap: wrap;
}

.classLabel .kind {
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--accent);
  border: 1px solid currentColor;
  border-radius: 999px;
  padding: 1px 6px;
}

.classLabel code {
  font-weight: 400;
  color: var(--muted);
  font-size: 12px;
}

.count {
  color: var(--muted);
  font-weight: 400;
  font-size: 12px;
}

pre.bases {
    text-wrap-mode: wrap;
}

ul.descList {
  margin: 0;
  padding: 8px 10px 10px 10px;
  list-style: none;
}

ul.descList li {
  padding: 3px 0 3px calc(var(--depth) * 18px);
  border-left: 1px dashed var(--line);
  margin-left: 4px;
}

ul.descList li .bases {
  color: var(--muted);
  font-size: 12px;
  margin-left: 6px;
}

/* The optional match highlight. Remove this rule and the one
   classList.add('match') call in render() if you do not want it. */
ul.descList li.match {
  background: rgba(11, 95, 191, .12);
}

.nested {
  padding: 8px 10px 10px 22px;
}

.nested details {
  margin: 4px 0;
  border-left: 1px dashed var(--line);
  padding-left: 8px;
}

.nested summary {
  cursor: pointer;
}

.cycle,
.empty {
  color: var(--muted);
  font-style: italic;
  padding: 4px 0;
}
</style>
</head>
<body>
<header>
  <h1>RTTI class hierarchies</h1>
  <div class="toolbar">
    <input id="search" type="search" placeholder="Filter classes…">
    <label><input id="showUnknown" type="checkbox" checked> Show unknown bases</label>
    <label><input id="flatMode" type="checkbox" checked> Top-level panes with flat descendants</label>
    <button id="expandAll">Expand all</button>
    <button id="collapseAll">Collapse all</button>
    <span id="stats"></span>
  </div>
</header>
<main id="tree"></main>
<script id="class-data" type="application/json">]==])

    ----------------------------------------------------------------
    -- Embedded JSON data.
    ----------------------------------------------------------------
    fh:write(json)

    ----------------------------------------------------------------
    -- HTML part 2: renderer JavaScript.
    ----------------------------------------------------------------
    fh:write([==[
</script>
<script>
(() => {
const data = JSON.parse(document.getElementById('class-data').textContent || '{}');
const map = new Map();


for (const c of data.classes || []) {
	let diplayAddrs='';
	if (typeof(c.vftables)!=='undefined' && c.vftables.length>0){
		
		diplayAddrs+=c.vftables.length===1?
		`vfTables: "${c.vftables[0]}", `
		:`vfTables: ["${c.vftables.join('", "')}"], `;
	}

	if (typeof(c.col)!=='undefined' && c.col!==''){
		diplayAddrs+=`COL: "${c.col}", `;
	}

	if (typeof(c.methods)!=='undefined' && c.methods.length>0){
		diplayAddrs+=c.vftables.length===1?
		`Methods: "${c.methods[0]}", `
		:`Methods: ["${c.methods.join('", "')}"], `;
	}
	if(diplayAddrs.endsWith(', ')){
		diplayAddrs=diplayAddrs.slice(0,-2);
	}
  map.set(c.mangled, {
    mangled: c.mangled,
    name: c.name || c.mangled,
    kind: c.kind || 'type',
    bases: Array.isArray(c.bases) ? c.bases.slice() : [],
    attrs: c.attrs,
    unknown: false,
	vftables: c.vftables || [],
	methods: c.methods || [],
	col: c.col || '',
	displayAddresses: diplayAddrs
  });
}

function ensure(m) {
  if (!map.has(m)) {
    map.set(m, {
      mangled: m,
      name: m,
      kind: 'unknown',
      bases: [],
      unknown: true
    });
  }
  return map.get(m);
}

// Make sure every base mentioned by a class exists as a node.
for (const c of Array.from(map.values())) {
  const seen = new Set();
  const bs = [];
  for (const b of c.bases) {
    const node = ensure(b);
    if (!seen.has(node.mangled)) {
      seen.add(node.mangled);
      bs.push(node.mangled);
    }
  }
  c.bases = bs;
}

// children[base] = list of direct derived classes.
const children = new Map();
for (const c of map.values()) {
  for (const b of c.bases) {
    if (!children.has(b)) children.set(b, []);
    children.get(b).push(c.mangled);
  }
}

function cmpNode(a, b) {
  const an = String((a && a.name) || (a && a.mangled) || '').toLowerCase();
  const bn = String((b && b.name) || (b && b.mangled) || '').toLowerCase();
  if (an < bn) return -1;
  if (an > bn) return 1;
  return String((a && a.mangled) || '').localeCompare(String((b && b.mangled) || ''));
}

for (const arr of children.values()) {
  arr.sort((x, y) => cmpNode(map.get(x), map.get(y)));
}

// Make sure every base mentioned by a class exists as a node.
for (const c of Array.from(map.values())) {
  const seen = new Set();
  const bs = [];
  for (const b of c.bases) {
    if (b === c.mangled) continue;          // a class is never its own base
    const node = ensure(b);
    if (!seen.has(node.mangled)) {
      seen.add(node.mangled);
      bs.push(node.mangled);
    }
  }
  c.bases = bs;
}

// Top-level nodes are nodes with no known bases. Unknown placeholder bases
// also appear here unless hidden by the checkbox.
const roots = Array.from(map.values())
  .filter(c => c.bases.length === 0)
  .sort(cmpNode);

const $ = id => document.getElementById(id);
const tree = $('tree');
const stats = $('stats');

function nodeName(m) {
  const c = map.get(m);
  return c ? c.name : m;
}

// ----------------------------------------------------------------
// FILTER HAYSTACK
//
// Exactly the three rendered places your spec names:
//   span.classLabel > strong            -> c.name
//   span.classLabel > code[title=...]   -> c.mangled
//   pre.bases                           -> base names, joined as rendered
//
// Fields are joined with \n, NOT a space, so a term cannot match across two
// of them. The search box is single-line, so a term can never contain \n.
//
// c.kind is DELIBERATELY EXCLUDED because the spec did not list it. This is a
// behaviour change: "struct" / "class" / "enum" used to filter by RTTI kind.
// To restore that, change the hay line to:
//   String(c.name||'') + '\n' + String(c.mangled||'') + '\n'
//     + String(c.kind||'') + '\n' + bases
//
// Memoised: map is never mutated after load, so the cache cannot go stale.
// This matters because the old code rebuilt the string per root per keystroke.
// ----------------------------------------------------------------
const hayCache = new Map();

function rowHaystack(c) {
  if (!c) return '';
  const cached = hayCache.get(c.mangled);
  if (cached !== undefined) return cached;

  // Joined identically to the pre.bases rendering, so the haystack is the
  // concatenation of the actual visible text.
  const bases = (c.bases || []).map(nodeName).filter(Boolean).join(',\n');
  const hay = (String(c.name || '') + '\n' + String(c.mangled || '') + '\n' + bases)
    .toLowerCase();

  hayCache.set(c.mangled, hay);
  return hay;
}

function rowMatches(c, term) {
  if (!term) return true;
  return rowHaystack(c).indexOf(term) !== -1;
}

// Transitive descendants of one root, unique per root, breadth-first so
// shallower classes appear before deeper ones.
function descendants(rootM) {
  const out = [];
  const seen = new Set([rootM]);
  const q = [];

  for (const m of children.get(rootM) || []) {
    if (!seen.has(m)) q.push({ m: m, depth: 1 });
  }

  for (let i = 0; i < q.length; i++) {
    const item = q[i];
    if (seen.has(item.m)) continue;
    seen.add(item.m);
    out.push(item);

    for (const kid of children.get(item.m) || []) {
      if (!seen.has(kid)) {
        q.push({ m: kid, depth: item.depth + 1 });
      }
    }
  }

  out.sort((a, b) => {
    if (a.depth !== b.depth) return a.depth - b.depth;
    return cmpNode(map.get(a.m), map.get(b.m));
  });

  return out;
}

// ----------------------------------------------------------------
// THE SINGLE SOURCE OF TRUTH
//
// paneCache: root mangled name -> the rows that pane WOULD show, honouring
// the Show-unknown-bases checkbox. Rebuilt only when that checkbox changes.
//
// visiblePanes(): those panes, further filtered by the CURRENT search term.
// A pane is visible iff ANY row it would show contains the term. Both
// render() calls this, so the export cannot disagree with the
// page about which panes or which rows are presented.
// ----------------------------------------------------------------
let paneCache = null;
let paneCacheKey = null;

function buildPaneCache(showUnknown) {
  const m = new Map();
  for (const root of roots) {
    if (!showUnknown && root.unknown) continue;

    const rows = [{ c: root, depth: 0 }];

    for (const d of descendants(root.mangled)) {
      const c = map.get(d.m);
      if (!c) continue;
      if (!showUnknown && c.unknown) continue;
      rows.push({ c: c, depth: d.depth });
    }

    m.set(root.mangled, rows);
  }
  return m;
}

function visiblePanes() {
  const showUnknown = $('showUnknown').checked;
  const term = $('search').value.trim().toLowerCase();

  if (paneCacheKey !== showUnknown) {
    paneCache = buildPaneCache(showUnknown);
    paneCacheKey = showUnknown;
  }

  const out = [];
  for (const root of roots) {
    const rows = paneCache.get(root.mangled);
    if (rows === undefined) continue;

    if (term) {
      let hit = false;
      for (const r of rows) {
        if (rowMatches(r.c, term)) { hit = true; break; }
      }
      if (!hit) continue;
    }

    out.push({ root: root, rows: rows });
  }
  return out;
}

function classLabel(c) {
  const span = document.createElement('span');
  span.className = 'classLabel';

  const kind = document.createElement('span');
  kind.className = 'kind';
  kind.textContent = c.kind || 'type';

  const name = document.createElement('strong');
  name.textContent = c.name || c.mangled;

  const code = document.createElement('code');
  code.textContent = c.mangled+(c.displayAddresses===''?'':` (${c.displayAddresses})`);
  code.title = 'Mangled name';
	
  span.appendChild(kind);
  span.appendChild(name);
  name.insertAdjacentHTML('afterend', '<br>');
  span.appendChild(code);
  return span;
}

// Nested mode renders the FULL subtree of a visible pane. The search term is
// deliberately NOT applied per child here: the spec selects panes, and
// filtering children individually is what produced the old asymmetry (a
// matching root revealed everything, a matching child revealed only itself).
// The Show-unknown-bases checkbox still applies.
function renderNested(m, path) {
  const frag = document.createDocumentFragment();
  const kids = (children.get(m) || []).slice();
  const showUnknown = $('showUnknown').checked;

  for (const kid of kids) {
    const c = map.get(kid);
    if (!c) continue;
    if (!showUnknown && c.unknown) continue;

    if (path.has(kid)) {
      const div = document.createElement('div');
      div.className = 'cycle';
      div.textContent = 'cycle: ' + c.name;
      frag.appendChild(div);
      continue;
    }

    const det = document.createElement('details');
    const sum = document.createElement('summary');
    sum.appendChild(classLabel(c));
    det.appendChild(sum);

    const p2 = new Set(path);
    p2.add(kid);
    det.appendChild(renderNested(kid, p2));

    frag.appendChild(det);
  }

  return frag;
}

function render() {
  const flat = $('flatMode').checked;
  const showUnknown = $('showUnknown').checked;
  const term = $('search').value.trim().toLowerCase();
  const panes = visiblePanes();

  tree.textContent = '';

  for (const pane of panes) {
    const root = pane.root;
    const rows = pane.rows;

    const det = document.createElement('details');
    det.className = 'rootPane';

    const sum = document.createElement('summary');
    sum.appendChild(classLabel(root));

    const cnt = document.createElement('span');
    cnt.className = 'count';
    if (flat) {
      const n = rows.length - 1;
      cnt.textContent = n + ' descendant' + (n === 1 ? '' : 's');
    } else {
      const direct = (children.get(root.mangled) || [])
        .filter(m => { const c = map.get(m); return c && (showUnknown || !c.unknown); })
        .length;
      cnt.textContent = direct + ' direct child' + (direct === 1 ? '' : 'ren');
    }
    sum.appendChild(cnt);
    det.appendChild(sum);

    if (flat) {
      const ul = document.createElement('ul');
      ul.className = 'descList';

      if (rows.length === 1) {
        const li = document.createElement('li');
        li.className = 'empty';
        li.textContent = 'No descendants.';
        ul.appendChild(li);
      } else {
        for (let i = 1; i < rows.length; i++) {
          const r = rows[i];
          const li = document.createElement('li');
          li.style.setProperty('--depth', String(r.depth));
          li.appendChild(classLabel(r.c));
			
          const baseNames = (r.c.bases || []).map(nodeName).filter(Boolean).map(p=> (r.c.displayAddresses==='')?p:p+': ('+r.c.displayAddresses+')').join('\n');
          if (baseNames) {
            const bs = document.createElement('pre');
            bs.className = 'bases';
            bs.textContent = baseNames;
            li.appendChild(bs);
            bs.insertAdjacentHTML('beforebegin',
              '<br><span class="bases">Directly inherits from:</span><br>');
          }

          // Optional: shows WHICH row pulled the pane in. Pane-level
          // visibility means a whole pane can appear from one deep match.
          if (term && rowMatches(r.c, term)) li.classList.add('match');

          ul.appendChild(li);
        }
      }

      det.appendChild(ul);
    } else {
      const holder = document.createElement('div');
      holder.className = 'nested';

      const frag = renderNested(root.mangled, new Set([root.mangled]));
      if (!frag.hasChildNodes()) {
        const e = document.createElement('div');
        e.className = 'empty';
        e.textContent = 'No descendants.';
        holder.appendChild(e);
      }

      holder.appendChild(frag);
      det.appendChild(holder);
    }

    tree.appendChild(det);
  }

  // Counted from the DOM so the figure is truthful in BOTH modes, including
  // nested mode where a diamond class is legitimately rendered more than once.
  stats.textContent = panes.length + ' top-level pane(s), ' +
    tree.querySelectorAll('.classLabel').length + ' rendered class(es)';
}

// No change needed here: visiblePanes() invalidates the pane cache itself
// when the checkbox flips, and re-reads the search term on every call.
$('search').addEventListener('input', render);
$('showUnknown').addEventListener('change', render);
$('flatMode').addEventListener('change', render);

$('expandAll').addEventListener('click', () => {
  document.querySelectorAll('details').forEach(d => { d.open = true; });
});

$('collapseAll').addEventListener('click', () => {
  document.querySelectorAll('details').forEach(d => { d.open = false; });
});

render();
})();
</script>
</body>
</html>
]==])

    fh:close()
    print('wrote ' .. tostring(path) .. ' (' .. #classes .. ' class(es))')
end

-----------------------------------------------------------------------
-- PUBLIC API
--
-- probe() is the only member that
-- mutates the result set; every other reader needs a COMPLETED probe(),
-- except sections(), which parses headers independently.
-----------------------------------------------------------------------
ghidraLike = {
probe = _probe,
csv = _csv,
rtticsv = _rtticsv,
sections = _sections,
html = _html,
endWindow = _endWindow
}