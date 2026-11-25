-- ghidraLike.lua
-- FIX: "too many local variables" is Lua's 200-local limit for ONE function.
-- The main chunk is a function, so every file-scope `local` counts. The
-- compiler names the declaration that crosses the limit (ncSetProp), not the
-- cause. Sections whose helpers are used only within the section are now
-- wrapped in do...end, with forward declarations for the names other sections
-- need. Identifiers and behaviour are unchanged.

------------------------------------------------------------------ constants
local floor = math.floor
local find, byte, char = string.find, string.byte, string.char
local unpack = table.unpack or unpack
local loadstr = loadstring or load

local PADDING = { [0xCC]=true, [0x90]=true }

local NOPCORE = {
  {0x2E,0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00},
  {0x0F,0x1F,0x84,0x00,0x00,0x00,0x00,0x00},
  {0x0F,0x1F,0x80,0x00,0x00,0x00,0x00},
  {0x0F,0x1F,0x44,0x00,0x00},
  {0x0F,0x1F,0x40,0x00},
  {0x0F,0x1F,0x00}
}

local CHUNK         = 262144
local OVERLAP       = 32
local RTTI_NAME_MAX = 2048
local VTABLE_SLOTS  = 4096

local SRC = {
  PDATA='pdata', CALL='call', PAD='pad', ENTRY='entry', EXP='export',
  TLS='tls', CRT='crt', PTR='ptr', VTBL='vtable', XDATA='xdata',
  RVA='rva', CFG='cfg', DYN='dynamic', JUMP='jump', FRAG='fragment'
}

local TAGORDER = { 'pdata','cfg','export','tls','crt','entry','vtable','dynamic',
                   'call','rva','pad','ptr','xdata','fragment','jump' }

local CONF = {
  [SRC.PDATA]=4, [SRC.CFG]=4, [SRC.EXP]=4, [SRC.TLS]=4, [SRC.CRT]=4, [SRC.ENTRY]=4,
  [SRC.VTBL]=3, [SRC.DYN]=3,
  [SRC.CALL]=2,
  [SRC.RVA]=1, [SRC.PAD]=1, [SRC.PTR]=1, [SRC.XDATA]=1, [SRC.FRAG]=1,
  [SRC.JUMP]=0
}

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

local DD = { EXPORT=0, IMPORT=1, RESOURCE=2, EXCEPTION=3, CERT=4,
             RELOC=5, DEBUG=6, TLS=9, LOADCFG=10 }

local MEM_COMMIT = 0x1000
local PAGE_EXEC  = { [0x10]=true, [0x20]=true, [0x40]=true, [0x80]=true }

local moduleName = ''
local moduleBase = 0

local function addressOffset(a)
  return getNameFromAddress(a, true, false, true)
end

local function hasBit(v, m)
  if type(v) ~= 'number' then return false end
  return floor(v / m) % 2 == 1
end

local function hasAll(v, ms)
  for i = 1, #ms do if not hasBit(v, ms[i]) then return false end end
  return true
end

local function cnt(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local function normAddr(a)
  if type(a) ~= 'number' then return nil end
  if a ~= a then return nil end
  if a == math.huge or a == -math.huge then return nil end
  local f = floor(a)
  if f ~= a then return nil end
  return f
end


------------------------------------------------------------------ progress window
local gl_open, gl_phase, gl_progress, gl_close, gl_yield
do
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

  local function gl_labelExtent(l)
    local w = tonumber(l.Width) or 0
    local h = tonumber(l.Height) or 0
    if w > 1 and h > 1 then return w, h end
    local caption = ''
    pcall(function() caption = tostring(l.Caption or '') end)
    local n = #caption
    if w <= 1 then w = math.max(520, n * 8) end
    if h <= 1 then h = 20 end
    return w, h
  end

  local function gl_fit()
    if gl_w[1] == nil or gl_w[2] == nil then return end
    local f, l = gl_w[1], gl_w[2]
    pcall(function() l.AutoSize = true end)
    pcall(function() l.WordWrap = false end)
    local lw, lh = gl_labelExtent(l)
    local padX, padY = 16, 16
    local wantW = (tonumber(l.Left) or 0) + lw + padX
    local wantH = (tonumber(l.Top) or 0) + lh + padY
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

  function gl_open(title)
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

  function gl_phase(p)
    if gl_w[2] == nil then return end
    gl_w[2].Caption = p
    gl_fit()
  end

  function gl_progress(done, total, unit)
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

  function gl_close()
    local f = gl_w[1]
    gl_w[1], gl_w[2] = nil, nil
    gl_lastW, gl_lastH = 0, 0
    if f ~= nil then pcall(function() f.destroy() end) end
  end

  function gl_yield()
    coroutine.yield()
  end
end


------------------------------------------------------------------ byte readers
local rd16, rd32, rd64, ptrFromChunk
do
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

  rd16 = function(a) return rd(2, a) end
  rd32 = function(a) return rd(4, a) end
  rd64 = function(a) return rd(8, a) end

  function ptrFromChunk(b, i, psz)
    if b == nil or i < 1 or i + psz - 1 > #b then return nil end
    local v = 0
    for k = i + psz - 1, i, -1 do
      local x = b[k]
      if x == nil then return nil end
      v = V256 * v + x
    end
    return v
  end
end

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
local peInfo, secSize, execSections, secSpans, dataRanges
do
  local function ddAddr(pe, idx)
    local d = pe.dd[idx]
    if d == nil or d.rva == nil or d.rva == 0 or d.size == nil or d.size == 0 then
      return nil, nil
    end
    return pe.base + d.rva, d.size
  end

  function peInfo(base)
    base = normAddr(base)
    if base == nil then return nil end

    local e_lfanew = rd32(base + 0x3C)
    if e_lfanew == nil or e_lfanew < 0x40 or e_lfanew > 0x100000 then return nil end
    local nt = base + e_lfanew
    if rd32(nt) ~= 0x00004550 then return nil end

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

  function secSize(s)
    local sz = 0
    if s.vsz and s.vsz > 0 then sz = s.vsz
    elseif s.rawsz and s.rawsz > 0 then sz = s.rawsz end
    if sz > 0x20000000 then sz = 0x20000000 end
    return sz
  end

  function execSections(pe, base, modSize)
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

  function secSpans(pe, pats)
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

  function dataRanges(pe)
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

  -- exposed for the RTTI range builder below
  _G.__glSpansToRanges = spansToRanges
end
local spansToRanges = _G.__glSpansToRanges
_G.__glSpansToRanges = nil


------------------------------------------------------------------ small helpers
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

local function demangle(m)
  if m == nil then return nil, nil end
  local k, name = m:match('^%.%?A([VUWT])(.+)$')
  if k == nil then return nil, m end
  name = name:gsub('@@$', '')
  return ({ V='class', U='struct', W='enum', T='union' })[k] or '?', name
end


------------------------------------------------------------------ NAME REGISTRY
local nmAddr, nmDesc, nmSeen, nmHex = {}, {}, {}, {}
local nmBase, nmModule = 0, ''

local function addName(a, desc, useHex)
  if useHex ~= true then useHex = false end
  if type(a) ~= 'number' or desc == nil or desc == '' then return end
  local f = floor(a)
  if f ~= a or f <= 0 then return end
  if nmSeen[f] then return end
  nmSeen[f] = true
  nmAddr[#nmAddr+1] = f
  nmDesc[#nmDesc+1] = desc
  nmHex[#nmHex+1] = useHex
end

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
local roots, callers = {}, {}
local curSecs = {}
local EXLO, EXHI = 0, -1

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
  if floor(mask / bit) % 2 == 0 then mask = mask + bit end
  if cf > conf then conf = cf end
  roots[a] = conf * CONFSHIFT + mask
  return true
end


------------------------------------------------------------------ chunk walker
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
local pdStart, pdEnd, pdChained = {}, {}, {}

local function srcPdata(pe, chainCheck)
  pdStart, pdEnd, pdChained = {}, {}, {}
  local addr, size = pe.dd[DD.EXCEPTION].rva, pe.dd[DD.EXCEPTION].size
  if addr == nil or addr == 0 or size == nil or size == 0 or not pe.is64 then return 0 end
  addr = pe.base + addr

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
      if bg ~= 0 and en > bg then
        local lo = base + bg
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
local function sweepChunk(a, len, have, b, s, withJumps)
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
    pos = i + 1
  end

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

local function srcExports(pe)
  local d = pe.dd[DD.EXPORT]
  if d.rva == nil or d.rva == 0 or d.size == nil or d.size == 0 then return 0 end
  local addr, size = pe.base + d.rva, d.size

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

local function srcTLS(pe)
  local d = pe.dd[DD.TLS]
  if d.rva == nil or d.rva == 0 or d.size == nil or d.size == 0 then return 0 end
  local addr, size = pe.base + d.rva, d.size
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
      if q ~= nil and q ~= 0 and propose(q, SRC.CRT) then
        n = n + 1
        addName(q, 'CRT_initialiser' .. n .. ' (global constructor)')
      end
    end
  end, 'bytes (S7 CRT initialisers)')
  return n
end

local function srcCFG(pe)
  local d = pe.dd[DD.LOADCFG]
  if d.rva == nil or d.rva == 0 then return 0 end
  local addr = pe.base + d.rva
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

  local stride = 4 + (floor(flags / 268435456) % 16)
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
local function scanPtrs(pe, ranges)
  local is64 = pe.is64
  local psz = is64 and 8 or 4
  local n = 0
  local fast, U4, U5 = false, 0, 0
  if is64 then
    local ulo, uhi = floor(EXLO / 4294967296), floor(EXHI / 4294967296)
    if ulo == uhi then fast = true; U4 = ulo % 256; U5 = floor(ulo / 256) % 256 end
  end
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
local cols, hierarch, vtblMap, funcToClass = {}, {}, {}, {}
local bcdTypeName
do
  local function ptrRef(pe, v)
    if v == nil then return nil end
    if pe.is64 then return pe.base + v end
    return v
  end

  local function asSigned32(v)
    if v >= 0x80000000 then return v - 0x100000000 end
    return v
  end

  function bcdTypeName(pe, bcdVA, nameOff)
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

  _G.__glPtrRef = ptrRef
  _G.__glSigned32 = asSigned32
end
local ptrRef, asSigned32 = _G.__glPtrRef, _G.__glSigned32
_G.__glPtrRef, _G.__glSigned32 = nil, nil


local function scanCols(pe, ranges, strict)
  local base, size, is64 = pe.base, pe.size, pe.is64
  local nameOff = is64 and 0x10 or 0x08
  local sig = is64 and 1 or 0
  local need = (is64 and strict) and 24 or 20

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
    local lim = math.min(len, have - (need - 1))
    for k = 1, lim, 4 do
      if b[k] == sig and b[k+1] == 0 and b[k+2] == 0 and b[k+3] == 0 then
        local tb = b[k+15]
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
                  local kd = demangle(nm)
                  local hx = (kd ~= nil)
                  local short = symbolShort(nm)
                  addName(col, short .. ' (COL)', true)
                  addName(tdVA, short .. ' (' ..
                    (kd and (kd:sub(1,1):upper() .. kd:sub(2)) or 'Type') .. ')', hx)
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
        local c = cols[q]
        if c ~= nil then
          local vslot = a + k - 1 + psz
          vtblMap[vslot] = { colAddr = q, className = c.tdName }
          addName(vslot, symbolShort(c.tdName) .. ' (vfTable)', true)
          walkVtable(pe, vslot, c.tdName)
          nv = nv + 1
        end
      end
    end
  end, 'bytes (RTTI vtable walk)')
  return nv
end

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
local fStart, fEnd, fMask, fConf, fCallers, fKind = {}, {}, {}, {}, {}, {}
local confA, confB = {}, {}

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
        kv = 0
      else
        kv = 2
        nNested = nNested + 1
        confA[#confA + 1], confB[#confB + 1] = pdStart[p], st
      end
    else
      en, kv = limit, 0
    end

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


------------------------------------------------------------------ comment cache
-- ONE table instead of five separate locals.
local NC = { version = 0, name = {}, nName = 0, cmt = {}, nCmt = 0 }

local NO, NCL = '«', '»'
local EO, ECL = '〈', '〉'

local ncTouched = _G.ghidraLikeTouched
if type(ncTouched) ~= 'table' then
  ncTouched = {}
  _G.ghidraLikeTouched = ncTouched
end

local function ncFlush()
  NC.name, NC.nName = {}, 0
  NC.cmt,  NC.nCmt  = {}, 0
  NC.version = NC.version + 1
end

local function ncStripName(s)
  if type(s) ~= 'string' then return '' end
  for _, pair in ipairs({ {NO, NCL}, {'⌦', '⌫'} }) do
    local O, C = pair[1], pair[2]
    while true do
      local a = find(s, O, 1, true)
      if a == nil then break end
      local b = find(s, C, a + #O, true)
      if b == nil then s = s:sub(1, a - 1); break end
      s = s:sub(1, a - 1) .. s:sub(b + #C)
    end
  end
  return s
end

local function ncHasName(s)
  return type(s) == 'string' and find(s, NO, 1, true) ~= nil
end

local function ncPurge()
  local touched = ncTouched
  if type(touched) ~= 'table' then
    ncTouched = {}
    _G.ghidraLikeTouched = ncTouched
    return 0
  end
  local n = 0
  local addrs = {}
  for a in pairs(touched) do addrs[#addrs + 1] = a end
  for i = 1, #addrs do
    local a = addrs[i]
    local okG, cur = pcall(getComment, a)
    if okG and type(cur) == 'string' and ncHasName(cur) then
      local want = ncStripName(cur)
      want = want:match('^%s*(.-)%s*$') or ''
      if want ~= cur then
        if pcall(setComment, a, want) then n = n + 1 end
      end
    end
  end
  for a in pairs(touched) do touched[a] = nil end
  _G.ghidraLikeTouched = touched
  ncTouched = touched
  return n
end


------------------------------------------------------------------ DRIVER
local gl_co, gl_tmr, gl_busy = nil, nil, false
local lastStat = nil

local function gl_stop(err, stat)
  if gl_tmr then pcall(function() gl_tmr.destroy() end); gl_tmr = nil end
  gl_co = nil
  gl_close()
  roots, callers = {}, {}
  pdStart, pdEnd, pdChained = {}, {}, {}
  cols = {}
  collectgarbage('collect')
  if err then
    print('ghidraLike failed: ' .. tostring(err))
    return
  end
  if stat then
    lastStat = stat
    print(string.format(
      'functions=%d  exact=%d  nested=%d  authoritative=%d  guessed-extent bytes=%d',
      stat.nfuncs, stat.exact, stat.nested, stat.auth, stat.guessed))
    print(string.format('names retained: %d', #nmAddr))
  end
  print('Done!')
end

local function _endWindow()
  gl_stop()
end

local function _probe()
  ncPurge()
  ncFlush()
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
  nmAddr, nmDesc, nmSeen, nmHex = {}, {}, {}, {}
  nmBase, nmModule = 0, ''
  lastStat = nil

  gl_open('ghidraLike - ' .. tostring(module0))

  gl_co = coroutine.create(function()
    local base = normAddr(getAddress(module0))
    if base == nil then
      error('getAddress("' .. tostring(module0) .. '") returned no address')
    end
    moduleBase = base
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
local csvEsc
do
  local function hasTag(mask, tag) return floor(mask / TAGBIT[tag]) % 2 == 1 end

  local function tagsOf(mask)
    local t = {}
    for i = 1, #TAGORDER do
      if hasTag(mask, TAGORDER[i]) then t[#t+1] = TAGORDER[i] end
    end
    return t
  end

  local function statusOf(kv, conf)
    if kv == 2 then return 'nested' end
    if conf >= 3 then return 'authoritative' end
    return 'included'
  end

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

  function csvEsc(s)
    s = tostring(s or '')
    if s:find('[",\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
  end

  local function sortedKeys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks+1] = k end
    table.sort(ks)
    return ks
  end

  _G.__glCsv = function(path)
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

  _G.__glRttiCsv = function(path)
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
end
local _csv, _rtticsv = _G.__glCsv, _G.__glRttiCsv
_G.__glCsv, _G.__glRttiCsv = nil, nil


------------------------------------------------------------------ NAMES
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
  fh:write('offset,desc,hex\n')
  for k = 1, #idx do
    local i = idx[k]
    fh:write(string.format('%X', nmAddr[i] - base) .. ','
      .. csvEsc(nmDesc[i]) .. ',' .. (nmHex[i] and '1' or '0') .. '\n')
  end
  fh:close()
  print('wrote ' .. tostring(path) .. ' (' .. #idx .. ' named addresses)')
end


------------------------------------------------------------------ lookup
local nmMap, nmCount = {}, 0
local nmLo, nmHi = 0, -1
local nmCache = {}
local nmRegSig, nmRegTab = nil, nil
local nmRegs

do
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
  _G.__glSplitCsv = nmSplitCsv
end

local function unloadNames()
  nmMap, nmCount, nmCache = {}, 0, {}
  nmLo, nmHi, nmRegSig, nmRegTab = 0, -1, nil, nil
end


------------------------------------------------------------------ registers
do
  local NRFAM = {'RAX','RBX','RCX','RDX','RSI','RDI','RBP','RSP','RIP',
                 'R8','R9','R10','R11','R12','R13','R14','R15'}
  local NRALIAS = {}
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

  function nmRegs()
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

  local function nmExpr(text, R)
    local parts, pos, n = {}, 1, #text
    local sawReg = false
    while pos <= n do
      local c = text:sub(pos,pos)
      if c:match('[%a_]') then
        local wd = text:match('^[%a_][%w_%.]*', pos)
        local up = wd:upper()
        if NRALIAS[up] then
          sawReg = true
          local v = R and R[up]
          if v == nil then return true, nil end
          parts[#parts+1] = string.format('%.0f', v)
        elseif wd:match('^%x+$') then
          parts[#parts+1] = '0x' .. wd
        else
          return sawReg, nil
        end
        pos = pos + #wd
      elseif c:match('%x') then
        local wd = text:match('^%x+', pos)
        parts[#parts+1] = '0x' .. wd
        pos = pos + #wd
      elseif c:match('[%+%-%*%(%)%s]') then
        parts[#parts+1] = c
        pos = pos + 1
      else
        return sawReg, nil
      end
    end
    return sawReg, table.concat(parts)
  end

  local function nmSym(text)
    local ok, a = pcall(getAddress, text)
    if ok and type(a) == 'number' then return a end
    local lhs, off = text:match('^(.-)%+([%x]+)$')
    if lhs and off then
      local ok2, bb = pcall(getAddress, lhs)
      if ok2 and type(bb) == 'number' then return bb + tonumber(off, 16) end
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

  _G.__glResolve = nmResolve
end
local nmResolve = _G.__glResolve
_G.__glResolve = nil


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
  local useQword = not inst:lower():find('dword ptr', 1, true)

  local nbr = 0
  for br in inst:gmatch('%b[]') do
    nbr = nbr + 1
    local a, ur = nmResolve(br:sub(2, -2), R)
    usedRegs = usedRegs or ur
    if a then
      add(a)
      if isCtl then
        local ok, t
        if useQword then ok, t = pcall(readQword, a) else ok, t = pcall(readInteger, a) end
        if ok and type(t) == 'number' then add(t, ' (indirect target)') end
      end
    end
  end

  if nbr == 0 then
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
      hasBit(c, SCN.CODE)      and 'CODE '  or '',
      hasBit(c, SCN.MEM_EXEC)  and 'EXEC '  or '',
      hasBit(c, SCN.MEM_WRITE) and 'WRITE' or ''))
  end
end


------------------------------------------------------------------ JSON + HTML
local _html
do
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

  function _html(path)
    local fh = io.open(path, 'w')
    if fh == nil then print('cannot open ' .. tostring(path)); return end

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
        mangled = m, name = name or m, kind = kind or 'type',
        bases = bases, attrs = h and h.attrs or nil
      }
      if mdr ~= nil then
        rec.addrs_col      = mdr.col and addressOffset(mdr.col) or nil
        rec.addrs_vftables = relList(mdr.vftables)
        rec.addrs_methods  = relList(mdr.methods)
      end
      classes[#classes + 1] = rec
    end
    table.sort(classes, function(a, b) return a.mangled < b.mangled end)

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
  --bg: #ffffff; --fg: #111111; --muted: #666666;
  --line: #dddddd; --pane: #f7f7f7; --accent: #0b5fbf;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111111; --fg: #eeeeee; --muted: #aaaaaa;
    --line: #333333; --pane: #1b1b1b; --accent: #7cc4ff;
  }
}
body { margin:0; font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,Arial,sans-serif;
       background:var(--bg); color:var(--fg); }
header { position:sticky; top:0; z-index:2; background:var(--bg);
         border-bottom:1px solid var(--line); padding:10px 14px; }
h1 { font-size:18px; margin:0 0 8px 0; }
.toolbar { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
.toolbar input[type="search"] { min-width:260px; padding:6px 8px;
  border:1px solid var(--line); border-radius:6px; background:var(--pane); color:var(--fg); }
.toolbar label, .toolbar button { border:1px solid var(--line); border-radius:6px;
  padding:6px 8px; background:var(--pane); color:var(--fg); cursor:pointer; user-select:none; }
.toolbar button:hover { border-color:var(--accent); }
#stats { color:var(--muted); margin-left:auto; white-space:nowrap; }
main { padding:12px 14px 40px 14px; }
details.rootPane { border:1px solid var(--line); border-radius:8px; margin:8px 0;
  background:var(--pane); overflow:hidden; }
details.rootPane > summary { cursor:pointer; padding:9px 10px; font-weight:600;
  list-style:none; display:flex; gap:8px; align-items:center; flex-wrap:wrap; }
details.rootPane > summary::-webkit-details-marker { display:none; }
details.rootPane[open] > summary { border-bottom:1px solid var(--line); }
.classLabel { display:inline-flex; gap:6px; align-items:baseline; flex-wrap:wrap; }
.classLabel .kind { font-size:11px; text-transform:uppercase; letter-spacing:0.04em;
  color:var(--accent); border:1px solid currentColor; border-radius:999px; padding:1px 6px; }
.classLabel code { font-weight:400; color:var(--muted); font-size:12px; }
.count { color:var(--muted); font-weight:400; font-size:12px; }
pre.bases { white-space:pre-wrap; margin:4px 0; font:inherit; }
ul.descList { margin:0; padding:8px 10px 10px 10px; list-style:none; }
ul.descList li { padding:3px 0 3px calc(var(--depth) * 18px);
  border-left:1px dashed var(--line); margin-left:4px; }
ul.descList li .bases { color:var(--muted); font-size:12px; margin-left:6px; }
ul.descList li.match { background:rgba(11,95,191,.12); }
.nested { padding:8px 10px 10px 22px; }
.nested details { margin:4px 0; border-left:1px dashed var(--line); padding-left:8px; }
.nested summary { cursor:pointer; }
.cycle, .empty { color:var(--muted); font-style:italic; padding:4px 0; }
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

    fh:write([==[
</script>
<script>
(() => {
  const data = JSON.parse(document.getElementById('class-data').textContent || '{}');
  const map = new Map();

  function addressText(c) {
    let t = '';
    const vf = Array.isArray(c.vftables) ? c.vftables : [];
    const me = Array.isArray(c.methods) ? c.methods : [];
    if (vf.length > 0) {
      t += vf.length === 1 ? `vftables: "${vf[0]}", `
                           : `vftables: ["${vf.join('", "')}"], `;
    }
    if (typeof c.col !== 'undefined' && c.col !== '') { t += `COL: "${c.col}", `; }
    if (me.length > 0) {
      t += me.length === 1 ? `Methods: "${me[0]}", `
                           : `Methods: ["${me.join('", "')}"], `;
    }
    return t.endsWith(', ') ? t.slice(0, -2) : t;
  }

  for (const c of data.classes || []) {
    map.set(c.mangled, {
      mangled: c.mangled, name: c.name || c.mangled, kind: c.kind || 'type',
      bases: Array.isArray(c.bases) ? c.bases.slice() : [],
      attrs: c.attrs, unknown: false,
      vftables: c.vftables || [], methods: c.methods || [], col: c.col || '',
      displayAddresses: addressText(c)
    });
  }

  function ensure(m) {
    if (!map.has(m)) {
      map.set(m, { mangled:m, name:m, kind:'unknown', bases:[], unknown:true,
                   vftables:[], methods:[], col:'', displayAddresses:'' });
    }
    return map.get(m);
  }

  for (const c of Array.from(map.values())) {
    const seen = new Set(); const bs = [];
    for (const b of c.bases) {
      if (b === c.mangled) continue;
      const node = ensure(b);
      if (!seen.has(node.mangled)) { seen.add(node.mangled); bs.push(node.mangled); }
    }
    c.bases = bs;
  }

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

  const roots = Array.from(map.values()).filter(c => c.bases.length === 0).sort(cmpNode);
  const $ = id => document.getElementById(id);
  const tree = $('tree'); const stats = $('stats');
  if (!tree) { return; }

  function nodeName(m) { const c = map.get(m); return c ? c.name : m; }

  const hayCache = new Map();
  function rowHaystack(c) {
    if (!c) return '';
    const cached = hayCache.get(c.mangled);
    if (cached !== undefined) return cached;
    const bases = (c.bases || []).map(nodeName).filter(Boolean).join(',\n');
    const hay = (String(c.name||'') + '\n' + String(c.mangled||'') + '\n' + bases).toLowerCase();
    hayCache.set(c.mangled, hay);
    return hay;
  }
  function rowMatches(c, term) {
    if (!term) return true;
    return rowHaystack(c).indexOf(term) !== -1;
  }

  function descendants(rootM) {
    const out = []; const seen = new Set([rootM]); const q = [];
    for (const m of children.get(rootM) || []) {
      if (!seen.has(m)) q.push({ m: m, depth: 1 });
    }
    for (let i = 0; i < q.length; i++) {
      const item = q[i];
      if (seen.has(item.m)) continue;
      seen.add(item.m); out.push(item);
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

  let paneCache = null, paneCacheKey = null;
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
      paneCache = buildPaneCache(showUnknown); paneCacheKey = showUnknown;
    }
    const out = [];
    for (const root of roots) {
      const rows = paneCache.get(root.mangled);
      if (rows === undefined) continue;
      if (term) {
        let hit = false;
        for (const r of rows) { if (rowMatches(r.c, term)) { hit = true; break; } }
        if (!hit) continue;
      }
      out.push({ root: root, rows: rows });
    }
    return out;
  }

  function classLabel(c) {
    const span = document.createElement('span'); span.className = 'classLabel';
    const kind = document.createElement('span'); kind.className = 'kind';
    kind.textContent = c.kind || 'type';
    const name = document.createElement('strong'); name.textContent = c.name || c.mangled;
    const code = document.createElement('code');
    const da = c.displayAddresses || '';
    code.textContent = c.mangled + (da === '' ? '' : ` (${da})`);
    code.title = 'Mangled name';
    span.appendChild(kind); span.appendChild(name);
    name.insertAdjacentHTML('afterend', '<br>');
    span.appendChild(code);
    return span;
  }

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
        div.className = 'cycle'; div.textContent = 'cycle: ' + c.name;
        frag.appendChild(div); continue;
      }
      const det = document.createElement('details');
      const sum = document.createElement('summary');
      sum.appendChild(classLabel(c)); det.appendChild(sum);
      const p2 = new Set(path); p2.add(kid);
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
      const root = pane.root; const rows = pane.rows;
      const det = document.createElement('details'); det.className = 'rootPane';
      const sum = document.createElement('summary');
      sum.appendChild(classLabel(root));
      const cnt = document.createElement('span'); cnt.className = 'count';
      if (flat) {
        const n = rows.length - 1;
        cnt.textContent = n + ' descendant' + (n === 1 ? '' : 's');
      } else {
        const direct = (children.get(root.mangled) || [])
          .filter(m => { const c = map.get(m); return c && (showUnknown || !c.unknown); }).length;
        cnt.textContent = direct + ' direct child' + (direct === 1 ? '' : 'ren');
      }
      sum.appendChild(cnt); det.appendChild(sum);

      if (flat) {
        const ul = document.createElement('ul'); ul.className = 'descList';
        if (rows.length === 1) {
          const li = document.createElement('li');
          li.className = 'empty'; li.textContent = 'No descendants.';
          ul.appendChild(li);
        } else {
          for (let i = 1; i < rows.length; i++) {
            const r = rows[i];
            const li = document.createElement('li');
            li.style.setProperty('--depth', String(r.depth));
            li.appendChild(classLabel(r.c));
            const da = r.c.displayAddresses || '';
            const baseNames = (r.c.bases || []).map(nodeName).filter(Boolean)
              .map(p => (da === '') ? p : p + ': (' + da + ')').join('\n');
            if (baseNames) {
              const bs = document.createElement('pre');
              bs.className = 'bases'; bs.textContent = baseNames;
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
        const holder = document.createElement('div'); holder.className = 'nested';
        const frag = renderNested(root.mangled, new Set([root.mangled]));
        if (!frag.hasChildNodes()) {
          const e = document.createElement('div');
          e.className = 'empty'; e.textContent = 'No descendants.';
          holder.appendChild(e);
        }
        holder.appendChild(frag); det.appendChild(holder);
      }
      tree.appendChild(det);
    }

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
end


------------------------------------------------------------------ NAME COMMENTING
local ncMap, ncCount = {}, 0
local ncLo, ncHi     = 0, -1
local ncBase, ncMod  = 0, ''
local ncRows         = {}
local ncRefs         = {}
local ncPrev = nil
local ncPid = getOpenedProcessID()

local ncState = _G.ghidraLikeHookState
if type(ncState) ~= 'table' then ncState = {}; _G.ghidraLikeHookState = ncState end

local ncBuildIndex, ncAttachNameMenu, ncLoad, ncCloseNameList, hlFlush

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

local function ncMarkup(s)
  if type(s) ~= 'string' then return '' end
  return (s:gsub('{%a+}', ''))
end

local function ncOffset(s)
  s = tostring(s or ''):match('^%s*(.-)%s*$')
  local plus = find(s, '+', 1, true)
  if plus then s = s:sub(plus + 1):match('^%s*(.-)%s*$') end
  s = s:gsub('^0[xX]', '')
  if s == '' or not s:match('^%x+$') then return nil end
  return tonumber(s, 16)
end

local function ncCachedName(a, inst, compute)
  local e = NC.name[a]
  if e ~= nil and e.v == NC.version and (e.regs == false or e.inst == inst) then
    return e.name
  end
  local name, regsUsed = compute()
  if e == nil then NC.nName = NC.nName + 1 end
  NC.name[a] = { v = NC.version, inst = inst,
                 regs = regsUsed and true or false, name = name }
  return name
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
  ncPid = getOpenedProcessID()
  ncState.pid = ncPid
  ncFlush()
  ncRefs = {}
  nmMap, nmCount, nmLo, nmHi = ncMap, ncCount, ncLo, ncHi
  nmCache, nmRegSig, nmRegTab = {}, nil, nil
  ncPurge()
  return ncCount
end

local function ncCheckProcess()
  local pid = getOpenedProcessID()
  if pid == ncPid then return false end
  ncPid = pid
  ncState.pid = pid
  local removed = ncPurge()
  ncFlush()
  if hlFlush then hlFlush() end          -- guarded: assigned later in the file
  ncRefs = {}
  ncMap, ncCount, ncLo, ncHi = {}, 0, 0, -1
  ncBase, ncMod, ncRows = 0, '', {}
  unloadNames()
  if ncCloseNameList then ncCloseNameList() end
  if ncBuildIndex then ncBuildIndex() end
  --print(string.format('ghidraLike: process changed - %d comment(s) cleaned, names unloaded', removed))
  return true
end


------------------------------------------------------------------ highlight
local hlAttach, hlLabelFor, ncPutName
do
  local HL_COLOR     = 0x34FF3B  -- THE one colour, 0xBBGGRR (Lazarus TColor)
  local HL_BG        = 0x222222
  local HL_LABELS    = true       -- false = solid one-colour bar, no text
  local HL_MAX       = 256
  local HL_MAXW      = 900
  local HL_LINE_NAME = false

  local hlState = _G.ghidraLikeHighlight
  if type(hlState) ~= 'table' then hlState = {}; _G.ghidraLikeHighlight = hlState end
  if type(hlState.cache) ~= 'table' then hlState.cache = {} end

  local hlCache = hlState.cache
  local hlCount = 0
  local hlLabel = {}
  local hlView  = nil

  function hlFlush()
    for k, b in pairs(hlCache) do
      pcall(function() b.destroy() end)
      hlCache[k] = nil
    end
    hlCount = 0
    for k in pairs(hlLabel) do hlLabel[k] = nil end
  end

  hlFlush()

  local function hlBitmap(label)
    local key = HL_LABELS and label or '*'
    local b = hlCache[key]
    if b ~= nil then return b end

    if HL_MAX > 0 and hlCount >= HL_MAX then
      for k, old in pairs(hlCache) do
        pcall(function() old.destroy() end)
        hlCache[k] = nil
      end
      hlCount = 0
    end

    local ok, bmp = pcall(createBitmap)
    if not ok or bmp == nil then return nil end

    local w, h
    if HL_LABELS then
      w = 20 + #label * 7
      if w > HL_MAXW then w = HL_MAXW end
      h = 16
    else
      w, h = 350, 3
    end

    local okInit = pcall(function()
      bmp.PixelFormat = 'pf24bit'
      bmp.Width, bmp.Height = w, h
      local c = bmp.Canvas
      c.Brush.Style = 'bsSolid'
      if HL_LABELS then
        c.Brush.Color = HL_BG
        c.FillRect(0, 0, w, h)
        c.Brush.Color = HL_COLOR
        c.FillRect(0, 0, 6, h)
        c.Brush.Style = 'bsClear'
        c.Font.Name   = 'Consolas'
        c.Font.Height = -12
        c.Font.Style  = '[fsBold]'
        c.Font.Color  = HL_COLOR
        c.TextOut(12, 1, label)
      else
        c.Brush.Color = HL_COLOR
        c.FillRect(0, 0, w, h)
      end
    end)

    if not okInit then
      pcall(function() bmp.destroy() end)
      return nil
    end

    hlCache[key] = bmp
    hlCount = hlCount + 1
    return bmp
  end

  function hlLabelFor(a)
    local s = hlLabel[a]
    if s ~= nil then return s ~= '' and s or nil end
    local self = ncSelf(a)
    local refs = ncRefs[a]
    local t
    if self and refs then t = self .. ' -> ' .. refs
    else t = self or refs end
    t = t and ncSanitise(t) or ''
    hlLabel[a] = t
    return t ~= '' and t or nil
  end

  local function ncRender(sender, Address, AboveInstruction, Selected)
    if not AboveInstruction then return nil end
    if ncCount == 0 then return nil end
    local a = normAddr(Address)
    if a == nil then return nil end
    local label = hlLabelFor(a)
    if label == nil then return nil end
    local bmp = hlBitmap(label)
    if bmp == nil then return nil end
    return bmp, 0, 0
  end

  function hlAttach()
    local ok, dv = pcall(function() return getMemoryViewForm().DisassemblerView end)
    if not ok or dv == nil then
      print('ghidraLike: open Memory View first, then call loadNames again')
      return false
    end
    hlView = dv
    local okSet = pcall(function() dv.OnExtraLineRender = ncRender end)
    pcall(function() dv.update() end)
    return okSet
  end

  function ncPutName(line, nm)
    if type(line) ~= 'string' or nm == '' then return line end
    local sep = find(line, ' - ', 1, true)
    if sep == nil then return line .. ' ' .. nm end
    return line:sub(1, sep - 1) .. ' ' .. nm .. line:sub(sep)
  end

  _G.__glHlLineName = function() return HL_LINE_NAME end
  _G.__glHlView     = function() return hlView end
  _G.__glHlClear    = function(a) hlLabel[a] = nil end
end
local hlLineName, hlViewOf, hlClear = _G.__glHlLineName, _G.__glHlView, _G.__glHlClear
_G.__glHlLineName, _G.__glHlView, _G.__glHlClear = nil, nil, nil


------------------------------------------------------------------ refs-only hook
local function ncHook(sender, address, LDD, result, description)
  ncCheckProcess()
  local r, d = result, description
  if ncPrev then
    local ok, rr, dd = pcall(ncPrev, sender, address, LDD, result, description)
    if ok then r = rr or r; d = dd or d end
  end

  local a = (type(LDD) == 'table' and type(LDD.address) == 'number')
            and LDD.address or ncAddr(address)
  if a == nil then return r, d end

  local inst = ''
  if type(LDD) == 'table' and type(LDD.opcode) == 'string' then
    inst = LDD.opcode
    if type(LDD.parameters) == 'string' then inst = inst .. ' ' .. LDD.parameters end
    inst = ncMarkup(inst)
  end

  local refs = ncCachedName(a, inst, function()
    local s, regsUsed = nil, false
    if inst ~= '' then
      local ok, got = pcall(_annotate, a, inst)
      if ok and type(got) == 'string' and got ~= '' then s = got end
      local okB, brk = pcall(debug_isBroken)
      regsUsed = (okB and brk == true)
    end
    s = s and ncSanitise(s) or nil
    if s == '' then s = nil end
    return s, regsUsed
  end)

  if ncRefs[a] ~= refs then
    ncRefs[a] = refs
    hlClear(a)
  end

  if hlLineName() then
    local label = hlLabelFor(a)
    if label then r = ncPutName(r, label) end
  end
  return r, d
end

local function ncAttach()
  local v = getVisibleDisassembler()
  if v == nil then
    print('loadNames: open Memory View first, then call loadNames again')
    return false
  end
  local ok0, cur = pcall(function() return v.OnPostDisassemble end)
  if ok0 and cur == ncHook then hlAttach(); return true end

  if ok0 and ncState.mine ~= nil and cur == ncState.mine then
    ncPrev = ncState.orig
  else
    ncPrev = (ok0 and type(cur) == 'function') and cur or nil
    ncState.orig = ncPrev
  end
  ncState.mine = ncHook

  local ok = pcall(function() v.OnPostDisassemble = ncHook end)
  hlAttach()
  for _, m in ipairs({ 'repaint', 'Repaint', 'invalidate', 'Invalidate' }) do
    pcall(function() v[m]() end)
  end
  return ok
end

------------------------------------------------------------------ names browser
do
  local ncListForm = nil
  local ncSorted = nil
  local ncHaystack = nil        -- lowercased: offset + description
  local ncHaystackRaw = nil     -- verbatim:   offset + description
  local ncIndexedRowsRef = nil
  local ncMenuItem = nil
  local ncMenuOwner = nil       -- the form the item was attached to
  local ncLastDir = nil

  local function ncCall(obj, ...)
    if obj == nil then return false end
    for _, name in ipairs({ ... }) do
      local ok = pcall(function() obj[name](obj) end)
      if ok then return true end
    end
    return false
  end

  local function ncSetProp(obj, value, ...)
    if obj == nil then return false end
    for _, name in ipairs({ ... }) do
      local ok = pcall(function() obj[name] = value end)
      if ok then return true end
    end
    return false
  end

  local function ncCreateCheck(parent, caption)
    local chk
    for _, fn in ipairs({ 'createCheckBox', 'createCheckbox' }) do
      local ctor = _G[fn]
      if type(ctor) == 'function' then
        local ok, c = pcall(ctor, parent)
        if ok and c ~= nil then chk = c break end
      end
    end
    if chk == nil then return nil end
    pcall(function() chk.Caption = caption end)
    pcall(function() chk.Checked = false end)
    pcall(function() chk.AutoSize = true end)
    return chk
  end

  local function ncHint(obj, text)
    if obj == nil then return end
    pcall(function() obj.Hint = text end)
    pcall(function() obj.ShowHint = true end)
  end

  local function ncScan(hay, needle, usePattern, source, sourceLen)
    local out, n = {}, 0
    local strFind = string.find
    if usePattern then
      for i = 1, sourceLen do
        local idx = source and source[i] or i
        if strFind(hay[idx], needle) ~= nil then n = n + 1; out[n] = idx end
      end
    else
      for i = 1, sourceLen do
        local idx = source and source[i] or i
        if strFind(hay[idx], needle, 1, true) ~= nil then n = n + 1; out[n] = idx end
      end
    end
    return out, n
  end

  function ncBuildIndex()
    if type(ncRows) ~= 'table' or #ncRows == 0 then
      ncSorted, ncHaystack, ncHaystackRaw, ncIndexedRowsRef = nil, nil, nil, nil
      return
    end
    if ncIndexedRowsRef == ncRows and ncSorted ~= nil then return end

    local total = #ncRows
    local sorted = {}
    for i = 1, total do sorted[i] = i end
    table.sort(sorted, function(a, b)
      return (ncRows[a][1] or 0) < (ncRows[b][1] or 0)
    end)

    local lo, raw = {}, {}
    local fmt, strLower = string.format, string.lower
    for i = 1, total do
      local row = ncRows[sorted[i]]
      local s = fmt('%X %s', row[1] or 0, tostring(row[2] or ''))
      raw[i] = s
      lo[i]  = strLower(s)
    end

    ncSorted = sorted
    ncHaystack = lo
    ncHaystackRaw = raw
    ncIndexedRowsRef = ncRows
  end

  local function ncJumpTo(addr, useHex, focusMv)
    addr = normAddr(addr)
    if addr == nil then return end
    local mv = getMemoryViewForm()
    if mv == nil then return end
    if not mv.Visible then ncCall(mv, 'Show', 'show') end

    if useHex == true then
      local hv = mv.HexadecimalView
      ncSetProp(hv, addr, 'address', 'Address')
      if focusMv then ncCall(hv, 'SetFocus', 'setFocus') end
    else
      local dv = mv.DisassemblerView
      ncSetProp(dv, addr, 'selectedAddress', 'SelectedAddress')
      if focusMv then ncCall(dv, 'SetFocus', 'setFocus') end
    end

    if focusMv then ncCall(mv, 'BringToFront', 'bringToFront') end
  end

  function ncCloseNameList()
    if ncListForm ~= nil then
      pcall(function() ncListForm.destroy() end)
      ncListForm = nil
    end
  end

  local function ncShowNameList()
    if type(ncRows) ~= 'table' or #ncRows == 0 then
      print('ghidraLike: no names loaded - run loadNames(path) first')
      return
    end
    local base = ncBase
    if type(base) ~= 'number' or base == 0 then
      print('ghidraLike: no module base - run loadNames(path) first')
      return
    end

    if ncListForm ~= nil then
      local still = false
      pcall(function()
        if ncListForm.Visible then
          ncCall(ncListForm, 'BringToFront', 'bringToFront')
          still = true
        end
      end)
      if still then return end
      pcall(function() ncListForm.destroy() end)
      ncListForm = nil
    end

    ncBuildIndex()

    local totalRows = #ncRows
    local sorted = ncSorted
    local hayLo  = ncHaystack
    local hayRaw = ncHaystackRaw

    local filtered = nil
    local lastKey, lastNeedle = nil, ''
    local lastPattern, lastCase = false, false

    local f = createForm(false)
    f.Width, f.Height = 720, 520
    f.Position = 'poScreenCenter'
    f.BorderStyle = 'bsSizeable'

    local TOP_GAP = 6
    local CTRL_GAP = 8

    local top = createPanel(f)
    top.Align = 'alTop'
    top.BevelOuter = 'bvNone'

    local lbl = createLabel(top)
    lbl.Caption = 'Filter:'
    lbl.Left = 8
    lbl.AutoSize = true

    local edt = createEdit(top)
    edt.Left = 56
    edt.Top = TOP_GAP
    edt.Anchors = '[akLeft,akRight,akTop]'

    local chkPattern = ncCreateCheck(top, 'pattern')
    local chkCase    = ncCreateCheck(top, 'case-sensitive')

    ncHint(chkPattern,
      'Search by Lua pattern.\n' ..
      'Examples:  ^Action   Selector$   %d+   Action.-Selector\n' ..
      'Unchecked = plain text (no magic characters).')
    ncHint(chkCase,
      'Match upper and lower case exactly.\n' ..
      'The offset is matched as displayed, in uppercase hex.')
    ncHint(edt, 'Type to filter. Toggle pattern for Lua patterns.')

    if chkPattern == nil or chkCase == nil then
      print('ghidraLike: checkboxes unavailable in this CE build - '
        .. 'filter stays plain, case-insensitive')
    end

    local function patternOn() return chkPattern ~= nil and chkPattern.Checked == true end
    local function caseOn()    return chkCase    ~= nil and chkCase.Checked    == true end

    local function modeTag(bad)
      if bad then return '  [invalid pattern]' end
      local t = {}
      if patternOn() then t[#t+1] = 'pattern' end
      if caseOn()    then t[#t+1] = 'case' end
      if #t == 0 then return '' end
      return '  [' .. table.concat(t, ', ') .. ']'
    end

    local function setCaption(shown, bad)
      local head = string.format('ghidraLike names (%s)', tostring(ncMod or ''))
      if shown == totalRows then
        f.Caption = string.format('%s - %d%s', head, totalRows, modeTag(bad))
      else
        f.Caption = string.format('%s - %d / %d%s', head, shown, totalRows, modeTag(bad))
      end
    end

    local lv = createListView(f)
    lv.Align = 'alClient'
    lv.ViewStyle = 'vsReport'
    lv.ReadOnly = true
    lv.RowSelect = true
    lv.HideSelection = false
    pcall(function() lv.FullRowSelect = true end)
    lv.OwnerData = true

    local c1 = lv.Columns.add()
    c1.Caption = 'Offset'
    c1.Width = 120
    local c2 = lv.Columns.add()
    c2.Caption = 'Description'
    c2.Width = 520

    lv.OnData = function(sender, item)
      local zeroIdx = item.Index
      local idx = filtered and filtered[zeroIdx + 1] or (zeroIdx + 1)
      local ri = sorted[idx]
      if ri == nil then return end
      local row = ncRows[ri]
      if row == nil then return end
      item.Caption = string.format('%X', row[1] or 0)
      item.SubItems.add(tostring(row[2] or ''))
    end

    local function applyFilter()
      local usePattern, useCase = patternOn(), caseOn()
      local text = edt.Text or ''
      local needle = useCase and text or text:lower()
      local hay = useCase and hayRaw or hayLo

      local key = (usePattern and 'p' or 'l') .. (useCase and 'c' or 'i')
                .. '\0' .. needle
      if key == lastKey then return end

      if needle == '' then
        filtered = nil
        lv.Items.Count = totalRows
        setCaption(totalRows, false)
      else
        if usePattern and not pcall(string.find, '', needle) then
          filtered = {}
          lv.Items.Count = 0
          setCaption(0, true)
          lastKey, lastNeedle = key, needle
          lastPattern, lastCase = usePattern, useCase
          ncCall(lv, 'Invalidate', 'invalidate')
          return
        end

        -- Narrowing is only sound for PLAIN search with an EXTENDING needle.
        -- A pattern can broaden as it grows ('a' -> 'a-', 'x' -> 'x?').
        local source, sourceLen = nil, totalRows
        if (not usePattern)
           and lastPattern == usePattern and lastCase == useCase
           and lastNeedle ~= '' and needle:sub(1, #lastNeedle) == lastNeedle then
          source = filtered
          sourceLen = source and #source or totalRows
        end

        local ok, res, n = pcall(ncScan, hay, needle, usePattern, source, sourceLen)
        if not ok then
          filtered = {}
          lv.Items.Count = 0
          setCaption(0, true)
        else
          filtered = res
          lv.Items.Count = n
          setCaption(n, false)
        end
      end

      lastKey, lastNeedle = key, needle
      lastPattern, lastCase = usePattern, useCase
      ncCall(lv, 'Invalidate', 'invalidate')
    end

    local function jumpSelected(focusMv)
      local selIdx = lv.ItemIndex
      if selIdx == nil or selIdx < 0 then return end
      local idx = filtered and filtered[selIdx + 1] or (selIdx + 1)
      local ri = sorted[idx]
      if ri == nil then return end
      local row = ncRows[ri]
      if row == nil then return end
      ncJumpTo(base + (row[1] or 0), row[3] == true, focusMv)
    end

    lv.OnDblClick = function() jumpSelected(true) end
    lv.OnKeyDown = function(sender, key)
      if key == 13 then jumpSelected(true) end
    end

    pcall(function()
      lv.OnSelectItem = function(sender, item, selected)
        if selected then jumpSelected(false) end
      end
    end)

    local filterTimer = createTimer(f, false)
    filterTimer.Interval = 150
    filterTimer.OnTimer = function(t)
      t.Enabled = false
      applyFilter()
    end

    edt.OnChange = function()
      filterTimer.Enabled = false
      filterTimer.Enabled = true
    end

    if chkPattern then pcall(function() chkPattern.OnChange = function() applyFilter() end end) end
    if chkCase    then pcall(function() chkCase.OnChange    = function() applyFilter() end end) end

    f.OnClose = function()
      filterTimer.Enabled = false
      ncListForm = nil
      return caFree
    end

    lv.Items.Count = totalRows
    setCaption(totalRows, false)
    ncListForm = f
    ncCall(f, 'Show', 'show')
    ncCall(f, 'Update', 'update')

    local function ctrlWidth(c, caption)
      local w = 0
      pcall(function() w = tonumber(c.Width) or 0 end)
      if w <= 1 then w = #caption * 8 + 24 end
      return w
    end

    local rowH = edt.Height
    if chkCase then
      local w = ctrlWidth(chkCase, 'case-sensitive')
      pcall(function() chkCase.Width = w end)
      chkCase.Anchors = '[akRight,akTop]'
      chkCase.Left = top.Width - TOP_GAP - w
      chkCase.Top  = TOP_GAP + floor((edt.Height - chkCase.Height) / 2)
      if chkCase.Height > rowH then rowH = chkCase.Height end
    end
    if chkPattern then
      local w = ctrlWidth(chkPattern, 'pattern')
      pcall(function() chkPattern.Width = w end)
      chkPattern.Anchors = '[akRight,akTop]'
      local rightEdge = chkCase and chkCase.Left or (top.Width - TOP_GAP)
      chkPattern.Left = rightEdge - CTRL_GAP - w
      chkPattern.Top  = TOP_GAP + floor((edt.Height - chkPattern.Height) / 2)
      if chkPattern.Height > rowH then rowH = chkPattern.Height end
    end

    top.Height = TOP_GAP + rowH + TOP_GAP
    lbl.Top = TOP_GAP + floor((edt.Height - lbl.Height) / 2)

    local editRight = chkPattern and chkPattern.Left or (top.Width - TOP_GAP)
    edt.Width = math.max(60, editRight - CTRL_GAP - edt.Left)

    ncCall(edt, 'SetFocus', 'setFocus')
  end

  ---------------------------------------------------------------- file picker
  -- Opens at getMainForm().SaveDialog1.InitialDir, as asked. That directory is
  -- READ, never written, so CE's own save dialog is left alone. If it is
  -- unavailable, fall back to the directory of the last file opened here.
  local function ncInitialDir()
    local ok, d = pcall(function() return getMainForm().SaveDialog1.InitialDir end)
    if ok and type(d) == 'string' and d ~= '' then return d end
    return ncLastDir
  end

  -- Execute returns a BOOLEAN, so ncCall (which only reports success) will not
  -- do. A cancel is a successful call returning false, not a failure to try.
  -- Distinguishes "no such method" from "method raised" from "user cancelled".
  -- A cancel is a successful call returning false, and stays silent.
  local function ncExecDialog(d)
    for _, name in ipairs({ 'Execute', 'execute' }) do
      local okM, m = pcall(function() return d[name] end)
      if okM and type(m) == 'function' then
        local ok, res = pcall(m, d)
        if ok then return res == true end
        print('ghidraLike: dialog ' .. name .. ' raised: ' .. tostring(res))
        return false
      end
    end
    print('ghidraLike: dialog exposes no Execute method')
    return false
  end

  local function ncPickNamesFile()
    local okM, mf = pcall(getMainForm)
    if not okM then mf = nil end

    local dlg, mine = nil, false
    local ok, d = pcall(createOpenDialog, mf)
    if ok and d ~= nil then dlg, mine = d, true end
    if dlg == nil then
      local ok2, d2 = pcall(function() return mf.OpenDialog1 end)
      if ok2 and d2 ~= nil then dlg = d2 end   -- CE's own: must NOT be destroyed
    end
    if dlg == nil then
      print('ghidraLike: no open-file dialog available in this CE build')
      return nil
    end

    pcall(function() dlg.Title = 'Select a ghidraLike names CSV' end)
    pcall(function() dlg.Filter = 'names CSV (*.csv)|*.csv|All files (*.*)|*.*' end)
    pcall(function() dlg.Options = '[ofFileMustExist,ofHideReadOnly,ofEnableSizing]' end)
    pcall(function() dlg.FileName = '' end)
    local dir = ncInitialDir()
    if dir then pcall(function() dlg.InitialDir = dir end) end

    local path = nil
    if ncExecDialog(dlg) then
      local okF, f = pcall(function() return dlg.FileName end)
      if okF and type(f) == 'string' and f ~= '' then path = f end
    end
    if mine then pcall(function() dlg.destroy() end) end

    if path then
      local dirOf = path:match('^(.*)[/\\][^/\\]*$')
      if dirOf then ncLastDir = dirOf end
    end
    return path
  end

  -- Names loaded -> the browser. No names -> the picker, then the browser.
  -- ncCheckProcess() first, so a process change reverts this to the picker even
  -- if the disassembler has not repainted since.
  local function ncMenuClick()
    -- The process check must never be able to stop the picker opening.
    local okChk, err = pcall(ncCheckProcess)
    if not okChk then
      print('ghidraLike: process check failed: ' .. tostring(err))
    end

    if ncCount > 0 and type(ncRows) == 'table' and #ncRows > 0 then
      ncShowNameList()
      return
    end

    local path = ncPickNamesFile()
    if path == nil then return end
    local ok, n = pcall(ncLoad, path)
    if not ok then
      print('ghidraLike: loadNames failed: ' .. tostring(n))
      return
    end
    if type(n) == 'number' and n > 0 then ncShowNameList() end
  end

  -- quiet=true for the startup poll, so a closed Memory View stays silent.
  -- Identity comparison only: never read a property of a possibly-freed item.
  function ncAttachNameMenu(quiet)
    local okM, mv = pcall(getMemoryViewForm)
    if not okM or mv == nil then
      if not quiet then
        print('ghidraLike: open Memory View first, then run loadNames again')
      end
      return false
    end
    if ncMenuItem ~= nil and ncMenuOwner == mv then return true end
    ncMenuItem, ncMenuOwner = nil, mv

    local okC, mi = pcall(createMenuItem, mv)
    if not okC or mi == nil then
      if not quiet then print('ghidraLike: could not create menu item') end
      return false
    end
    pcall(function() mi.Caption = 'ghidraLike names' end)
    pcall(function() mi.OnClick = function() ncMenuClick() end end)

    local anchor, parent, idx = nil, nil, 0
    pcall(function() anchor = mv.EnumeratedllsandSymbols1 end)
    if anchor ~= nil then
      pcall(function() parent = anchor.Parent end)
      pcall(function() idx = anchor.MenuIndex + 1 end)
    end
    if parent == nil then
      pcall(function() parent = mv.Menu.Items end)   -- top-level fallback
      idx = 0
    end
    if parent == nil then
      if not quiet then print('ghidraLike: no menu to attach to') end
      pcall(function() mi.destroy() end)
      return false
    end

    local okI = pcall(function() parent.insert(idx, mi) end)
    if not okI then okI = pcall(function() parent.add(mi) end) end
    if not okI then
      if not quiet then print('ghidraLike: could not insert menu item') end
      pcall(function() mi.destroy() end)
      return false
    end

    ncMenuItem = mi
    return true
  end
end

------------------------------------------------------------------ loader
function ncLoad(path, module)
  local fh, err = io.open(path, 'rb')
  if fh == nil then
    print('loadNames: cannot open ' .. tostring(path) .. '  ' .. tostring(err))
    return 0
  end
  local content = fh:read('*a')
  fh:close()

  local mn = module
  local rows = {}
  local n = 0

  local strFind = string.find
  local strSub = string.sub
  local strMatch = string.match
  local strByte = string.byte
  local char1 = string.char(1)
  local splitCsv = _G.__glSplitCsv

  for line in content:gmatch('[^\r\n]+') do
    local firstByte = strByte(line, 1)
    if firstByte == 35 then
      if mn == nil then
        local mc = strMatch(line, '^#module=(.+)$')
        if mc then mn = strMatch(mc, '^%s*(.-)%s*$') end
      end
    else
      local c1 = strFind(line, ',', 1, true)
      if c1 ~= nil then
        local f1, f2, f3
        if strFind(line, '"', 1, true) == nil then
          local c2 = strFind(line, ',', c1 + 1, true)
          f1 = strSub(line, 1, c1 - 1)
          if c2 ~= nil then
            f2 = strSub(line, c1 + 1, c2 - 1)
            f3 = strSub(line, c2 + 1)
          else
            f2 = strSub(line, c1 + 1)
          end
        else
          local f = splitCsv(line)
          f1, f2, f3 = f[1], f[2], f[3]
        end

        if f1 ~= 'offset' and f2 ~= 'desc' then
          local off = ncOffset(f1)
          if off ~= nil and f2 ~= nil and f2 ~= '' then
            local bFirst, bLast = strByte(f2, 1), strByte(f2, -1)
            local desc = (bFirst == 32 or bFirst == 9 or bLast == 32 or bLast == 9)
              and strMatch(f2, '^%s*(.-)%s*$') or f2

            if desc ~= '' then
              local useHex = false
              if f3 ~= nil and f3 ~= '' then
                local hx = strMatch(f3, '^%s*(.-)%s*$')
                if hx == '1' or hx == char1 or hx == 'true' or hx == 'TRUE' then
                  useHex = true
                end
              end
              n = n + 1
              rows[n] = { off, desc, useHex }
            end
          end
        end
      end
    end
  end
  content = nil

  if mn == nil or mn == '' then mn = ncMod end
  if mn == nil or mn == '' then mn = moduleName end
  if mn == nil or mn == '' then mn = process end
  if mn == nil then print('loadNames: no module name'); return 0 end
  if n == 0 then print('loadNames: no data rows in ' .. tostring(path)); return 0 end

  ncCheckProcess()

  local ok, b = pcall(getAddress, mn)
  if not ok or type(b) ~= 'number' then
    print('loadNames: cannot resolve module ' .. tostring(mn)); return 0
  end
  ncInstall(rows, b, mn)
  hlFlush()
  ncBuildIndex()
  ncAttach()
  ncAttachNameMenu()
  local hv = hlViewOf()
  if hv ~= nil then pcall(function() hv.update() end) end
  print(string.format('loadNames: %d names, %s base %X, range %X-%X',
    ncCount, tostring(mn), b, ncLo, ncHi))
  return ncCount
end

------------------------------------------------------------------ startup button
-- The button exists before any loadNames call. Memory View may not be open at
-- dofile time, so a 1 s tick keeps trying, silently. Each tick compares FORM
-- IDENTITY only, so it never touches a dangling menu-item handle, and it also
-- re-attaches if Memory View is later replaced by a different form object.
-- The timer is held in a global so a reload destroys the previous one.
ncAttachNameMenu(true)
do
  local okM, mf = pcall(getMainForm)
  if okM and mf ~= nil then
    local prev = _G.ghidraLikeMenuTimer
    if prev ~= nil then pcall(function() prev.destroy() end) end
    local okT, t = pcall(createTimer, mf)
    if okT and t ~= nil then
      t.Interval = 1000
      t.OnTimer = function() ncAttachNameMenu(true) end
      _G.ghidraLikeMenuTimer = t
    end
  end
end

if ncState.pid ~= nil and ncState.pid ~= ncPid then
  ncPurge()
  ncFlush()
  hlFlush()
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