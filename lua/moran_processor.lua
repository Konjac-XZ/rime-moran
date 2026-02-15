-- moran_processor.lua
-- Synopsis: 適用於魔然方案默認模式的按鍵處理器
-- Author: ksqsf
-- License: MIT license
-- Version: 0.4.4

-- 主要功能：
-- 1. 選擇第二個首選項，但可用於跳過 emoji 濾鏡產生的候選
-- 2. 快速切換強制切分
-- 3. 快速取出/放回被吞掉的輔助碼
-- 4. shorthand 略碼

-- ChangeLog:
--  0.4.4: 允許 Ctrl+L 拆開四碼
--  0.4.3: 修復 Ctrl+L 的單字判別條件
--  0.4.2: 放鬆取出輔助碼的條件，Ctrl+O 用於取出輔助碼
--  0.4.1: Ctrl+L 增加對 yyxxo 的支持
--  0.4.0: 增加固定格式略碼功能
--  0.3.0: 增加取出/放回被吞掉的輔助碼的能力
--  0.2.0: 增加快速切換切分的能力，因而從 moran_semicolon_processor 更名爲 moran_processor
--  0.1.5: 修復獲取 candidate_count 的邏輯
--  0.1.4: 數字也增加到條件裏

local moran = require("moran")

local kReject = 0
local kAccepted = 1
local kNoop = 2

local function debug_log(env, msg)
   if not env.debug_capital_append then
      return
   end
   if log and log.error then
      log.error(msg)
   end
end

-- Temporary trace log for diagnosing capital_append behavior.
local function trace_log(msg)
   if log and log.error then
      log.error("[moran_processor.trace] " .. msg)
   end
end

local function safe_key_repr(key_event)
   local ok, repr = pcall(function() return key_event:repr() end)
   if ok and repr then
      return repr
   end
   return "<no-repr>"
end

local function semicolon_processor(key_event, env)
   local context = env.engine.context

   if key_event.keycode ~= 0x3B then
      return kNoop
   end

   local composition = context.composition
   if composition:empty() then
      return kNoop
   end

   local segment = composition:back()
   local menu = segment.menu
   local page_size = env.engine.schema.page_size

   -- Special cases: for 'ovy' and 快符, just send ';'
   if context.input:find('^ovy') or context.input:find('^;') then
      return kNoop
   end

   -- Special case: if there is only one candidate, just select it!
   local candidate_count = menu:prepare(page_size)
   if candidate_count == 1 then
      context:select(0)
      return kAccepted
   end

   -- If it is not the first page, simply send 2.
   local selected_index = segment.selected_index
   if selected_index >= page_size then
      local page_num = math.floor(selected_index / page_size)
      context:select(page_num * page_size + 1)
      return kAccepted
   end

   -- First page: do something more sophisticated.
   local i = 1
   while i < page_size do
      local cand = menu:get_candidate_at(i)
      if cand == nil then
         break
      end
      local cand_text = cand.text
      local codepoint = utf8.codepoint(cand_text, 1)
      if moran.unicode_code_point_is_chinese(codepoint) -- 漢字
         or (codepoint >= 97 and codepoint <= 122)      -- a-z
         or (codepoint >= 65 and codepoint <= 90)       -- A-Z
         or (codepoint >= 48 and codepoint <= 57 and cand.type ~= "simplified") -- 0-9
      then
         context:select(i)
         return kAccepted
      end
      i = i + 1
   end

   -- No good candidates found. Just select the second candidate.
   context:select(1)
   return kAccepted
end

--| 使用快捷鍵從前一段「偷」出輔助碼。
--
-- 例如，想輸入「沒法動」，鍵入 mz'fa'dsl，但輸出是「沒發動」。
-- 此時若選了「沒法」二字，d 會被吞掉。按下該處理器的快捷鍵，可以把 d 再次偷出來。
local function steal_auxcode_processor(key_event, env)
   -- ctrl+l, ctrl+o
   if not (key_event:ctrl() and (key_event.keycode == 0x6c or key_event.keycode == 0x6f)) then
      return kNoop
   end

   local ctx = env.engine.context
   local composition = ctx.composition
   local segmentation = composition:toSegmentation()
   local segs = segmentation:get_segments()
   local n = #segs
   if n <= 1 then
      return kNoop
   end

   local stealer = segs[n]
   local stealee = segs[n-1]
   if stealee:has_tag("_moran_stealee") then
      ctx.input = ctx.input:sub(1, stealer._start) .. ctx.input:sub(stealer._start + 2)
      stealee.tags = stealee.tags - Set({"_moran_stealee"})
      return kAccepted
   end
   if not (stealee.status == 'kSelected' or stealee.status == 'kConfirmed') then
      return kNoop
   end
   local stealee_cand = stealee:get_selected_candidate()
   local auxcode = stealee_cand.preedit:match("[a-z][a-z][a-z]?([a-z])$")
   if not auxcode then
      return kNoop
   end
   ctx.input = ctx.input:sub(1, stealer._start) .. auxcode .. ctx.input:sub(stealer._start + 1)
   stealee.tags = stealee.tags + Set({"_moran_stealee"})
   return kAccepted
end

local function force_segmentation_processor(key_event, env)
   if not (key_event:ctrl() and key_event.keycode == 0x6c) then  -- ctrl+l
      return kNoop
   end

   local composition = env.engine.context.composition
   if composition:empty() then
      return kNoop
   end

   local seg = composition:back()
   local cand = seg:get_selected_candidate()
   if cand == nil then
      return kNoop
   end

   local ctx = env.engine.context
   local input = ctx.input:sub(seg._start + 1, seg._end)
   local preedit = cand.preedit

   local raw = input:gsub("'", "")  -- 不帶 ' 分隔符的輸入

   if input:match("^[a-z][a-z][a-z][a-z]o$") then
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,2) .. "'" .. raw:sub(3,5) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][ '][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z]'[a-z][a-z]$") then  -- 2-2-2
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,3) .. "'" .. raw:sub(4,6) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][ '][a-z][a-z][ '][a-z][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z]'[a-z][a-z][a-z]$") then  -- 2-2-3
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,2) .. "'" .. raw:sub(3,5) .. "'" .. raw:sub(6,7) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][ '][a-z][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z][a-z]'[a-z][a-z]$") then  -- 2-3-2
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,3) .. "'" .. raw:sub(4,5) .. "'" .. raw:sub(6,7) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][a-z][ '][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z][a-z]'[a-z][a-z]'[a-z][a-z]$") then  -- 3-2-2
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,2) .. "'" .. raw:sub(3,4) .. "'" .. raw:sub(5,7) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][ '][a-z][a-z][a-z]$") or input:match("^[a-z][a-z]'[a-z][a-z][a-z]$") then  -- 2-3
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,3) .. "'" .. raw:sub(4,5) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][a-z][ '][a-z][a-z]$") or input:match("^[a-z][a-z][a-z]'[a-z][a-z]$") then  -- 3-2
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,2) .. "'" .. raw:sub(3,5) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][a-z][ '][a-z][a-z][a-z]$") or input:match("^[a-z][a-z][a-z]'[a-z][a-z][a-z]$") then -- 3-3
      ctx.input = ctx.input:sub(1, seg._start) .. raw:sub(1,2) .. "'" .. raw:sub(3,4) .. "'" .. raw:sub(5,6) .. ctx.input:sub(seg._end + 1, -1)
   elseif preedit:match("^[a-z][a-z][a-z][a-z]$") then
      ctx.input = raw:sub(1, 2) .. "'" .. raw:sub(3,4)
   elseif ctx.input:match("^[a-z][a-z]'[a-z][a-z]$") then
      ctx.input = raw
   else
      return kNoop
   end

   return kAccepted
end

-- Append typed letters to the previous syllable when composing Chinese input.
-- Notes from Weasel logs (2026-01-13):
-- - key_event for Shift+K arrives as keycode 0x4B with shift=true; Shift alone is 0xFFE1.
-- - ctx.input is a compact code stream without syllable separators (no spaces/apostrophes).
-- - cand.preedit preserves syllable separators (e.g. "na li"), so we must derive the
--   insertion point from preedit and map it to the compact input by counting A-Za-z.
-- - When preedit is unavailable, we fall back to inserting at the last delimiter in
--   input (rare) or appending to the end.
-- Lessons from logs (2026-02-14):
-- - Hidden assumption #1 (wrong): seg:has_tag("english") can decide if we should
--   preserve typed uppercase.
--   Conflict: recognizer_secondary can tag lowercase Chinese-code inputs as english
--   (e.g. "nihk"), which made Shift+Letter append uppercase in Chinese flow.
--   Resolution: decide by input prefix casing (starts_with_upper) instead.
-- - Hidden assumption #2 (partially wrong): key_event.keycode casing always reflects
--   user intent directly.
--   Conflict: frontend-specific key events and Shift combinations can produce
--   surprising keycode patterns; we keep trace logs for this path.
local function capital_append_processor(key_event, env)
   trace_log(("enter keycode=0x%X shift=%s ctrl=%s repr=%q"):format(
      key_event.keycode,
      tostring(key_event:shift()),
      tostring(key_event:ctrl()),
      safe_key_repr(key_event)
   ))
   debug_log(env, ("capital_append: keycode=0x%X shift=%s ctrl=%s"):format(
      key_event.keycode,
      tostring(key_event:shift()),
      tostring(key_event:ctrl())
   ))
   if key_event:ctrl() then
      trace_log("skip: ctrl")
      debug_log(env, "capital_append: skip (ctrl)")
      return kNoop
   end

   local code = key_event.keycode
   local is_upper = code >= 0x41 and code <= 0x5A
   local is_lower = code >= 0x61 and code <= 0x7A
   trace_log(("classify code=0x%X is_upper=%s is_lower=%s shift=%s"):format(
      code, tostring(is_upper), tostring(is_lower), tostring(key_event:shift())
   ))
   if not (is_upper or is_lower) then
      trace_log("skip: not letter")
      debug_log(env, "capital_append: skip (not letter)")
      return kNoop
   end
   if is_lower and not key_event:shift() then
      trace_log("skip: lowercase without shift")
      debug_log(env, "capital_append: skip (lower without shift)")
      return kNoop
   end

   local ctx = env.engine.context

   local input = ctx.input
   if not input or input == "" then
      trace_log("skip: empty input")
      debug_log(env, "capital_append: skip (empty input)")
      return kNoop
   end

   local insert_pos = nil
   local composition = ctx.composition
   if not composition:empty() then
      local seg = composition:back()
      local cand = seg:get_selected_candidate()
      if cand and cand.preedit then
         local preedit = cand.preedit
         debug_log(env, ("capital_append: preedit=%q"):format(preedit))
         local last_delim = preedit:match(".*()[ ']")
         if last_delim then
            local prefix = preedit:sub(1, last_delim - 1)
            local count = 0
            for _ in prefix:gmatch("[A-Za-z]") do
               count = count + 1
            end
            if count > 0 and count < #input then
               insert_pos = count
               debug_log(env, ("capital_append: insert_pos from preedit=%d"):format(insert_pos))
            else
               debug_log(env, ("capital_append: preedit count out of range=%d input_len=%d"):format(count, #input))
            end
         else
            debug_log(env, "capital_append: no delimiter in preedit")
         end
      else
         debug_log(env, "capital_append: no candidate/preedit")
      end
   end

   -- Preserve typed case only when the whole input starts with uppercase.
   -- This intentionally avoids using seg:has_tag("english"): logs show that tag can
   -- be true for lowercase Chinese-code inputs due to secondary recognizer rules.
   -- Otherwise keep Chinese aux append behavior (append lowercase).
   local starts_with_upper = input:find("^[A-Z]") ~= nil
   local base = string.char(is_upper and code or (code - 32))
   local ch = nil
   if starts_with_upper then
      ch = key_event:shift() and base or string.lower(base)
   else
      ch = string.lower(base)
   end
   trace_log(("compose code=0x%X base=%q ch=%q shift=%s starts_with_upper=%s input_before=%q"):format(
      code, base, ch, tostring(key_event:shift()), tostring(starts_with_upper), input
   ))
   if insert_pos == nil then
      local last_delim = input:match(".*()[ ']")
      if last_delim then
         insert_pos = last_delim - 1
         debug_log(env, ("capital_append: insert_pos from input_delim=%d"):format(insert_pos))
      else
         insert_pos = #input
         debug_log(env, ("capital_append: insert_pos append=%d"):format(insert_pos))
      end
   end

   ctx.input = input:sub(1, insert_pos) .. ch .. input:sub(insert_pos + 1)
   trace_log(("apply insert_pos=%d input_after=%q"):format(insert_pos, ctx.input))
   debug_log(env, ("capital_append: input=%q -> %q"):format(input, ctx.input))
   return kAccepted
end

local shorthands = {
   [string.byte("B")] = function(env, s)
      return s .. "不" .. s
   end,
   [string.byte("L")] = function(env, s)
      return s .. "了" .. s
   end,
   [string.byte("Y")] = function(env, s)
      return s .. "一" .. s
   end,
   [string.byte("V")] = function(env, s)
      if not env.engine.context:get_option("std_tw") then
         return s .. "着" .. s .. "着"
      else
         return s .. "著" .. s .. "著"
      end
   end,
   [string.byte("Q")] = function(env, s)
      if (env.engine.context:get_option("simplification") == true) then
         return s .. "来" .. s .. "去"
      else
         return s .. "來" .. s .. "去"
      end
   end,
}

local function shorthand_processor(key_event, env)
   local shf = shorthands[key_event.keycode]
   if not key_event:shift() or shf == nil then
      return kNoop
   end

   local composition = env.engine.context.composition
   if composition:empty() then
      return kNoop
   end

   local segment = composition:back()
   local cand = segment:get_selected_candidate()
   local text = cand.text
   env.engine:commit_text(shf(env, text))
   env.engine.context:clear()
   return kAccepted
end

return {
   init = function(env)
      env.processors = {
         semicolon_processor,
         force_segmentation_processor,
         steal_auxcode_processor,
      }

      if env.engine.schema.config:get_bool("moran/shorthands") then
         table.insert(env.processors, shorthand_processor)
      end
      env.debug_capital_append = env.engine.schema.config:get_bool("moran/debug_capital_append") or false
      if env.debug_capital_append and log and log.error then
         log.error("[moran_processor] debug_capital_append enabled")
      end
      table.insert(env.processors, capital_append_processor)
   end,

   fini = function(env)
   end,

   func = function(key_event, env)
      if key_event:release() then
         return kNoop
      end

      for _, processor in pairs(env.processors) do
         local res = processor(key_event, env)
         if res == kAccepted or res == kRejected then
            return res
         end
      end
      return kNoop
   end
}
