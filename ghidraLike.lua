-- CONSTANTS AND LEXICAL SHORTHANDS
local floor = math.floor
local find, byte, char, len = string.find, string.byte, string.char, string.len
-- Lua 5.1 keeps unpack in the global table; 5.2+ moved it into "table".
local unpack = table.unpack or unpack
-- Lua 5.1's string loader is loadstring; 5.2+ unified it into load.
local loadstr = loadstring or load

local PADDING = { [0xCC]=true, [0x90]=true }

-- Multi-byte NOP "cores", longest first. The set is prefix-free, so the first
-- match wins unambiguously. Leading 0x66 prefixes are stripped in padItemLen.
local NOPCORE = {
  {0x2E,0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00},   -- cs nopw [rax+rax*1+0]
  {0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00},        -- 8 bytes
  {0x0F,0x1F,0x80,0x00,0x00,0x00,0x00},             -- 7 bytes
  {0x0F,0x1F,0x44,0x00,0x00},                       -- 5 bytes
  {0x0F,0x1F,0x40,0x00},                            -- 4 bytes
  {0x0F,0x1F,0x00}                                 -- 3 bytes
}

local CHUNK         = 262144
-- Look-ahead carried past a window so a structure straddling the boundary can
-- still be read whole. The largest read-ahead structure is the 24-byte COL.
local OVERLAP       = 32
local RTTI_NAME_MAX = 2048
local VTABLE_SLOTS  = 4096

local SRC = {
  PDATA='pdata', CALL='call', PAD='pad', ENTRY='entry', EXP='export',
  TLS='tls', CRT='crt', PTR='ptr', VTBL='vtable', XDATA='xdata',
  RVA='rva', CFG='cfg', DYN='dynamic', JUMP='jump', FRAG='fragment'
}

-- Canonical order: display order AND bit position. Nothing persists the mask,
-- so changing this order is harmless.
local TAGORDER = { 'pdata','cfg','export','tls','crt','entry','vtable','dynamic',
                   'call','rva','pad','ptr','xdata','fragment','jump' }

local CONF = {
  [SRC.PDATA]=4, [SRC.CFG]=4, [SRC.EXP]=4, [SRC.TLS]=4, [SRC.CRT]=4, [SRC.ENTRY]=4,
  [SRC.VTBL]=3, [SRC.DYN]=3,
  [SRC.CALL]=2,
  [SRC.RVA]=1, [SRC.PAD]=1, [SRC.PTR]=1, [SRC.XDATA]=1, [SRC.FRAG]=1,
  [SRC.JUMP]=0
}

-- Indexed as CONFNAME[tier + 1]: Lua arrays are 1-based, the lowest tier is 0.
local CONFNAME = { 'SPECULATIVE','WEAK','STRONG','HIGH','AUTHORITATIVE' }

local CONFSHIFT = 1048576          -- 2^20, above the 2^15 ceiling of the mask

local TAGBIT = {}
do
  local bit = 1
  for i = 1, #TAGORDER do TAGBIT[TAGORDER[i]] = bit; bit = bit * 2 end
end

local SCN = {
  CODE=0x00000020, INITDATA=0x00000040, UNINITDATA=0x00000080,
  MEM_READ=0x40000000, MEM_EXEC=0x20000000, MEM_WRITE=0x80000000
}

-- TLS is 9, not 4. Index 4 is the certificate directory; confusing the two is
-- the classic PE-parsing slip.
local DD = { EXPORT=0, IMPORT=1, RESOURCE=2, EXCEPTION=3, CERT=4,
             RELOC=5, DEBUG=6, TLS=9, LOADCFG=10 }

local MEM_COMMIT = 0x1000
-- Guard variants (0x100, 0x200, ...) are stripped by Protect % 256.
local PAGE_EXEC  = { [0x10]=true, [0x20]=true, [0x40]=true, [0x80]=true }

local moduleName = ''
local moduleBase = 0

local function addressOffset(a)
  return getNameFromAddress(a, true, false, true)
end

-- Bit test written as divide-mod for portability. Non-numbers are "not set".
local function hasBit(v, m)
  if type(v) ~= 'number' then return false end
  return floor(v / m) % 2 == 1
end

local function hasAll(v, ms)
  for i = 1, #ms do if not hasBit(v, ms[i]) then return false end end
  return true
end

-- # is meaningless for hash tables, and most tables here are keyed by address.
local function cnt(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

-- Gatekeeper for address keys. Rejects non-numbers, fractions, NaN and infinity.
local function normAddr(a)
  if type(a) ~= 'number' then return nil end
  if a ~= a then return nil end                       -- NaN
  if a == math.huge or a == -math.huge then return nil end
  local f = floor(a)
  if f ~= a then return nil end
  return f
end


------------------------------------------------------------------ progress window
-- [1] = the form, [2] = the label. Only these two indices are ever used.
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

-- No memo caches remain; this just asks the collector for the chunk tables back.
local function gl_freeCaches()
  collectgarbage('collect')
end

local function gl_labelExtent(l)
  local w = tonumber(l.Width) or 0
  local h = tonumber(l.Height) or 0
  if w > 1 and h > 1 then return w, h end
  local caption = ''
  pcall(function() caption = tostring(l.Caption or '') end)
  local n = #caption
  -- Rough fallback: about 8 pixels per character at the font size used here.
  if w <= 1 then w = math.max(520, n * 8) end
  if h <= 1 then h = 20 end
  return w, h
end

local function gl_fit()
  if gl_w[1] == nil or gl_w[2] == nil then return end
  local f, l = gl_w[1], gl_w[2]
  -- WordWrap must be false, or the label width depends on the form width and
  -- the sizing becomes circular.
  pcall(function() l.AutoSize = true end)
  pcall(function() l.WordWrap = false end)
  local lw, lh = gl_labelExtent(l)
  local padX, padY = 16, 16
  local wantW = (tonumber(l.Left) or 0) + lw + padX
  local wantH = (tonumber(l.Top) or 0) + lh + padY
  -- Round up to 8-pixel steps so the window does not twitch by one pixel.
  wantW = math.ceil(wantW / 8) * 8
  wantH = math.ceil(wantH / 8) * 8
  if wantW ~= gl_lastW then
    if not pcall(function() f.ClientWidth = wantW end) then
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
    if pcall(function() return gl_w[1].Caption end) then
      gl_w[1].Caption = title
      gl_w[1].Show()
      gl_w[2].Caption = '…'
      gl_lastW, gl_lastH = 0, 0
      pcall(function() gl_w[1].Update() end)
      gl_fit()
      pcall(function() gl_w[1].Position = 'poDesigned' end)
      return
    end
    pcall(function() gl_w[1].destroy() end)
    gl_w[1], gl_w[2] = nil, nil
  end
  local f = createForm(getMainForm())
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
  pcall(function() f.Position = 'poDesigned' end)
end

local function gl_phase(p)
  if gl_w[2] == nil then return end
  gl_w[2].Caption = p
  gl_fit()
end

local function gl_progress(done, total, unit)
  if gl_w[2] == nil then return end
  unit = unit or 'items'
  if total == nil or total <= 0 then
    gl_w[2].Caption = spaceSep_int(done) .. ' ' .. unit
  else
    if done > total then done = total end
    gl_w[2].Caption = string.format('%s / %s %s (%d%%)',
      spaceSep_int(done), spaceSep_int(total), unit, floor(done / total * 100))
  end
  gl_fit()
end

local function gl_close()
  local f = gl_w[1]
  gl_w[1], gl_w[2] = nil, nil
  gl_lastW, gl_lastH = 0, 0
  if f ~= nil then pcall(function() f.destroy() end) end
end

local function gl_yield()
  coroutine.yield()
end


------------------------------------------------------------------ byte readers
-- v = 256*v + next_byte, most significant byte first. With n <= 8 and user-mode
-- addresses below 2^48 every intermediate stays exact.
-- readBytes can return a SHORT table at the edge of a mapping, so "#b < n" is a
-- real condition. Every reader returns nil rather than a partial value.
local V256 = 256

local function rd(n, a)
  local b = readBytes(a, n, true)
  if b == nil or #b < n then return nil end
  local v = 0
  for i = n, 1, -1 do
    local x = b[i]
    if x == nil then return nil end
    v = V256 * v + x
  end
  return v
end

local rd16 = function(a) return rd(2, a) end
local rd32 = function(a) return rd(4, a) end
local rd64 = function(a) return rd(8, a) end

-- Same assembly from a table already in hand. i is 1-based; psz is 4 or 8.
-- Bounds- and hole-checked, so a caller may pass a window with no look-ahead.
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

-- PE section names are space-PADDED, not NUL-terminated: 0x00 and 0x20 both end.
local function trimName(rb)
  local s = {}
  for j = 1, 8 do
    local c = rb[j]
    if c == nil or c == 0 or c == 0x20 then break end
    s[#s+1] = char(c)
  end
  return table.concat(s)
end


------------------------------------------------------------------ PE helpers
-- The 16 data directories sit at opt+0x60 (PE32) or opt+0x70 (PE32+), because
-- PE32+ widens ImageBase from 4 to 8 bytes. SizeOfImage lands at +56 in BOTH
-- formats, which is a coincidence rather than a rule.
local function peInfo(base)
  base = normAddr(base)
  if base == nil then return nil end

  local e_lfanew = rd32(base + 0x3C)
  if e_lfanew == nil or e_lfanew < 0x40 or e_lfanew > 0x100000 then return nil end
  local nt = base + e_lfanew
  if rd32(nt) ~= 0x00004550 then return nil end          -- "PE\0\0"

  local nSec, sizeOpt = rd16(nt + 6), rd16(nt + 20)
  if nSec == nil or sizeOpt == nil then return nil end
  if nSec > 96 then return nil end

  local opt = nt + 24
  local magic = rd16(opt)
  local is64 = (magic == 0x20B)
  if (not is64) and magic ~= 0x10B then return nil end
  if sizeOpt < (is64 and 0xF0 or 0xE0) then return nil end

  local entryRva = rd32(opt + 16)
  if entryRva == nil then return nil end

  local ddOff = opt + (is64 and 0x70 or 0x60)
  local out = {
    is64 = is64, base = base,
    entry = base + entryRva,
    size = rd32(opt + 56) or 0,
    imageBase = is64 and rd64(opt + 24) or rd32(opt + 28),
    secs = {}, dd = {}
  }

  for i = 0, 15 do
    out.dd[i] = { rva = rd32(ddOff + i * 8), size = rd32(ddOff + i * 8 + 4) }
  end

  local tbl = opt + sizeOpt
  for i = 0, nSec - 1 do
    local s = tbl + i * 40
    local rb = readBytes(s, 8, true)
    if rb then
      local va = rd32(s + 12)
      if va ~= nil then
        out.secs[#out.secs+1] = {
          name = trimName(rb), rva = va, va = base + va,
          vsz = rd32(s + 8), rawsz = rd32(s + 16),
          rawptr = rd32(s + 20), chr = rd32(s + 36)
        }
      end
    end
  end
  return out
end

local function ddAddr(pe, idx)
  local d = pe.dd[idx]
  if d == nil or d.rva == nil or d.rva == 0 or d.size == nil or d.size == 0 then
    return nil, nil
  end
  return pe.base + d.rva, d.size
end

-- VirtualSize == 0 means "use SizeOfRawData". A corrupt 0xFFFFFFFF would wrap a
-- Lua 5.3 integer into nonsense, so one section is capped at 512 MB.
local function secSize(s)
  local sz = 0
  if s.vsz and s.vsz > 0 then sz = s.vsz
  elseif s.rawsz and s.rawsz > 0 then sz = s.rawsz end
  if sz > 0x20000000 then sz = 0x20000000 end
  return sz
end

-- Executable ranges, in order of trustworthiness: characteristics, then OS page
-- protection, then nothing (which the caller turns into a hard error).
-- Never assumes the section is called ".text".
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

  local lim = modSize
  if type(lim) ~= 'number' or lim <= 0 then lim = pe.size end
  if type(lim) ~= 'number' or lim <= 0 then lim = 0x40000000 end

  local rt
  if pcall(function() rt = enumMemoryRegions() end) and type(rt) == 'table' then
    for _, v in pairs(rt) do
      if type(v) == 'table' and type(v.BaseAddress) == 'number'
         and type(v.RegionSize) == 'number' and type(v.State) == 'number'
         and type(v.Protect) == 'number'
         and v.State == MEM_COMMIT and PAGE_EXEC[v.Protect % 256]
         and v.BaseAddress >= base and v.BaseAddress < base + lim then
        out[#out+1] = { lo = v.BaseAddress,
                        hi = math.min(v.BaseAddress + v.RegionSize - 1, base + lim - 1),
                        name = '(unnamed)', how = 'OS page protection' }
      end
    end
  end
  return out, #out > 0 and 'OS' or 'NONE'
end

-- Every section whose name STARTS WITH one of pats, in PE order. MSVC emits
-- several .CRT$X* sections, so matching only the first hit would lose data.
-- plain = true, so the dots are literal.
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
          break
        end
      end
    end
  end
  return spans
end

local function spansToRanges(sp)
  local r = {}
  for i = 1, #sp do r[#r+1] = { sp[i].lo, sp[i].hi } end
  return r
end

-- Readable, initialised, NON-executable data: the hunting ground for pointers.
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


------------------------------------------------------------------ small helpers
-- Decreasing read sizes: a 256-byte read near the end of a mapping fails, but
-- 64 and then 16 still get the string. Any byte outside 0x20..0x7E ends it.
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

-- ".?AVFoo@@" -> "class", "Foo". Only a TRAILING "@@" is the terminator; inside
-- a template name "@@" legitimately closes a nested argument.
local function demangle(m)
  if m == nil then return nil, nil end
  local k, name = m:match('^%.%?A([VUWT])(.+)$')
  if k == nil then return nil, m end
  name = name:gsub('@@$', '')
  return ({ V='class', U='struct', W='enum', T='union' })[k] or '?', name
end


------------------------------------------------------------------ NAME REGISTRY
-- ONE registry, declared HERE, above every scanner, and NEVER redeclared.
-- Declaring it again further down would either make addName a nil global inside
-- scanCols (aborting the scan) or create a second set of tables that namecsv
-- cannot see. That was the previous revision's central defect.
--
-- Deliberately NO executable-range check: a TypeDescriptor or a COL lives in
-- .rdata, so propose() would reject it. First writer wins, so a real export
-- name beats a generic RTTI label.
local nmAddr, nmDesc, nmSeen = {}, {}, {}
local nmBase, nmModule = 0, ''

local function addName(a, desc)
  if type(a) ~= 'number' or desc == nil or desc == '' then return end
  local f = floor(a)
  if f ~= a or f <= 0 then return end
  if nmSeen[f] then return end
  nmSeen[f] = true
  nmAddr[#nmAddr+1] = f
  nmDesc[#nmDesc+1] = desc
end

-- .?AVActionSelector@ai@match@@    -> ActionSelector@ai@match   (RTTI type)
-- ?ActionSelector@ai@match@@QAEXXZ -> ActionSelector@ai@match   (export)
-- An RTTI type ends at its TRAILING '@@'; a function's qualified name ends at
-- the FIRST '@@'. Templates keep their interior '@@' for that reason.
local function symbolShort(s)
  if s == nil then return nil end
  if s:sub(1,3) == '.?A' then
    return (s:gsub('^%.%?A[VUWT]',''):gsub('@@$',''))
  end
  local t = s:gsub('^%?','')
  local cut = t:find('@@', 1, true)
  if cut then t = t:sub(1, cut-1) end
  return t
end


------------------------------------------------------------------ padding
-- Length of ONE padding item at b[i], or 0. Handles a bare int3/nop, any number
-- of leading 0x66 prefixes followed by 0x90, and the multi-byte NOP cores.
-- The np > 8 cap exists because an unbounded 0x66 sled is compression or malice,
-- not alignment padding.
local function padItemLen(b, i, limit)
  if i > limit then return 0 end
  local v = b[i]
  if v == nil then return 0 end
  if PADDING[v] then return 1 end
  local j = i
  while j <= limit and b[j] == 0x66 do j = j + 1 end
  local np = j - i
  if np > 8 or j > limit then return 0 end
  if np > 0 and b[j] == 0x90 then return np + 1 end
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

-- Byte table -> Lua string, so string.find hops between interesting bytes at C
-- speed. Lua-level work then scales with CANDIDATES, not with section size.
-- 4096 per call keeps the C-stack demand of string.char modest.
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


------------------------------------------------------------------ proposal store
-- roots[address] = confidence * CONFSHIFT + sourceMask
local roots, callers = {}, {}
local curSecs = {}
local EXLO, EXHI = 0, -1           -- empty bounding box until a probe sets it

local function inExec(a)
  for i = 1, #curSecs do
    local s = curSecs[i]
    if a >= s.lo and a <= s.hi then return true end
  end
  return false
end

local function propose(a, tag)
  if type(a) ~= 'number' then return false end
  local f = floor(a)
  if f ~= a then return false end
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
  -- Adding is safe precisely because we have just tested the bit is 0.
  if floor(mask / bit) % 2 == 0 then mask = mask + bit end
  if cf > conf then conf = cf end
  roots[a] = conf * CONFSHIFT + mask
  return true
end


------------------------------------------------------------------ chunk walker
-- fn(b, len, have, a) per CHUNK-sized window:
--   a = absolute window start, b = byte table (may exceed len thanks to OVERLAP)
--   len = whole slots in the window, have = #b including look-ahead
-- Windows start psz-aligned, aligned UP. An unreadable window is SKIPPED, not
-- fatal. gl_yield() per window is the cooperative multitasking seam.
local function eachChunk(ranges, psz, fn, label)
  local total = 0
  for r = 1, #ranges do total = total + (ranges[r][2] - ranges[r][1] + 1) end
  local done = 0
  gl_progress(0, total, label)
  for r = 1, #ranges do
    local lo, hi = ranges[r][1], ranges[r][2]
    local a = lo + ((psz - (lo % psz)) % psz)
    while a < hi do
      local avail = hi - a + 1
      local len = math.min(CHUNK, avail)
      len = len - (len % psz)
      if len <= 0 then break end
      local b = readBytes(a, math.min(len + OVERLAP, avail), true) or readBytes(a, len, true)
      if b ~= nil then fn(b, len, #b, a) end
      a = a + len; done = done + len
      gl_progress(done, total, label); gl_yield()
    end
  end
end


------------------------------------------------------------------ S1: .pdata
-- RUNTIME_FUNCTION is 12 bytes: BeginAddress, EndAddress, UnwindData.
-- EndAddress is the first byte AFTER the function, so extents here are EXACT.
-- Only non-leaf functions have an entry, so .pdata is exact but not complete.
-- Sortedness is CHECKED, not trusted, because a packer can rewrite the table.
local pdStart, pdEnd, pdChained = {}, {}, {}

local function srcPdata(pe, chainCheck)
  pdStart, pdEnd, pdChained = {}, {}, {}
  local addr, size = ddAddr(pe, DD.EXCEPTION)
  if addr == nil or not pe.is64 then return 0 end

  local n = floor(size / 12)
  if n > 5000000 then n = 5000000 end
  local per = floor(CHUNK / 12)
  local base, count, i = pe.base, 0, 0
  local sorted, lastLo = true, -1

  while i < n do
    local m = math.min(per, n - i)
    local b = readBytes(addr + i * 12, m * 12, true)
    if b == nil then break end
    m = math.min(m, floor(#b / 12))
    if m <= 0 then break end

    for r = 0, m - 1 do
      local o = r * 12
      local bg = b[o+1] + 256 * b[o+2] + 65536 * b[o+3] + 16777216 * b[o+4]
      local en = b[o+5] + 256 * b[o+6] + 65536 * b[o+7] + 16777216 * b[o+8]
      -- bg == 0 or en <= bg is the zero padding that terminates the table.
      if bg ~= 0 and en > bg then
        local lo = base + bg
        -- A cold fragment rather than an entry: UnwindData odd =>
        -- RUNTIME_FUNCTION_INDIRECT; or UNW_FLAG_CHAININFO, which is flag 4 in
        -- bits 3..5 of UNWIND_INFO's first byte => 4 << 3 = 32 = 0x20.
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
        propose(lo, chained and SRC.FRAG or SRC.PDATA)
      end
    end
    i = i + m
    gl_progress(i, n, 'pdata records'); gl_yield()
  end

  -- Repair by sorting INDEX arrays, so pdStart/pdEnd stay in step.
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


------------------------------------------------------------------ S2/S3: sweep
-- Deliberately NOT instruction-aligned, because aligning requires decoding.
-- Some E8 hits are therefore immediates or table bytes; their targets still
-- satisfy the inclusion rule, which is the rule in force.
local function sweepChunk(a, len, have, b, s, withJumps)
  -- E8 rel32: opcode at a+i-1, instruction is 5 bytes, so the displacement base
  -- (the next instruction) is a+i+4.
  local pos = 1
  while true do
    local i = find(s, '\232', pos, true)
    if i == nil or i > len then break end
    if i + 4 <= have then
      local b1, b2, b3, b4 = byte(s, i + 1, i + 4)
      local rel = b1 + 256 * b2 + 65536 * b3 + 16777216 * b4
      if rel >= 2147483648 then rel = rel - 4294967296 end
      local t = a + i + 4 + rel
      if propose(t, SRC.CALL) then callers[t] = (callers[t] or 0) + 1 end
    end
    pos = i + 1                     -- advance by ONE: overlapping matches are real
  end

  -- E9 rel32 (opt-in): tail calls and incremental-link thunks.
  if withJumps then
    pos = 1
    while true do
      local i = find(s, '\233', pos, true)
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

  -- Padding boundaries. Acceptance is asymmetric, and this is the subtlest rule
  -- in the file: a run of >= 2 pad bytes counts ANYWHERE; a LONE pad byte counts
  -- only when the following address is 16-aligned. Without that proviso a single
  -- 0x90 immediate or ModRM byte would drown the result set in noise.
  local padUntil = 0

  local function handle(i)
    local pl = padItemLen(b, i, have)
    if pl == 0 then return false end
    local j = i
    while pl > 0 do j = j + pl; pl = padItemLen(b, j, have) end
    padUntil = j - 1
    if j <= have then
      local t = a + j - 1
      if j - i >= 2 or t % 16 == 0 then propose(t, SRC.PAD) end
    end
    return true
  end

  -- Back off over leading 0x66 prefixes so a prefixed NOP is measured from its
  -- true start. Bounded at 8, matching padItemLen's own limit.
  local function hit(i)
    if i <= padUntil then return end
    local s0, n = i, 0
    while s0 > 1 and n < 8 and s0 - 1 > padUntil and b[s0 - 1] == 0x66 do
      s0 = s0 - 1; n = n + 1
    end
    if s0 ~= i and handle(s0) then return end
    handle(i)
  end

  pos = 1
  while true do
    local i = find(s, '[\204\144]', pos)
    if i == nil or i > len then break end
    hit(i)
    pos = math.max(i + 1, padUntil + 1)
  end

  padUntil = 0
  pos = 1
  while true do
    local i = find(s, '\15\31', pos, true)
    if i == nil or i > len then break end
    local s0 = i
    -- 0x2E is PART OF the NOP core, not a stray: step back onto it.
    if s0 > 1 and b[s0 - 1] == 0x2E then s0 = s0 - 1 end
    hit(s0)
    pos = math.max(i + 1, padUntil + 1)
  end
end

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
        local have = math.min(#b, avail)
        local ok, s = pcall(chunkString, b, have)
        if ok then sweepChunk(a, len, have, b, s, withJumps) end
      end
      a = a + len
      gl_progress(a - lo, total, label); gl_yield()
    end
  end
end


------------------------------------------------------------------ S4..S7, S11
local function srcEntry(pe) propose(pe.entry, SRC.ENTRY) end

-- AddressOfFunctions is indexed by ORDINAL and has NumberOfFunctions entries.
-- Ordinal-only exports exist exactly when that exceeds NumberOfNames, so walk
-- the function array rather than the smaller name-indexed one.
-- A 0 entry is a gap; an entry pointing INTO the export directory is a forwarder
-- STRING, not code, and must be skipped.
local function srcExports(pe)
  local addr, size = ddAddr(pe, DD.EXPORT)
  if addr == nil then return 0 end

  local nFuncs = rd32(addr + 20)
  local atRva  = rd32(addr + 28)
  if nFuncs == nil or atRva == nil or atRva == 0 or nFuncs > 0x100000 then return 0 end

  local tbl = pe.base + atRva
  local eLo, eHi = addr, addr + size
  local n, i, per = 0, 0, 16384

  while i < nFuncs do
    local m = math.min(per, nFuncs - i)
    local b = readBytes(tbl + i * 4, m * 4, true)
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

  -- Named exports. CORRECTED: the strides are i*4 and i*2. The previous
  -- revision used the undefined globals i4 and i2, which raised
  -- "attempt to perform arithmetic on a nil value" on any module with a single
  -- named export -- and many game EXEs export NvOptimusEnablement.
  local nNames = rd32(addr + 24)
  local aNames = rd32(addr + 32)
  local aOrds  = rd32(addr + 36)
  if nNames and aNames and aOrds and nNames > 0 and nNames < 0x100000 then
    for i = 0, nNames - 1 do
      local nr = rd32(pe.base + aNames + i * 4)
      local od = rd16(pe.base + aOrds  + i * 2)
      if nr and od then
        local fr = rd32(tbl + od * 4)
        if fr and fr ~= 0 then
          local t = pe.base + fr
          if not (t >= eLo and t < eHi) then
            local sn = readCString(pe.base + nr, 1024)
            if sn then addName(t, symbolShort(sn) .. ' (export)') end
          end
        end
      end
      if i % 2048 == 0 then gl_yield() end
    end
  end
  return n
end

-- IMAGE_TLS_DIRECTORY64: Start +0x00, End +0x08, Index +0x10, CallBacks +0x18
-- IMAGE_TLS_DIRECTORY32: Start +0x00, End +0x04, Index +0x08, CallBacks +0x0C
-- AddressOfCallBacks is a VA, not an RVA, and the array is NUL-terminated.
-- TLS callbacks run BEFORE the entry point, so no call instruction names them.
local function srcTLS(pe)
  local addr, size = ddAddr(pe, DD.TLS)
  if addr == nil then return 0 end
  local psz   = pe.is64 and 8 or 4
  local cbOff = pe.is64 and 0x18 or 0x0C
  if size < cbOff + psz then return 0 end
  local cb = pe.is64 and rd64(addr + cbOff) or rd32(addr + cbOff)
  if cb == nil or cb == 0 then return 0 end
  local n, guard, a = 0, 0, cb
  while guard < 64 do
    local f = pe.is64 and rd64(a) or rd32(a)
    if f == nil or f == 0 then break end
    if propose(f, SRC.TLS) then
      n = n + 1
      addName(f, 'TlsCallback' .. n .. ' (TLS callback)')
    end
    a = a + psz; guard = guard + 1
  end
  return n
end

-- MSVC merges .CRT into .rdata by default, so this usually finds nothing and the
-- initialisers come from S8 instead. Kept for custom link layouts.
local function srcCRT(pe)
  local spans = secSpans(pe, { '.CRT', '.00CRT', 'CRT' })
  if #spans == 0 then spans = secSpans(pe, { '.init' }) end
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

-- Control Flow Guard publishes every legitimate indirect call target.
--   IMAGE_LOAD_CONFIG_DIRECTORY      x86     x64
--     GuardCFFunctionTable (VA)     +0x50   +0x80
--     GuardCFFunctionCount          +0x54   +0x88
--     GuardFlags                    +0x58   +0x90
-- Entries are (4 + n) bytes, n = (GuardFlags >> 28) & 0xF, so the stride is NOT
-- fixed. Read the structure's own Size field first and refuse to parse a
-- structure that predates these fields.
local function srcCFG(pe)
  local addr = ddAddr(pe, DD.LOADCFG)
  if addr == nil then return 0 end
  local oTbl, oCnt, oFlg
  if pe.is64 then oTbl, oCnt, oFlg = 0x80, 0x88, 0x90
  else            oTbl, oCnt, oFlg = 0x50, 0x54, 0x58 end

  local lcSize = rd32(addr)
  if lcSize == nil or lcSize < oFlg + 4 then return 0 end

  local tbl   = pe.is64 and rd64(addr + oTbl) or rd32(addr + oTbl)
  local count = pe.is64 and rd64(addr + oCnt) or rd32(addr + oCnt)
  local flags = rd32(addr + oFlg)
  if tbl == nil or count == nil or flags == nil or tbl == 0 or count == 0 then return 0 end
  if count > 4000000 then return 0 end

  local stride = 4 + (floor(flags / 268435456) % 16)      -- 268435456 = 2^28
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


------------------------------------------------------------------ S8: pointers
-- PRE-FILTER: before assembling a qword, check that the two middle bytes of the
-- UPPER dword match the module's address window. A typical x64 image lives
-- inside one 4 GB window, so this rejects almost every slot after two lookups.
--
-- CORRECTED: the qword is now assembled with ptrFromChunk, which is bounds- and
-- hole-checked. The previous inline expression was missing the '+' between the
-- low and high dword groups, so Lua parsed "(A)(B)" as calling a number.
-- ptrFromChunk costs one Lua call per SURVIVING candidate, which the pre-filter
-- makes rare; correctness is worth more than that call.
local function scanPtrs(pe, ranges)
  local is64 = pe.is64
  local psz = is64 and 8 or 4
  local n = 0
  local fast, U4, U5 = false, 0, 0
  if is64 then
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
          local q = ptrFromChunk(b, k, 8)
          if q ~= nil and q >= EXLO and q <= EXHI and propose(q, SRC.PTR) then
            n = n + 1
          end
        end
      end
    else
      for k = 1, lim, 4 do
        local t = b[k+3]
        if t ~= nil and t >= tbLo and t <= tbHi then
          local q = ptrFromChunk(b, k, 4)
          if q ~= nil and q >= EXLO and q <= EXHI and propose(q, SRC.PTR) then
            n = n + 1
          end
        end
      end
    end
  end, 'bytes (S8 data pointers)')
  return n
end

-- OPT-IN. Every dword in (0, SizeOfImage) landing in code qualifies, so
-- switch-case labels, EH tables and plain integers all flood in. Tagged
-- separately (RVA / XDATA) so it can be filtered out again. x64 only: on PE32 an
-- RVA is indistinguishable from a small integer.
local function scanRvas(pe, ranges, tag, label)
  if not pe.is64 then return 0 end
  local limit = pe.size
  local topMax = floor(limit / 16777216)
  local base, n = pe.base, 0
  eachChunk(ranges, 4, function(b, len, have, a)
    local lim = math.min(len, have - 3)
    for k = 1, lim, 4 do
      local tb = b[k+3]
      if tb ~= nil and tb <= topMax then
        local r = ptrFromChunk(b, k, 4)
        if r ~= nil and r > 0 and r < limit then
          local t = base + r
          if t >= EXLO and t <= EXHI and propose(t, tag) then n = n + 1 end
        end
      end
    end
  end, label)
  return n
end


------------------------------------------------------------------ RTTI
-- MSVC / clang-cl ABI only; MinGW's Itanium RTTI has a different layout and
-- simply produces no COLs.
--   x64: signature 1, every reference is a 32-bit RVA, COL is 24 bytes ending
--        with pSelf (the COL's own RVA), name at TD+0x10.
--   x86: signature 0, references are absolute pointers, COL is 20 bytes, name at
--        TD+0x08.
--   COL = { signature +0x00, offset +0x04, cdOffset +0x08,
--           pTypeDescriptor +0x0C, pClassHierarchyDescriptor +0x10,
--           [x64: pSelf +0x14] }
--   CHD = { signature +0x00, attributes +0x04, numBaseClasses +0x08,
--           pBaseClassArray +0x0C }
--   BCD = { pTypeDescriptor +0x00, numContainedBases +0x04, PMD +0x08,
--           attributes +0x14 }
-- A vftable is PRECEDED by a pointer to its COL, at vftable - psz. That single
-- relationship turns "a class name" into "the addresses of its virtual methods".
local cols, hierarch, vtblMap, funcToClass = {}, {}, {}, {}

local function ptrRef(pe, v)
  if v == nil then return nil end
  if pe.is64 then return pe.base + v end
  return v
end

-- Rather than trusting one offset, PROBE the plausible 4-byte-aligned positions
-- 0x00..0x14 and accept the first resolving to an MSVC type-name string. +0x00 is
-- tried first because that IS the Microsoft field; a wrong guess loses one base
-- class rather than the whole hierarchy.
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

local function asSigned32(v)
  if v >= 0x80000000 then return v - 0x100000000 end
  return v
end

-- PASS 1: find every Complete Object Locator from bytes ALREADY in memory.
-- All structural tests run on the chunk table; CE is called once per SURVIVING
-- candidate -- roughly one call per class instead of one per slot.
--   strict -- x64 only, requires pSelf == the COL's own RVA. Essentially
--             self-addressing proof; eliminates almost every accidental match.
--   loose  -- drops pSelf. Retried only if strict found NOTHING.
-- Candidate tests, in order of increasing cost:
--   1. first byte == signature, next three == 0
--   2. top byte of pTypeDescriptor in range
--   3. offset-to-top and CD offset within +/-1 MB
--   4. td/chd inside the image (x64) or the module (x86)
--   5. strict: pSelf == own RVA
--   6. the name at TD+nameOff matches '^%.%?A[VUWT]'   (the CE call)
local function scanCols(pe, ranges, strict)
  local base, size, is64 = pe.base, pe.size, pe.is64
  local nameOff = is64 and 0x10 or 0x08
  local sig = is64 and 1 or 0
  local need = (is64 and strict) and 24 or 20

  -- x64: pTypeDescriptor is an RVA, so accept top bytes of RVAs in [0, size).
  -- x86: it is an absolute pointer, so accept top bytes of [base, base+size).
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
    -- A COL at b[k] needs k + need - 1 <= have, i.e. k <= have - (need - 1).
    local lim = math.min(len, have - (need - 1))
    for k = 1, lim, 4 do
      if b[k] == sig and b[k+1] == 0 and b[k+2] == 0 and b[k+3] == 0 then
        local tb = b[k+15]                       -- top byte of pTypeDescriptor
        if tb >= tLo and tb <= tHi then
          local off = b[k+4] + 256 * b[k+5] + 65536 * b[k+6] + 16777216 * b[k+7]
          local cd  = b[k+8] + 256 * b[k+9] + 65536 * b[k+10] + 16777216 * b[k+11]
          local soff, scd = asSigned32(off), asSigned32(cd)
          if soff > -0x100000 and soff < 0x100000
             and scd > -0x100000 and scd < 0x100000 then
            local td  = b[k+12] + 256 * b[k+13] + 65536 * b[k+14] + 16777216 * tb
            local chd = b[k+16] + 256 * b[k+17] + 65536 * b[k+18] + 16777216 * b[k+19]
            local ok
            if is64 then
              ok = td > 0 and td < size and chd > 0 and chd < size
              if ok and strict then
                local selfRva = b[k+20] + 256 * b[k+21]
                              + 65536 * b[k+22] + 16777216 * b[k+23]
                ok = (selfRva == a + k - 1 - base)
              end
            else
              ok = td >= base and td < base + size
               and chd >= base and chd < base + size
            end
            if ok then
              local tdVA, chdVA = ptrRef(pe, td), ptrRef(pe, chd)
              local nm = readCString(tdVA + nameOff, RTTI_NAME_MAX)
              if nm ~= nil and nm:match('^%.%?A[VUWT]') then
                local col = a + k - 1
                if cols[col] == nil then
                  cols[col] = { tdAddr = tdVA, tdName = nm, chdAddr = chdVA }
                  found = found + 1
                  -- Retain the COL and its TypeDescriptor NOW: cols[] is
                  -- released at the end of probe(), and a TypeDescriptor is
                  -- DATA, so it can never be recovered from the code roots.
                  -- (The previous revision did this twice; once is enough.)
                  local kd    = demangle(nm)
                  local short = symbolShort(nm)
                  addName(col,  short .. ' (COL)')
                  addName(tdVA, short .. ' (' ..
                    (kd and (kd:sub(1,1):upper() .. kd:sub(2)) or 'Type') .. ')')
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

-- Walk one vftable: every CONSECUTIVE code pointer is a virtual method. Reads 16
-- slots at a time, falling back to one slot at a mapping edge. Stops at the first
-- slot that is not in-module code -- both the natural end and the safety net
-- against a data array that merely looks like a vftable.
-- vtable slots are ROOTS, not just names: discovering a class is useless unless
-- its methods enter the function list.
local function walkVtable(pe, vslot, nm)
  local psz = pe.is64 and 8 or 4
  local nmShort = symbolShort(nm)
  local slot, c = vslot, 0
  while c < VTABLE_SLOTS do
    local b = readBytes(slot, 16 * psz, true)
    if b == nil then b = readBytes(slot, psz, true) end
    if b == nil then break end
    local got = floor(#b / psz)
    if got == 0 then break end
    for i = 0, got - 1 do
      local fa = ptrFromChunk(b, i * psz + 1, psz)
      if fa == nil or fa < EXLO or fa > EXHI or not inExec(fa) then return c end
      -- First class to claim a method keeps it. Two vftables can share a slot
      -- value (a common tail, or a thunk); the first winner is as good as any.
      if funcToClass[fa] == nil then funcToClass[fa] = nm end
      addName(fa, nmShort .. ' (vtable method)')
      propose(fa, SRC.VTBL)
      c = c + 1
      if c >= VTABLE_SLOTS then return c end
    end
    slot = slot + got * psz
  end
  return c
end

-- PASS 2: a slot whose VALUE is a known COL address is the slot at vftable - psz,
-- so the vftable begins one pointer later:
--     vslot = a + k - 1 + psz   ==>   mem[vftable - psz] = col
-- On x64, subtract 8 from a reported vftable address and you must land on its COL.
-- CORRECTED: same missing-'+' defect as scanPtrs; now uses ptrFromChunk.
local function scanVtables(pe, ranges)
  local is64 = pe.is64
  local psz = is64 and 8 or 4
  local lo, hi = pe.base, pe.base + pe.size - 1
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
          q = ptrFromChunk(b, k, 8)
        end
      else
        local t = b[k+3]
        if t ~= nil and t >= tbLo and t <= tbHi then
          q = ptrFromChunk(b, k, 4)
        end
      end
      if q ~= nil then
        -- The hash lookup is the whole test: is this value a COL we found?
        local c = cols[q]
        if c ~= nil then
          local vslot = a + k - 1 + psz
          vtblMap[vslot] = { colAddr = q, className = c.tdName }
          addName(vslot, symbolShort(c.tdName) .. ' (vfTable)')
          walkVtable(pe, vslot, c.tdName)
          nv = nv + 1
        end
      end
    end
  end, 'bytes (RTTI vtable walk)')
  return nv
end

-- class -> { bases = {...}, attrs = ... }. One read fetches the WHOLE base-class
-- array. Keyed by the MANGLED name, since that is what cols[] holds -- which is
-- why base() does not compose directly with classOf().
local function buildHierarchy(pe)
  local nameOff = pe.is64 and 0x10 or 0x08
  for _, col in pairs(cols) do
    if col.chdAddr then
      local nb = rd32(col.chdAddr + 0x08)
      local ar = rd32(col.chdAddr + 0x0C)
      if nb and ar and nb > 0 and nb < 4096 then
        local arr = ptrRef(pe, ar)
        local bases = {}
        if arr ~= nil then
          local ab = readBytes(arr, nb * 4, true)
          if ab ~= nil then
            for i = 0, floor(#ab / 4) - 1 do
              local v = ab[i*4+1] + 256 * ab[i*4+2]
                      + 65536 * ab[i*4+3] + 16777216 * ab[i*4+4]
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


------------------------------------------------------------------ RESULTS
-- SIX PARALLEL NUMBER ARRAYS, ~100 bytes per function, rather than one ~650-byte
-- table per function. Index i means the same function in all six.
--   fStart[i]    absolute address
--   fEnd[i]      first byte AFTER it (exclusive)
--   fMask[i]     packed source-bit mask
--   fConf[i]     confidence tier 0..4
--   fCallers[i]  number of distinct E8 sites targeting it
--   fKind[i]     0 = guessed extent, 1 = exact .pdata, 2 = nested
local fStart, fEnd, fMask, fConf, fCallers, fKind = {}, {}, {}, {}, {}, {}
local confA, confB = {}, {}

-- EXTENT POLICY, in order of preference:
--   1. exact   : start is a .pdata BeginAddress -> use EndAddress
--   2. clipped : start lies inside a .pdata body -> min(next candidate, body end)
--   3. guessed : otherwise -> next candidate, or the section end
-- The merge is a single linear walk with one cursor that only ever advances, so
-- the cost is O(n log n) for the sort and O(n + m) after it. Nothing is decoded.
local function analyze(secs, nroot)
  gl_phase('Sorting candidates')
  local cand, n = {}, 0
  for a in pairs(roots) do n = n + 1; cand[n] = a end
  table.sort(cand)

  gl_phase('Computing extents and status')
  fStart, fEnd, fMask, fConf, fCallers, fKind = {}, {}, {}, {}, {}, {}
  confA, confB = {}, {}

  local p, np = 1, #pdStart
  local nNested, nExact, nAuth, guessed = 0, 0, 0, 0

  for k = 1, n do
    local st = cand[k]
    local v = roots[st]
    local conf = floor(v / CONFSHIFT)
    local mask = v - conf * CONFSHIFT

    -- On exit, pdStart[p] is the first record beginning at or after st, so
    -- "pdStart[p] < st" is exactly the test for "st is inside a body".
    while p <= np and pdEnd[p] <= st do p = p + 1 end

    local secHi = st
    for s = 1, #secs do
      if st >= secs[s].lo and st <= secs[s].hi then secHi = secs[s].hi break end
    end
    local limit = secHi + 1
    local nxt = cand[k + 1]
    if nxt ~= nil and nxt < limit then limit = nxt end

    local en, kv
    if p <= np and pdStart[p] == st then
      en, kv = pdEnd[p], 1
      nExact = nExact + 1
    elseif p <= np and pdStart[p] < st then
      en = math.min(limit, pdEnd[p])
      if conf >= 3 then
        -- Strong enough to be its own function (a thunk, an outlined hot path).
        kv = 0
      else
        kv = 2
        nNested = nNested + 1
        confA[#confA + 1], confB[#confB + 1] = pdStart[p], st
      end
    else
      en, kv = limit, 0
    end

    -- Deliberately conservative: case 2 with conf >= 3 counts as guessed even
    -- though its bound is real, so "guessed-extent bytes" never understates.
    if kv == 0 then guessed = guessed + (en - st) end
    if conf >= 3 and kv ~= 2 then nAuth = nAuth + 1 end

    fStart[k], fEnd[k], fMask[k], fConf[k] = st, en, mask, conf
    fCallers[k], fKind[k] = callers[st] or 0, kv

    if k % 8192 == 0 then gl_progress(k, n, 'functions'); gl_yield() end
  end

  gl_progress(n, n, 'functions')
  return { nroot = nroot, nfuncs = n, nested = nNested, exact = nExact,
           auth = nAuth, guessed = guessed }
end


------------------------------------------------------------------ DRIVER
local gl_co, gl_tmr, gl_busy = nil, nil, false
local lastStat = nil

-- Single exit point for success and failure. Clears every large structure,
-- including on the error path. Deliberately does NOT clear nmAddr/nmDesc/nmSeen,
-- vtblMap, funcToClass or hierarch: those are the durable outputs.
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
  if stat then
    lastStat = stat
    print(string.format(
      'functions=%d  exact=%d  nested=%d  authoritative=%d  guessed-extent bytes=%d',
      stat.nfuncs, stat.exact, stat.nested, stat.auth, stat.guessed))
    print(string.format('names retained: %d',
      #nmAddr))
  end
  print('Done!')
end

local function _endWindow()
  gl_stop()
end

-- ALWAYS returns nil, because the work is asynchronous. Poll count() or watch for
-- the summary lines.
local function _probe()
  if gl_co ~= nil then print('ghidraLike already running'); return nil end
  local module0 = process
  if module0 == nil then
    print('ghidraLike: open a process first')
    return nil
  end
  moduleName = tostring(module0)

  roots, callers = {}, {}
  pdStart, pdEnd, pdChained = {}, {}, {}
  fStart, fEnd, fMask, fConf, fCallers, fKind = {}, {}, {}, {}, {}, {}
  confA, confB = {}, {}
  cols, hierarch, vtblMap, funcToClass = {}, {}, {}, {}
  nmAddr, nmDesc, nmSeen = {}, {}, {}
  nmBase, nmModule = 0, ''
  lastStat = nil

  gl_open('ghidraLike - ' .. tostring(module0))

  gl_co = coroutine.create(function()
    local base = normAddr(getAddress(module0))
    if base == nil then
      error('getAddress("' .. tostring(module0) .. '") returned no address')
    end
    moduleBase = base
    -- Bind the registry to this module NOW, so namecsv() can rebase without
    -- needing buildNames() at all.
    nmBase, nmModule = base, moduleName

    local modSize = normAddr(getModuleSize(module0))
    local pe = peInfo(base)
    if pe == nil then error('PE parse failed for ' .. tostring(module0)) end
    pe.moduleName = module0

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

    -- THE INCLUSION RULE LIVES HERE. These ranges, and nothing else, define what
    -- counts as code for the rest of the run.
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
    if how == 'OS' then
      print('  WARNING: resolved by page protection - if the image is still being'
        .. ' decrypted, re-run after the game has fully started.')
    end

    gl_phase('S1  .pdata (exception directory)')
    print('S1 pdata records: ' .. srcPdata(pe, true))

    gl_phase('S2/S3  code sweep (E8 + padding + E9)')
    sweepCode(secs, true)
    print('S2/S3 sweep done  candidates so far: ' .. cnt(roots))

    gl_phase('S4  entry point');     srcEntry(pe)
    gl_phase('S5  export table');    print('S5 exports: ' .. srcExports(pe))
    gl_phase('S6  TLS callbacks');   print('S6 tls: ' .. srcTLS(pe))
    gl_phase('S7  .CRT initialisers'); print('S7 crt: ' .. srcCRT(pe))

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

    addName(pe.entry, 'EntryPoint (entry point)')

    local nroot = cnt(roots)
    local stat = analyze(secs, nroot)

    roots, callers = {}, {}
    pdStart, pdEnd, pdChained = {}, {}, {}
    cols = {}
    return stat
  end)

  gl_tmr = createTimer(getMainForm())
  gl_tmr.Interval = 1
  gl_tmr.OnTimer = function()
    if gl_busy or gl_co == nil then return end
    gl_busy = true
    local ok, res = coroutine.resume(gl_co)
    gl_busy = false
    if not ok then
      -- Traceback from the DEAD coroutine, so the message names the function and
      -- line that actually failed rather than the timer callback.
      local msg = tostring(res)
      if debug and debug.traceback then
        local okTb, tb = pcall(debug.traceback, gl_co, msg)
        if okTb and type(tb) == 'string' then msg = tb end
      end
      gl_stop(msg, nil)
    elseif coroutine.status(gl_co) == 'dead' then
      gl_stop(nil, res)
    end
  end
  return nil
end


------------------------------------------------------------------ OUTPUT
local function hasTag(mask, tag) return floor(mask / TAGBIT[tag]) % 2 == 1 end

local function tagsOf(mask)
  local t = {}
  for i = 1, #TAGORDER do
    if hasTag(mask, TAGORDER[i]) then t[#t+1] = TAGORDER[i] end
  end
  return t
end

-- 'nested' is a FLAG, not a rejection: the rule is that nothing is deleted.
local function statusOf(kv, conf)
  if kv == 2 then return 'nested' end
  if conf >= 3 then return 'authoritative' end
  return 'included'
end

-- FIRST MATCH WINS. A virtual method that is also in .pdata reports as "vtable
-- method"; check srcs for 'pdata' if you want the stronger claim.
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

-- One throwaway table per displayed row. The DURABLE store stays the flat arrays.
-- Note ['end']: "end" is a Lua keyword, so bracket syntax is the only access.
local function recAt(i)
  local st, conf, mask, kv = fStart[i], fConf[i], fMask[i], fKind[i]
  local ed = fEnd[i] - 1
  local sr, er = addressOffset(st), addressOffset(ed)
  return {
    start = st, ['end'] = ed, size = fEnd[i] - st,
    srcs = tagsOf(mask), conf = conf, status = statusOf(kv, conf),
    callers = fCallers[i], fromPdata = (kv == 1), nested = (kv == 2),
    class = funcToClass[st], kind = kindOf(mask, fCallers[i], funcToClass[st]),
    startRel = sr, endRel = er
  }
end

-- RFC-4180 escaping.
local function csvEsc(s)
  s = tostring(s or '')
  if s:find('[",\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
  return s
end

local function _csv(path)
  local fh = io.open(path, 'w')
  if fh == nil then print('cannot open ' .. tostring(path)); return end
  fh:write('start,end,size,directCallSites,status,confidence,sources,kind,fromPdata,class\n')
  for i = 1, #fStart do
    local f = recAt(i)
    local _, cn = demangle(f.class)
    fh:write(table.concat({
      f.startRel, f.endRel,
      tostring(f.size), tostring(f.callers), csvEsc(f.status), CONFNAME[f.conf+1],
      csvEsc(table.concat(f.srcs, '|')), csvEsc(f.kind),
      tostring(f.fromPdata), csvEsc(cn or ''),
    }, ',') .. '\n')
  end
  fh:close(); print('wrote ' .. path .. ' (' .. #fStart .. ' rows)')
end

local function sortedKeys(t)
  local ks = {}
  for k in pairs(t) do ks[#ks+1] = k end
  table.sort(ks)
  return ks
end

-- ONE ROW PER VFTABLE, not per class. A class with virtual bases, or one reached
-- through adjustor thunks, owns several COLs, so a name legitimately repeats.
-- "kind" here is the RTTI type kind, NOT the "kind" column of csv().
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
    fh:write(table.concat({
      addressOffset(ks[n]), addressOffset(v.colAddr),
      csvEsc(label or '?'), csvEsc(name or v.className),
      csvEsc(table.concat(names, '|')),
    }, ',') .. '\n')
  end
  fh:close(); print('wrote ' .. path .. ' (' .. #ks .. ' rows)')
end


------------------------------------------------------------------ NAMES
-- ADDITIVE and idempotent. It does NOT clear the registry: the scan already
-- filled it with real export names, TypeDescriptors and COLs, and addName is
-- first-writer-wins, so those survive and these generic labels only fill gaps.
-- Calling it is optional -- namecsv() works straight after probe().
--[[local function buildNames()
  local ok, b = pcall(getAddress, moduleName)
  if not ok or type(b) ~= 'number' then
    print('buildNames: cannot resolve module ' .. tostring(moduleName)); return 0
  end
  nmBase, nmModule = b, moduleName

  for vslot, v in pairs(vtblMap) do
    local short = symbolShort(v.className)
    addName(v.colAddr, short .. ' (COL)')
    addName(vslot,     short .. ' (vfTable)')
  end
  for fa, mn in pairs(funcToClass) do
    addName(fa, symbolShort(mn) .. ' (vtable method)')
  end
  for i = 1, #fStart do
    local m, a = fMask[i], fStart[i]
    if     hasTag(m, SRC.EXP)   then
      addName(a, 'export' .. string.format('%X', a - b) .. ' (export)')
    elseif hasTag(m, SRC.TLS)   then addName(a, 'TlsCallback (TLS callback)')
    elseif hasTag(m, SRC.CRT)   then addName(a, 'CRT_initialiser (global constructor)')
    elseif hasTag(m, SRC.ENTRY) then addName(a, 'EntryPoint (entry point)')
    end
  end
  print(string.format('buildNames: %d named addresses total, %s base %X',
    #nmAddr, tostring(nmModule), b))
  return #nmAddr
end]]

-- ONE ROW PER NAMED ADDRESS. offset is hex, relative to the module base.
-- The '#module=' line lets loadNames rebase without being told the name.
local function _namecsv(path)
  if #nmAddr == 0 then
    print('namecsv: nothing retained - run probe() first'); return
  end
  local base = nmBase
  local mn   = nmModule
  if base == nil or base == 0 then base = moduleBase end
  if mn == nil or mn == '' then mn = moduleName end
  if base == nil or base == 0 then
    print('namecsv: no module base known - run probe() first'); return
  end
  local fh = io.open(path, 'w')
  if fh == nil then print('cannot open ' .. tostring(path)); return end
  local idx = {}
  for i = 1, #nmAddr do idx[i] = i end
  table.sort(idx, function(x, y) return nmAddr[x] < nmAddr[y] end)
  fh:write('#module=' .. tostring(mn) .. '\n')
  fh:write('offset,desc\n')
  for k = 1, #idx do
    local i = idx[k]
    fh:write(string.format('%X', nmAddr[i] - base) .. ',' .. csvEsc(nmDesc[i]) .. '\n')
  end
  fh:close()
  print('wrote ' .. tostring(path) .. ' (' .. #idx .. ' named addresses)')
end


------------------------------------------------------------------ lookup
-- THE single runtime lookup table. loadNames / useNames write it; nameAt and
-- annotate read it. Declared exactly once.
local nmMap, nmCount = {}, 0
local nmLo, nmHi = 0, -1
local nmCache = {}                 -- addr -> desc | false, register-free only
local nmRegSig, nmRegTab = nil, nil

-- Minimal RFC-4180 reader: quoted fields, doubled quotes.
local function nmSplitCsv(line)
  local out, i, n = {}, 1, #line
  while i <= n do
    if line:sub(i,i) == '"' then
      local buf = {}; i = i + 1
      while i <= n do
        local d = line:sub(i,i)
        if d == '"' then
          if line:sub(i+1,i+1) == '"' then buf[#buf+1] = '"'; i = i + 2
          else i = i + 1; break end
        else buf[#buf+1] = d; i = i + 1 end
      end
      out[#out+1] = table.concat(buf)
      if line:sub(i,i) == ',' then i = i + 1 end
    else
      local j = line:find(',', i, true)
      if j == nil then out[#out+1] = line:sub(i); i = n + 1
      else out[#out+1] = line:sub(i, j-1); i = j + 1 end
    end
  end
  return out
end

local function unloadNames()
  nmMap, nmCount, nmCache = {}, 0, {}
  nmLo, nmHi, nmRegSig, nmRegTab = 0, -1, nil, nil
end

local function _loadNames(path, module)
  local fh = io.open(path, 'r')
  if fh == nil then print('loadNames: cannot open ' .. tostring(path)); return 0 end
  local mn, rows = module, {}
  for line in fh:lines() do
    local mc = line:match('^#module=(.+)$')
    if mc then
      if mn == nil then mn = mc:match('^%s*(.-)%s*$') end
    elseif line:sub(1,1) ~= '#' and line:find(',', 1, true) then
      local f = nmSplitCsv(line)
      local off, desc = tonumber(f[1], 16), f[2]
      if off and desc and desc ~= '' and desc ~= 'desc' and f[1] ~= 'offset' then
        rows[#rows+1] = { off, desc }
      end
    end
  end
  fh:close()
  mn = mn or moduleName or process
  if mn == nil then print('loadNames: no module name'); return 0 end
  if #rows == 0 then print('loadNames: no data rows in ' .. tostring(path)); return 0 end
  local ok, b = pcall(getAddress, mn)
  if not ok or type(b) ~= 'number' then
    print('loadNames: cannot resolve module ' .. tostring(mn)); return 0
  end
  return nmInstall(rows, b, mn)
end

local function _nameAt(a)
  if type(a) ~= 'number' or a < nmLo or a > nmHi then return nil end
  return nmMap[a]
end


------------------------------------------------------------------ registers
-- CE supplies RAX..R15 and EAX..EIP, but not AX/AL/AH/SIL/R8B. Derive those
-- arithmetically, so the file still needs no bit operators:
--     alias = floor(family / 2^shift) mod 2^(bytes*8)
local NRFAM = {'RAX','RBX','RCX','RDX','RSI','RDI','RBP','RSP','RIP',
               'R8','R9','R10','R11','R12','R13','R14','R15'}
local NRALIAS = {}
do
  local e = {RAX='EAX',RBX='EBX',RCX='ECX',RDX='EDX',RSI='ESI',RDI='EDI',
             RBP='EBP',RSP='ESP',RIP='EIP'}
  local w = {RAX='AX',RBX='BX',RCX='CX',RDX='DX',RSI='SI',RDI='DI',
             RBP='BP',RSP='SP',RIP='IP'}
  local b = {RAX='AL',RBX='BL',RCX='CL',RDX='DL',RSI='SIL',RDI='DIL',
             RBP='BPL',RSP='SPL'}
  local h = {RAX='AH',RBX='BH',RCX='CH',RDX='DH'}
  for i = 1, #NRFAM do
    local f = NRFAM[i]
    NRALIAS[f] = {f,8,0}
    if e[f] then NRALIAS[e[f]] = {f,4,0} end
    if w[f] then NRALIAS[w[f]] = {f,2,0} end
    if b[f] then NRALIAS[b[f]] = {f,1,0} end
    if h[f] then NRALIAS[h[f]] = {f,1,8} end
    local num = f:match('^R(%d+)$')
    if num then
      NRALIAS['R'..num..'D'] = {f,4,0}
      NRALIAS['R'..num..'W'] = {f,2,0}
      NRALIAS['R'..num..'B'] = {f,1,0}
    end
  end
end

local function nmRegs()
  local ok, brk = pcall(debug_isBroken)
  if not ok or brk ~= true then return nil end
  local sig = tostring(RIP) .. ':' .. tostring(RSP) .. ':' .. tostring(RAX)
  if nmRegSig == sig and nmRegTab then return nmRegTab end
  local R = {}
  for i = 1, #NRFAM do
    local f = NRFAM[i]
    local v = _G[f]
    if type(v) == 'number' then R[f] = v end
  end
  for a, d in pairs(NRALIAS) do
    if R[a] == nil then
      local v = R[d[1]]
      if type(v) == 'number' then
        R[a] = floor(v / (2 ^ d[3])) % (2 ^ (d[2] * 8))
      end
    end
  end
  nmRegSig, nmRegTab = sig, R
  return R
end

-- Tokenise rather than blank-and-refill. A word is tested against the register
-- table FIRST, so AF00C is hex but RAX is not. Registers become DECIMAL literals;
-- bare hex runs get an 0x prefix. Returns (sawRegister, expr|nil).
local function nmExpr(text, R)
  local parts, pos, n = {}, 1, #text
  local sawReg = false
  while pos <= n do
    local c = text:sub(pos,pos)
    if c:match('[%a_]') then
      local w  = text:match('^[%a_][%w_%.]*', pos)
      local up = w:upper()
      if NRALIAS[up] then
        sawReg = true
        local v = R and R[up]
        if v == nil then return true, nil end
        parts[#parts+1] = string.format('%.0f', v)
      elseif w:match('^%x+$') then
        parts[#parts+1] = '0x' .. w
      else
        return sawReg, nil            -- unknown symbol: refuse to guess
      end
      pos = pos + #w
    elseif c:match('%x') then
      local w = text:match('^%x+', pos)
      parts[#parts+1] = '0x' .. w
      pos = pos + #w
    elseif c:match('[%+%-%*%(%)%s]') then
      parts[#parts+1] = c
      pos = pos + 1
    else
      return sawReg, nil
    end
  end
  return sawReg, table.concat(parts)
end

-- getAddress may not accept "module.section+OFF"; split and retry.
local function nmSym(text)
  local ok, a = pcall(getAddress, text)
  if ok and type(a) == 'number' then return a end
  local lhs, off = text:match('^(.-)%+([%x]+)$')
  if lhs and off then
    local ok2, b = pcall(getAddress, lhs)
    if ok2 and type(b) == 'number' then return b + tonumber(off, 16) end
  end
  return nil
end

local function nmResolve(text, R)
  text = text:match('^%s*(.-)%s*$')
  if text == '' then return nil, false end
  if text:match('^%x+$') then return tonumber(text, 16), false end
  local sawReg, expr = nmExpr(text, R)
  if sawReg then
    if expr == nil then return nil, true end
    local f = loadstr('return ' .. expr)
    if f == nil then return nil, true end
    local ok, v = pcall(f)
    if ok and type(v) == 'number' and floor(v) == v then return v, true end
    return nil, true
  end
  return nmSym(text), false
end

-- Resolve an instruction's operands and return the matching descs, or nil.
-- Takes TEXT, never disassembles: the no-decode rule is preserved.
-- Pass a NUMERIC address as addr, so nmCache keys stay consistent.
local function _annotate(addr, inst)
  if nmCount == 0 or type(inst) ~= 'string' or inst == '' then return nil end
  local hit = nmCache[addr]
  if hit ~= nil then return hit or nil end

  local R = nmRegs()
  local usedRegs = false
  local out, seen = {}, {}

  local function add(a, suffix)
    if type(a) ~= 'number' or a < nmLo or a > nmHi then return end
    local d = nmMap[a]
    if d then
      local s = d .. (suffix or '')
      if not seen[s] then seen[s] = true; out[#out+1] = s end
    end
  end

  local mn = inst:match('^%s*(%a+)')
  mn = mn and mn:lower() or ''
  local isCtl = (mn == 'call' or mn == 'jmp')
  -- Absent an explicit "dword ptr", assume a pointer-width slot. On a 32-bit
  -- target write "dword ptr" in the operand, or the indirect read is wrong.
  local useQword = not inst:lower():find('dword ptr', 1, true)

  local nbr = 0
  for br in inst:gmatch('%b[]') do
    nbr = nbr + 1
    local a, ur = nmResolve(br:sub(2, -2), R)
    usedRegs = usedRegs or ur
    if a then
      add(a)
      -- call/jmp [X]: X is a SLOT, [X] is the function. Name both.
      if isCtl then
        local ok, t
        if useQword then ok, t = pcall(readQword, a) else ok, t = pcall(readInteger, a) end
        if ok and type(t) == 'number' then add(t, ' (indirect target)') end
      end
    end
  end

  if nbr == 0 then
    -- CORRECTED: (.*)$ not (.)$. The old pattern captured ONE character, so
    -- "call 140001000" yielded the single character "0" and nothing resolved.
    -- For an operand string of length L it returned 1 instead of L.
    local ops = inst:match('^%s*%S+%s*(.*)$') or ''
    for tok in ops:gmatch('[^,]+') do
      tok = tok:match('^%s*(.-)%s*$')
      if tok and tok ~= '' and not tok:find('%s') then
        local a, ur = nmResolve(tok, R)
        usedRegs = usedRegs or ur
        if a then add(a) end
      end
    end
  end

  local desc = (#out > 0) and table.concat(out, ' | ') or nil
  if not usedRegs then nmCache[addr] = desc or false end
  return desc
end


------------------------------------------------------------------ sections
-- Re-parses the header, so it does NOT require a completed probe(). Reach for
-- this first when a scan looks wrong: it tells you whether the section table
-- lies, and therefore whether the OS-page-protection fallback is about to kick in.
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
      s.va, s.va + secSize(s) - 1, s.vsz or 0, c,
      hasBit(c, SCN.CODE)     and 'CODE '  or '',
      hasBit(c, SCN.MEM_EXEC) and 'EXEC '  or '',
      hasBit(c, SCN.MEM_WRITE) and 'WRITE' or ''))
  end
end


------------------------------------------------------------------ JSON
-- CORRECTED: every escape is DOUBLED, so Lua emits the two-character sequence
-- JSON requires. The previous version wrote '\ "' (an invalid Lua escape, so the
-- whole file failed to compile), '\u003c' (invalid: Lua wants \u{003c}), and
-- '\b'/'\t'/'\n'/'\f'/'\r' which produce RAW CONTROL BYTES that JSON.parse
-- rejects inside a string.
-- '<' and '>' are escaped so a class name containing "</script>" cannot break out
-- of the embedded <script type="application/json"> element.
local function jsonStr(s)
  s = tostring(s or '')
  local out = {}
  for i = 1, #s do
    local c = s:byte(i)
    if     c == 34 then out[#out+1] = '\\"'
    elseif c == 92 then out[#out+1] = '\\\\'
    elseif c == 8  then out[#out+1] = '\\b'
    elseif c == 9  then out[#out+1] = '\\t'
    elseif c == 10 then out[#out+1] = '\\n'
    elseif c == 12 then out[#out+1] = '\\f'
    elseif c == 13 then out[#out+1] = '\\r'
    elseif c == 60 then out[#out+1] = '\\u003c'
    elseif c == 62 then out[#out+1] = '\\u003e'
    elseif c < 32 or c == 127 then
      out[#out+1] = string.format('\\u%04x', c)
    else
      out[#out+1] = char(c)
    end
  end
  return '"' .. table.concat(out) .. '"'
end


------------------------------------------------------------------ HTML
-- ghidraLike.html(path) writes a self-contained page of RTTI class hierarchies.
--   * <details>/<summary> gives native collapsible panes with no framework.
--   * Data is embedded as JSON, so the file works offline from file://.
--   * Unknown base classes become placeholder nodes, hideable without losing the
--     derived classes attached to them.
--   * Multiple inheritance is a graph, not necessarily a tree. The default view
--     is "top-level panes with flat descendant lists", which avoids exponential
--     duplication in diamond hierarchies. A nested tree mode is also provided.
--   * FILTER SEMANTICS: the search box selects PANES, not rows. A pane is shown
--     if ANY row it would display contains the substring; once shown, it displays
--     all of its rows. Matching rows are highlighted.
--   * The searchable text is exactly the three rendered places: c.name,
--     c.mangled, and the base names as joined. c.kind is deliberately excluded.
--   * render() reads visiblePanes(), so the export cannot drift from the page.
--
-- CORRECTED: attribute values no longer carry stray spaces. id= "tree " made
-- getElementById('tree') return null and killed the page silently.
local function _html(path)
  local fh = io.open(path, 'w')
  if fh == nil then print('cannot open ' .. tostring(path)); return end

  -- hierarch alone can miss root classes with no bases, so also use vtblMap and
  -- funcToClass.
  local names = {}
  local function addClassName(n)
    if type(n) == 'string' and n ~= '' and names[n] == nil then names[n] = true end
  end
  for m in pairs(hierarch) do
    addClassName(m)
    local h = hierarch[m]
    if h and h.bases then
      for i = 1, #h.bases do addClassName(h.bases[i]) end
    end
  end
  for _, v in pairs(vtblMap) do addClassName(v.className) end
  for _, m in pairs(funcToClass) do addClassName(m) end

  -- Group vftables by class, then take the PRIMARY one as the lowest address.
  -- Secondary vftables are laid out immediately after the primary, so the minimum
  -- is the primary, and its COL is the class's own locator, not a subobject's.
  local byName = {}
  for vslot, v in pairs(vtblMap) do
    local l = byName[v.className]
    if l == nil then l = {}; byName[v.className] = l end
    l[#l + 1] = { vft = vslot, col = v.colAddr }
  end
  local classAddrs = {}
  for m, l in pairs(byName) do
    table.sort(l, function(a, b) return a.vft < b.vft end)
    local r = { col = l[1].col, vftables = {}, methods = {} }
    for i = 1, #l do r.vftables[i] = l[i].vft end
    classAddrs[m] = r
  end
  for fa, m in pairs(funcToClass) do
    local r = classAddrs[m]
    if r == nil then r = { vftables = {}, methods = {} }; classAddrs[m] = r end
    r.methods[#r.methods + 1] = fa
  end

  -- CORRECTED: build FRESH relative-address arrays per class instead of mutating
  -- classAddrs in place. The old in-place conversion could run twice on a record
  -- reached through the demangled-name fallback, and could call addressOffset(nil)
  -- on a record that had no COL.
  local function relList(t)
    local s = {}
    for i = 1, #t do s[i] = t[i] end
    table.sort(s)
    local o = {}
    for i = 1, #s do o[i] = addressOffset(s[i]) or '' end
    return o
  end

  local classes = {}
  for m in pairs(names) do
    local kind, name = demangle(m)
    local mdr = classAddrs[m] or classAddrs[name]
    local h = hierarch[m]
    local bases = {}
    if h and h.bases then
      for i = 1, #h.bases do bases[#bases + 1] = h.bases[i] end
    end
    local rec = {
      mangled = m,
      name = name or m,
      kind = kind or 'type',
      bases = bases,
      attrs = h and h.attrs or nil
    }
    if mdr ~= nil then
      rec.addrs_col      = mdr.col and addressOffset(mdr.col) or nil
      rec.addrs_vftables = relList(mdr.vftables)
      rec.addrs_methods  = relList(mdr.methods)
    end
    classes[#classes + 1] = rec
  end
  table.sort(classes, function(a, b) return a.mangled < b.mangled end)

  -- Build JSON manually, so no Lua JSON library is required.
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

  -- HTML part 1: head, styles, toolbar, opening JSON script tag.
  -- Every attribute value below has NO space between the quotes and the value.
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
h1 { font-size: 18px; margin: 0 0 8px 0; }
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
.toolbar button:hover { border-color: var(--accent); }
#stats {
  color: var(--muted);
  margin-left: auto;
  white-space: nowrap;
}
main { padding: 12px 14px 40px 14px; }
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
details.rootPane > summary::-webkit-details-marker { display: none; }
details.rootPane[open] > summary { border-bottom: 1px solid var(--line); }
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
  white-space: pre-wrap;
  margin: 4px 0;
  font: inherit;
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
ul.descList li.match { background: rgba(11, 95, 191, .12); }
.nested { padding: 8px 10px 10px 22px; }
.nested details {
  margin: 4px 0;
  border-left: 1px dashed var(--line);
  padding-left: 8px;
}
.nested summary { cursor: pointer; }
.cycle, .empty {
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

  fh:write(json)

  -- HTML part 2: renderer.
  fh:write([==[
</script>
<script>
(() => {
  const data = JSON.parse(document.getElementById('class-data').textContent || '{}');
  const map = new Map();

  // CORRECTED: the methods branch used to test c.vftables.length, which is
  // undefined for a class with methods but no vftable, and threw.
  function addressText(c) {
    let t = '';
    const vf = Array.isArray(c.vftables) ? c.vftables : [];
    const me = Array.isArray(c.methods) ? c.methods : [];
    if (vf.length > 0) {
      t += vf.length === 1
        ? `vftables: "${vf[0]}", `
        : `vftables: ["${vf.join('", "')}"], `;
    }
    if (typeof c.col !== 'undefined' && c.col !== '') {
      t += `COL: "${c.col}", `;
    }
    if (me.length > 0) {
      t += me.length === 1
        ? `Methods: "${me[0]}", `
        : `Methods: ["${me.join('", "')}"], `;
    }
    return t.endsWith(', ') ? t.slice(0, -2) : t;
  }

  for (const c of data.classes || []) {
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
      displayAddresses: addressText(c)
    });
  }

  // CORRECTED: placeholder nodes now carry displayAddresses: ''. Without it the
  // field was undefined, so the "=== ''" tests below failed and the page printed
  // ": (undefined)" after every base of an unknown class.
  function ensure(m) {
    if (!map.has(m)) {
      map.set(m, {
        mangled: m,
        name: m,
        kind: 'unknown',
        bases: [],
        unknown: true,
        vftables: [],
        methods: [],
        col: '',
        displayAddresses: ''
      });
    }
    return map.get(m);
  }

  // Make sure every base exists as a node. Done ONCE, before children is built.
  // The old version ran this loop twice, so children was built from the first
  // pass and the self-base guard in the second pass had no effect on it.
  for (const c of Array.from(map.values())) {
    const seen = new Set();
    const bs = [];
    for (const b of c.bases) {
      if (b === c.mangled) continue;        // a class is never its own base
      const node = ensure(b);
      if (!seen.has(node.mangled)) {
        seen.add(node.mangled);
        bs.push(node.mangled);
      }
    }
    c.bases = bs;
  }

  // children[base] = direct derived classes.
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

  const roots = Array.from(map.values())
    .filter(c => c.bases.length === 0)
    .sort(cmpNode);

  const $ = id => document.getElementById(id);
  const tree = $('tree');
  const stats = $('stats');
  if (!tree) { return; }

  function nodeName(m) {
    const c = map.get(m);
    return c ? c.name : m;
  }

  // FILTER HAYSTACK: exactly the three rendered places. Joined with \n, not a
  // space, so a term cannot match across two of them. c.kind is excluded.
  // Memoised: map is never mutated after load.
  const hayCache = new Map();
  function rowHaystack(c) {
    if (!c) return '';
    const cached = hayCache.get(c.mangled);
    if (cached !== undefined) return cached;
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

  // Transitive descendants of one root, unique per root, breadth-first.
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
        if (!seen.has(kid)) q.push({ m: kid, depth: item.depth + 1 });
      }
    }
    out.sort((a, b) => {
      if (a.depth !== b.depth) return a.depth - b.depth;
      return cmpNode(map.get(a.m), map.get(b.m));
    });
    return out;
  }

  // THE SINGLE SOURCE OF TRUTH.
  // paneCache: root -> the rows that pane WOULD show, honouring the checkbox.
  // visiblePanes(): those panes, further filtered by the CURRENT search term.
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
    const da = c.displayAddresses || '';
    code.textContent = c.mangled + (da === '' ? '' : ` (${da})`);
    code.title = 'Mangled name';
    span.appendChild(kind);
    span.appendChild(name);
    name.insertAdjacentHTML('afterend', '<br>');
    span.appendChild(code);
    return span;
  }

  // Nested mode renders the FULL subtree of a visible pane. The search term is
  // deliberately NOT applied per child: the spec selects panes.
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
            const da = r.c.displayAddresses || '';
            const baseNames = (r.c.bases || [])
              .map(nodeName)
              .filter(Boolean)
              .map(p => (da === '') ? p : p + ': (' + da + ')')
              .join('\n');
            if (baseNames) {
              const bs = document.createElement('pre');
              bs.className = 'bases';
              bs.textContent = baseNames;
              bs.insertAdjacentHTML('beforebegin',
                '<br><span class="bases">Directly inherits from:</span><br>');
              li.appendChild(bs);
            }
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

    // Counted from the DOM, so the figure is truthful in BOTH modes.
    stats.textContent = panes.length + ' top-level pane(s), ' +
      tree.querySelectorAll('.classLabel').length + ' rendered class(es)';
  }

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

-- ============================================================================
-- NAME COMMENTING
--   Disassembler mnemonics.lua writes the explanation inside 〈…〉.
--   This block adds the name as «name», AFTER your own notes, before 〈.
--
--   Layout:  <your notes>«name»〈explanation〉<tail>
--
--   « is C2 AB and » is C2 BB. Neither byte is E2, 8C or A9, so the mnemonics
--   file's [^〈] byte class captures the whole prefix including our block.
--   ⌦ (E2 8C A6) would not survive it. Lua strings are byte sequences, not
--   character sequences, which is why every marker search below is a plain
--   find with an explicit byte skip.
--
--   The 〈〉 anchor is created when absent: if that file finds no 〈 it falls
--   back to the literal "〈" and discards the entire prefix.
--
--   Load order: mnemonics first, then this file, then loadNames(path).
-- ============================================================================

local NO, NCL = '«', '»'
local EO, ECL = '〈', '〉'

local ncMap, ncCount = {}, 0
local ncLo, ncHi     = 0, -1
local ncBase, ncMod  = 0, ''
local ncRows         = {}
local ncPrev, ncInstalled = nil, false
local ncPid = getOpenedProcessID()

-- W: every address whose comment we have written. CE's comment store is DURABLE
-- and lives outside Lua, so clearing our tables does not remove what we wrote.
-- Kept in a global so a dofile() reload can still clean up the previous run.
local ncTouched = _G.ghidraLikeTouched
if type(ncTouched) ~= 'table' then ncTouched = {}; _G.ghidraLikeTouched = ncTouched end

-- The ORIGINAL non-ours handler, kept across reloads so re-attaching unwraps our
-- previous closure instead of chaining it.
local ncState = _G.ghidraLikeHookState
if type(ncState) ~= 'table' then ncState = {}; _G.ghidraLikeHookState = ncState end

-- Printable ASCII only: guarantees the byte-survival condition and stops a
-- name containing « or » from confusing our own parser. Capped at 96.
local function ncSanitise(s)
  s = tostring(s or '')
  local out = {}
  for i = 1, #s do
    local c = s:byte(i)
    if c >= 0x20 and c <= 0x7E then out[#out+1] = char(c) end
  end
  local t = table.concat(out):gsub('%s+', ' ')
  t = t:match('^%s*(.-)%s*$') or ''
  if #t > 96 then t = t:sub(1, 95) .. '+' end
  return t
end

-- Drop whole UTF-8 characters whose encoding contains E2, 8C or A9.
-- For a character occupying bytes b_1..b_k, keep it iff no b_i is in that set.
local function ncSanitisePrefix(s)
  if type(s) ~= 'string' then return '' end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local k = 1
    if     c >= 0xF0 then k = 4
    elseif c >= 0xE0 then k = 3
    elseif c >= 0xC0 then k = 2 end
    if i + k - 1 > n then break end
    local bad = false
    for j = i, i + k - 1 do
      local b = s:byte(j)
      if b == 0xE2 or b == 0x8C or b == 0xA9 then bad = true break end
    end
    if not bad then out[#out+1] = s:sub(i, i + k - 1) end
    i = i + k
  end
  return table.concat(out)
end

-- C = P · 〈 · E · 〉 · T
local function ncSplit(c)
  if type(c) ~= 'string' then return '', nil, '' end
  local a = find(c, EO, 1, true)
  if a == nil then return c, nil, '' end
  local p = c:sub(1, a - 1)
  local b = find(c, ECL, a + #EO, true)
  if b == nil then return p, c:sub(a + #EO), '' end
  return p, c:sub(a + #EO, b - 1), c:sub(b + #ECL)
end

local function ncStripName(s)
  if type(s) ~= 'string' then return '' end
  while true do
    local a = find(s, NO, 1, true)
    if a == nil then return s end
    local b = find(s, NCL, a + #NO, true)
    if b == nil then return s:sub(1, a - 1) end
    s = s:sub(1, a - 1) .. s:sub(b + #NCL)
  end
end

local function ncHasName(s)
  return type(s) == 'string' and find(s, NO, 1, true) ~= nil
end

-- Strip-then-append, so sigma(U·N) = U and the result is the same whether your
-- notes were typed before or after the previous name. Idempotent.
local function ncBuild(cur, name)
  local p, e, t = ncSplit(cur)
  local U = ncStripName(p)
  U = U:match('^%s*(.-)%s*$') or ''
  U = ncSanitisePrefix(U)
  -- CE feeds the comment back as description, so a stray copy of the name
  -- inside the explanation would otherwise be re-appended. Self-healing.
  local body = ncStripName(e or '')
  local N = ''
  if name and name ~= '' then
    N = (U ~= '' and ' ' or '') .. NO .. name .. NCL
  end
  return U .. N .. EO .. body .. ECL .. (t or '')
end

-- Apply sigma to every comment we touched. Removes «…» and leaves your notes,
-- the 〈…〉 explanation and the tail exactly as they are. An empty result clears
-- the comment. This is the ONLY thing that can undo a durable setComment.
local function ncPurge()
  local n = 0
  for a in pairs(ncTouched) do
    local okG, cur = pcall(getComment, a)
    if okG and type(cur) == 'string' and ncHasName(cur) then
      local want = ncStripName(cur)
      want = want:match('^%s*(.-)%s*$') or ''
      if want ~= cur then
        if pcall(setComment, a, want) then n = n + 1 end
      end
    end
  end
  ncTouched = {}
  _G.ghidraLikeTouched = ncTouched
  return n
end

local function ncSplitCsv(line)
  local out, i, n = {}, 1, #line
  while i <= n do
    if line:sub(i, i) == '"' then
      local buf = {}; i = i + 1
      while i <= n do
        local d = line:sub(i, i)
        if d == '"' then
          if line:sub(i + 1, i + 1) == '"' then buf[#buf+1] = '"'; i = i + 2
          else i = i + 1; break end
        else buf[#buf+1] = d; i = i + 1 end
      end
      out[#out+1] = table.concat(buf)
      if line:sub(i, i) == ',' then i = i + 1 end
    else
      local j = find(line, ',', i, true)
      if j == nil then out[#out+1] = line:sub(i); i = n + 1
      else out[#out+1] = line:sub(i, j - 1); i = j + 1 end
    end
  end
  return out
end

-- Accepts 20E7700, 0x20E7700, pes2021.exe+20E7700.
local function ncOffset(s)
  s = tostring(s or ''):match('^%s*(.-)%s*$')
  local plus = find(s, '+', 1, true)
  if plus then s = s:sub(plus + 1):match('^%s*(.-)%s*$') end
  s = s:gsub('^0[xX]', '')
  if s == '' or not s:match('^%x+$') then return nil end
  return tonumber(s, 16)
end


------------------------------------------------------------------ comment cache
-- Modelled on allDisassemblerNotes: key = address, validity = the disassembly
-- line, cleared on process change. A VERSION stamp is added because loading a
-- CSV changes the desired comment without changing the line.
--   NC_name  avoids recomputing the name.
--   NC_cmt   avoids getComment AND setComment on a repeat repaint.
local NC_version = 0
local NC_name, NC_nName = {}, 0
local NC_cmt,  NC_nCmt  = {}, 0

local function ncFlush()
  NC_name, NC_nName = {}, 0
  NC_cmt,  NC_nCmt  = {}, 0
  NC_version = NC_version + 1
end

local function ncCachedName(a, inst, compute)
  local e = NC_name[a]
  if e ~= nil and e.v == NC_version and (e.regs == false or e.inst == inst) then
    return e.name
  end
  local name, regsUsed = compute()
  if e == nil then NC_nName = NC_nName + 1 end
  NC_name[a] = { v = NC_version, inst = inst,
                 regs = regsUsed and true or false, name = name }
  return name
end

-- One place decides what a process change means: purge, then unload. No silent
-- rebasing -- a CSV belongs to one module in one process, and re-installing its
-- rows at a new base is how the old names survived into the new process.
local function ncCheckProcess()
  local pid = getOpenedProcessID()
  if pid == ncPid then return false end
  ncPid = pid
  ncState.pid = pid
  local removed = ncPurge()
  ncFlush()
  ncMap, ncCount, ncLo, ncHi = {}, 0, 0, -1
  ncBase, ncMod, ncRows = 0, '', {}
  unloadNames()                    -- clears the _annotate registry + its cache
  print(string.format(
    'ghidraLike: process changed - %d comment(s) cleaned, names unloaded', removed))
  return true
end

local function ncInstall(rows, b, mn)
  ncMap, ncCount, ncRows, ncBase, ncMod = {}, 0, rows, b, mn
  local lo, hi
  for i = 1, #rows do
    local a = b + rows[i][1]
    if ncMap[a] == nil then
      ncMap[a] = rows[i][2]; ncCount = ncCount + 1
      if lo == nil or a < lo then lo = a end
      if hi == nil or a > hi then hi = a end
    end
  end
  ncLo, ncHi = lo or 0, hi or -1

  -- Refresh the stamp HERE, so the first repaint after a load cannot mistake
  -- itself for a process change. This was the second print.
  ncPid = getOpenedProcessID()
  ncState.pid = ncPid
  ncFlush()

  -- Mirror into the registry _annotate reads. Without this, nmCount stayed 0
  -- and operand names never resolved. Sharing the table costs nothing.
  nmMap, nmCount, nmLo, nmHi = ncMap, ncCount, ncLo, ncHi
  nmCache, nmRegSig, nmRegTab = {}, nil, nil

  -- NO PRINT HERE. ncInstall has two callers; only ncLoad may print.
  return ncCount
end

local function ncSelf(a)
  if ncCount == 0 or type(a) ~= 'number' then return nil end
  if a < ncLo or a > ncHi then return nil end
  return ncMap[a]
end

local function ncAddr(a)
  if type(a) == 'number' then return a end
  if type(a) == 'string' then
    local ok, n = pcall(getAddress, a)
    if ok and type(n) == 'number' then return n end
    return tonumber(a, 16)
  end
  return nil
end

-- CE colour markup, observed as "[{R}rsp{N}+{H}18{N}],{R}rbx{N}".
local function ncMarkup(s)
  if type(s) ~= 'string' then return '' end
  return (s:gsub('{%a+}', ''))
end

local function ncPutName(line, nm)
  if type(line) ~= 'string' or nm == '' then return line end
  local sep = find(line, ' - ', 1, true)
  if sep == nil then return line .. ' ' .. nm end
  return line:sub(1, sep - 1) .. ' ' .. nm .. line:sub(sep)
end

local function ncHook(sender, address, LDD, result, description)
  ncCheckProcess()                 -- purge BEFORE anything writes

  local r, d = result, description
  if ncPrev then
    local ok, rr, dd = pcall(ncPrev, sender, address, LDD, result, description)
    if ok then r = rr or r; d = dd or d end
  end

  local a = (type(LDD) == 'table' and type(LDD.address) == 'number')
            and LDD.address or ncAddr(address)
  if a == nil then return r, d end

  -- Tier 2: no getComment and no setComment on a hit.
  local ce = NC_cmt[a]
  if ce ~= nil and ce.v == NC_version and ce.line == r then
    if ce.name then r = ncPutName(r, ce.name) end
    return r, d
  end

  local inst = ''
  if type(LDD) == 'table' and type(LDD.opcode) == 'string' then
    inst = LDD.opcode
    if type(LDD.parameters) == 'string' then inst = inst .. ' ' .. LDD.parameters end
    inst = ncMarkup(inst)
  end

  -- Tier 1. self(a) names the ADDRESS; _annotate names what it POINTS AT.
  -- Both are needed: a function-start row is found only by self().
  local nm = ncCachedName(a, inst, function()
    local s = ncSelf(a)
    local regsUsed = false
    if inst ~= '' then
      local ok, refs = pcall(_annotate, a, inst)
      if ok and type(refs) == 'string' and refs ~= '' then
        s = s and (s .. ' -> ' .. refs) or refs
      end
      local okB, brk = pcall(debug_isBroken)
      regsUsed = (okB and brk == true)
    end
    s = s and ncSanitise(s) or nil
    if s == '' then s = nil end
    return s, regsUsed
  end)

  local okG, cur = pcall(getComment, a)
  cur = (okG and type(cur) == 'string') and cur or ''

  local want
  if nm == nil and not ncHasName(cur) then
    want = cur                                    -- nothing of ours to touch
  elseif nm == nil then
    local p, e, t = ncSplit(cur)
    local U = ncSanitisePrefix((ncStripName(p):match('^%s*(.-)%s*$') or ''))
    if e == nil then want = U
    else want = U .. EO .. ncStripName(e) .. ECL .. (t or '') end
  else
    want = ncBuild(cur, nm)
  end

    if cur ~= want then
		if pcall(setComment, a, want) then ncTouched[a] = true end
    end

  if ce == nil then NC_nCmt = NC_nCmt + 1 end
  NC_cmt[a] = { v = NC_version, line = r, name = nm }

  if nm then r = ncPutName(r, nm) end
  return r, d
end

local function ncAttach()
  local v = getVisibleDisassembler()
  if v == nil then
    print('loadNames: open Memory View first, then call loadNames again')
    return false
  end
  local ok0, cur = pcall(function() return v.OnPostDisassemble end)
  if ok0 and cur == ncHook then return true end

  if ok0 and ncState.mine ~= nil and cur == ncState.mine then
    -- Our PREVIOUS closure is still installed. Reuse the original handler
    -- rather than chaining it, or the stale one keeps writing old names.
    ncPrev = ncState.orig
  else
    ncPrev = (ok0 and type(cur) == 'function') and cur or nil
    ncState.orig = ncPrev
  end
  ncState.mine = ncHook
  ncInstalled = true

  local ok = pcall(function() v.OnPostDisassemble = ncHook end)
  for _, m in ipairs({ 'repaint', 'Repaint', 'invalidate', 'Invalidate' }) do
    pcall(function() v[m]() end)
  end
  return ok
end

local function ncLoad(path, module)
  local fh, err = io.open(path, 'r')
  if fh == nil then
    print('loadNames: cannot open ' .. tostring(path) .. '  ' .. tostring(err))
    return 0
  end
  local mn, rows = module, {}
  for line in fh:lines() do
    local mc = line:match('^#module=(.+)$')
    if mc then
      if mn == nil then mn = mc:match('^%s*(.-)%s*$') end
    elseif line:sub(1, 1) ~= '#' and find(line, ',', 1, true) then
      local f = ncSplitCsv(line)
      local off, desc = ncOffset(f[1]), (f[2] or ''):match('^%s*(.-)%s*$')
      if f[1] == 'offset' or desc == 'desc' then
        -- column header
      elseif off ~= nil and desc ~= '' then
        rows[#rows+1] = { off, desc }
      end
    end
  end
  fh:close()

  if mn == nil or mn == '' then mn = ncMod end
  if mn == nil or mn == '' then mn = moduleName end
  if mn == nil or mn == '' then mn = process end
  if mn == nil then print('loadNames: no module name'); return 0 end
  if #rows == 0 then print('loadNames: no data rows in ' .. tostring(path)); return 0 end

  ncCheckProcess()                 -- clean the old process before installing

  local ok, b = pcall(getAddress, mn)
  if not ok or type(b) ~= 'number' then
    print('loadNames: cannot resolve module ' .. tostring(mn)); return 0
  end
  ncInstall(rows, b, mn)
  ncAttach()
  -- THE ONLY PRINT SITE.
  print(string.format('loadNames: %d names, %s base %X, range %X-%X',
    ncCount, tostring(mn), b, ncLo, ncHi))
  return ncCount
end


-- Reloaded after the process changed? The previous run's comments are still in
-- CE and its ncTouched survived in the global, so clean them now.
if ncState.pid ~= nil and ncState.pid ~= ncPid then
  ncPurge()
  ncFlush()
end
ncState.pid = ncPid

-- ============================================================================
-- PUBLIC API
-- ============================================================================
ghidraLike = {
  probe     = _probe,
  csv       = _csv,
  rtticsv   = _rtticsv,
  sections  = _sections,
  html      = _html,
  endWindow = _endWindow,
  namecsv   = _namecsv,
  nameAt    = function(a) local n = ncAddr(a); return n and ncSelf(n) or nil end,
  loadNames = ncLoad
}