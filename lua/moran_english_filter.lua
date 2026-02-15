-- moran_english_filter.lua
--
-- Version: 0.3.0
-- Author:  ksqsf
-- License: GPLv3
--
-- 0.3.0: Add lowercase fallback query for mixed/uppercase input.
-- 0.2.0: Honor typed case for candidate prefixes and stop dropping by case mismatch.
-- 0.1.1: Relax matching criteria.
-- 0.1: Add.

-- == Developer notes ==
--
-- We assume that the way the English translator finds candidates is fuzzy:
--  1. Input can match words regardless of casing.
--
-- For example:
--  1. "hello" can find "hello", "hELLO", "Hello".
--  2. "Hello" can find "Hello", "hello", "HEllo".
--
-- The expected use case is:
--  1. moran_english.dict.yaml contains "Apple"
--  2. Input "APP" finds "Apple"
--  3. This filter modifies the output to "APPle".
--  4. Input "Chatgpt" keeps dictionary uppercase and outputs "ChatGPT"
--     (typed lowercase cannot demote dictionary uppercase).
--
-- Lessons from logs (2026-02-14):
-- - Hidden assumption #1 (wrong): if "cand.preedit = input" returns without error,
--   preedit has been updated.
--   Conflict: for some candidate wrappers (notably ShadowCandidate/fallback path),
--   assignment may not throw but still does not change observable preedit.
-- - Hidden assumption #2 (wrong): case-fixed text alone is enough.
--   Conflict: lowercase fallback query ("app") can leak lowercase preedit into buffer
--   even when displayed candidate text is "APP...".
-- - Resolution: rebuild outgoing English candidates via Candidate(...) and set
--   preedit on the rebuilt candidate; do not rely on mutating wrapped candidates.

local moran = require("moran")

local Module = {}

-----------------------------------------------------------------------

local PAT_UPPERCASE = "[A-Z]"
local PAT_ENGLISH_WORD = "^[a-zA-Z0-9 &!@#$%^&*()-=_+[%]\\\\{}'\";,./<>?]+$"

local function debug_log(env, msg)
   if not env.debug_english_filter then
      return
   end
   if log and log.error then
      log.error("[moran_english_filter] " .. msg)
   end
end

local function safe_preedit(cand)
   local ok, v = pcall(function() return cand.preedit end)
   if ok then
      return tostring(v)
   end
   return "<preedit-read-failed>"
end

-- | Check if @s is proper: contains at least one capital letter.
--
-- @param s str
-- @return true if proper; false otherwise
local function str_is_proper(s)
   return s:find(PAT_UPPERCASE) ~= nil
end

-- | Check if @s is an English word.
--
-- @param s str
-- @return true if it can be considered an English word
local function str_is_english_word(s)
    return s:find(PAT_ENGLISH_WORD) ~= nil
end

local function str_has_uppercase(s)
   return s:find(PAT_UPPERCASE) ~= nil
end

local function casefold_ascii(s)
   return (s:gsub("%u", string.lower))
end

-- | Apply one-way case preference from @std to @str:
-- | - typed uppercase can promote candidate letters to uppercase
-- | - typed lowercase must NOT demote candidate uppercase letters
local function fix_case(str, std)
   if not str or not std then
      return ""
   end

   local len = math.min(#str, #std)
   local out = {}
   for i = 1, len do
      local src = str:sub(i, i)
      local pat = std:sub(i, i)
      if src:match("%a") and pat:match("%u") then
         out[i] = string.upper(src)
      else
         out[i] = src
      end
   end
   if #str > len then
      out[len + 1] = str:sub(len + 1, -1)
   end
   return table.concat(out)
end

-- | A fast check on the first byte of the string.
local function not_filterable(s)
    return #s > 0 and s:byte(1) >= 128
end

local function force_preedit(cand, preedit)
   local ok, err = pcall(function()
      cand.preedit = preedit
   end)
   return ok, err
end

local function build_english_candidate(src, text, preedit)
   local ctype = src.type or "completion"
   local cstart = src._start or 0
   local cend = src._end or 0
   local ccomment = src.comment or ""
   local cand = Candidate(ctype, cstart, cend, text, ccomment)
   -- Intentionally build a fresh candidate: logs show mutating wrapped candidate
   -- preedit is not reliably observable in fallback/shadow paths.
   local ok_preedit, err_preedit = force_preedit(cand, preedit)
   local ok_quality, q = pcall(function() return src.quality end)
   if ok_quality and q ~= nil then
      pcall(function() cand.quality = q end)
   end
   return cand, ok_preedit, err_preedit
end

-----------------------------------------------------------------------

function Module.init(env)
   env.debug_english_filter = env.engine.schema.config:get_bool("moran/debug_english_filter") or false
   local ok, tr = pcall(Component.Translator, env.engine, "", "table_translator@english")
   if ok then
      env.english_translator = tr
   else
      env.english_translator = nil
      debug_log(env, "failed to init table_translator@english; fallback query disabled")
   end
end

function Module.fini(env)
   env.english_translator = nil
end

function Module.func(t_input, env)
   local composition = env.engine.context.composition
   if composition:empty() then
      debug_log(env, "composition is empty")
      return
   end

   local segmentation = composition:toSegmentation()
   local seg = segmentation:back()
   local iter = moran.iter_translation(t_input)
   local has_english_tag = seg:has_tag("english")
   if not has_english_tag then
      debug_log(env, "segment has no english tag; passthrough")
      moran.yield_all(iter)
      return
   end

   local input = segmentation.input:sub(seg._start + 1, seg._end + 1)
   if not str_is_proper(input) then
      moran.yield_all(iter)
      return
   end
   debug_log(env, ("input=%q segment=[%d,%d]"):format(
      input, seg._start, seg._end
   ))

   local seen = {}
   local function emit_fixed(c, source, idx)
      if not_filterable(c.text) or not str_is_english_word(c.text) then
         local dedup_key = "raw\0" .. c.text
         if seen[dedup_key] then
            debug_log(env, ("%s cand#%d dedup(raw): %q"):format(source, idx, c.text))
            return false
         end
         seen[dedup_key] = true
         debug_log(env, ("%s cand#%d keep(non_filterable/non_english): %q"):format(source, idx, c.text))
         yield(c)
         return true
      end

      local fixed_text = fix_case(c.text, input)
      local dedup_key = "eng\0" .. fixed_text
      if seen[dedup_key] then
         debug_log(env, ("%s cand#%d dedup(english): %q"):format(source, idx, fixed_text))
         return false
      end
      seen[dedup_key] = true
      if fixed_text == c.text then
         debug_log(env, ("%s cand#%d keep(case already match): %q"):format(source, idx, c.text))
      else
         debug_log(env, ("%s cand#%d fix_case: %q -> %q"):format(source, idx, c.text, fixed_text))
      end
      local out, ok, err = build_english_candidate(c, fixed_text, input)
      if not ok then
         debug_log(env, ("%s cand#%d force_preedit failed: %s"):format(source, idx, tostring(err)))
      end
      yield(out)
      return true
   end

   local kept = 0
   local primary_scanned = 0
   for c in iter do
      primary_scanned = primary_scanned + 1
      if emit_fixed(c, "primary", primary_scanned) then
         kept = kept + 1
      end
   end

   local fallback_scanned = 0
   local folded_input = casefold_ascii(input)
   if str_has_uppercase(input) and folded_input ~= input and env.english_translator ~= nil then
      debug_log(env, ("fallback query: input=%q folded=%q"):format(input, folded_input))
      local fallback_iter = moran.query_translation(env.english_translator, folded_input, seg)
      for c in fallback_iter do
         fallback_scanned = fallback_scanned + 1
         if emit_fixed(c, "fallback", fallback_scanned) then
            kept = kept + 1
         end
      end
   end

   debug_log(env, ("summary input=%q kept=%d scanned(primary=%d,fallback=%d)"):format(
      input, kept, primary_scanned, fallback_scanned
   ))
end

return Module

-- Local Variables:
-- lua-indent-level: 4
-- End:
