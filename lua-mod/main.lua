-- Stream Party Overlay mod for Gen1Recomp (mod API 2)
--
-- Writes the player's current party (species, level, current HP, max HP)
-- to "stream_party.json" in the LOVE save directory, so an OBS browser
-- source can poll it. See README-lua-mod.md for the event/field
-- assumptions this file relies on.

local OUTPUT_PATH = "stream_party.json"
local TMP_PATH = OUTPUT_PATH .. ".tmp"
local MIN_WRITE_INTERVAL = 0.15 -- seconds; coalesces bursts like multi-hit moves

return function(mod)
  -- Live reference to the running Game instance, captured once at boot.
  -- Everything else (battle events, screen events, etc.) reuses this
  -- instead of relying on a `game` field being present on every payload.
  local liveGame = nil

  local lastWriteAt = -math.huge
  local lastFingerprint = nil

  local function safeCall(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      mod.log:error("stream-party-overlay: %s failed: %s", label, tostring(err))
    end
  end

  -- Minimal JSON string escaper; party payloads are small so we don't
  -- need a general-purpose encoder, just something correct and cheap.
  local function encodeJsonString(s)
    s = tostring(s)
    s = s:gsub('[%c\\"]', function(c)
      if c == '"' then return '\\"' end
      if c == '\\' then return '\\\\' end
      if c == '\n' then return '\\n' end
      if c == '\r' then return '\\r' end
      if c == '\t' then return '\\t' end
      return string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
  end

  local function getLiveParty()
    if not liveGame or not liveGame.save or not liveGame.save.party then
      return nil
    end
    return liveGame.save.party
  end

  -- Builds a plain-Lua snapshot list so we never hold references into
  -- live engine tables while we're formatting/writing.
  local function buildSnapshot()
    local party = getLiveParty()
    if not party then
      return nil
    end

    local snapshot = {}
    for i = 1, #party do
      local mon = party[i]
      if mon and mon.species then
        local maxHp = (mon.stats and mon.stats.hp) or mon.hp or 0
        snapshot[#snapshot + 1] = {
          species = mon.species,
          nickname = mon.nickname,
          level = mon.level or 0,
          hp = mon.hp or 0,
          maxHp = maxHp,
        }
      end
    end
    return snapshot
  end

  local function fingerprintOf(snapshot)
    local parts = {}
    for i = 1, #snapshot do
      local m = snapshot[i]
      parts[#parts + 1] = table.concat(
        { m.species, m.nickname or "", m.level, m.hp, m.maxHp }, ":"
      )
    end
    return table.concat(parts, "|")
  end

  local function encodeSnapshot(snapshot)
    local buf = { '{"updatedAt":', tostring(os.time()), ',"party":[' }
    for i = 1, #snapshot do
      local m = snapshot[i]
      if i > 1 then buf[#buf + 1] = "," end
      buf[#buf + 1] = "{"
      buf[#buf + 1] = '"species":' .. encodeJsonString(m.species) .. ","
      buf[#buf + 1] = '"nickname":' .. (m.nickname and encodeJsonString(m.nickname) or "null") .. ","
      buf[#buf + 1] = '"level":' .. tostring(m.level) .. ","
      buf[#buf + 1] = '"hp":' .. tostring(m.hp) .. ","
      buf[#buf + 1] = '"maxHp":' .. tostring(m.maxHp)
      buf[#buf + 1] = "}"
    end
    buf[#buf + 1] = "]}"
    return table.concat(buf)
  end

  -- Best-effort atomic write: write to a temp file first, then try a
  -- real filesystem rename (instant, no torn-read window) via Lua's
  -- os.rename against the absolute save-dir path. love.filesystem has
  -- no built-in rename, and os.rename may be sandboxed away in fused
  -- builds, so we fall back to a direct overwrite if it's unavailable.
  -- A direct love.filesystem.write of a ~1KB string is already a single
  -- fast buffered write, so the fallback's torn-read window is tiny;
  -- pairing this with cache:"no-store" + retry-on-parse-failure on the
  -- JS side (per the overlay spec) covers the remaining edge case.
  local function atomicWrite(contents)
    local ok, err = love.filesystem.write(TMP_PATH, contents)
    if not ok then
      return false, err
    end

    local renamed = false
    if os and os.rename then
      local saveDir = love.filesystem.getSaveDirectory()
      local absTmp = saveDir .. "/" .. TMP_PATH
      local absFinal = saveDir .. "/" .. OUTPUT_PATH
      renamed = pcall(os.rename, absTmp, absFinal) and true or false
    end

    if not renamed then
      local wok, werr = love.filesystem.write(OUTPUT_PATH, contents)
      love.filesystem.remove(TMP_PATH)
      if not wok then
        return false, werr
      end
    end

    return true
  end

  local function requestWrite(reason)
    local snapshot = buildSnapshot()
    if not snapshot then
      return -- engine not ready yet / no active save; leave existing file alone
    end

    local fingerprint = fingerprintOf(snapshot)
    if fingerprint == lastFingerprint then
      return -- nothing actually changed, skip the disk write entirely
    end

    local now = love.timer.getTime()
    if now - lastWriteAt < MIN_WRITE_INTERVAL then
      return -- coalesce rapid-fire events (e.g. multi-hit moves); a later
             -- event in the same burst will flush the final state
    end

    local ok, err = atomicWrite(encodeSnapshot(snapshot))
    if ok then
      lastFingerprint = fingerprint
      lastWriteAt = now
      mod.log:info("stream-party-overlay: wrote party snapshot (%s)", reason)
    else
      mod.log:warn("stream-party-overlay: write failed (%s): %s", reason, tostring(err))
    end
  end

  -- --- Event wiring -------------------------------------------------

  mod.events:on("game.ready", function(payload)
    liveGame = payload and payload.game
    safeCall("initial write", requestWrite, "game.ready")
  end)

  mod.events:on("save.loaded", function(payload)
    if payload and payload.save then
      -- Keep liveGame.save pointed at whatever the engine just swapped in.
      liveGame = liveGame or {}
      liveGame.save = payload.save
    end
    safeCall("save.loaded", requestWrite, "save.loaded")
  end)

  local partyChangeEvents = {
    "pokemon.caught",
    "pokemon.level_up",
    "pokemon.evolved",
    "pokemon.received",
    "battle.damage_dealt",
    "battle.status_inflicted",
    "battle.fainted",
    "battle.ended",
    "screen.pushed",
    "screen.popped",
    "map.entered",
  }

  for _, eventName in ipairs(partyChangeEvents) do
    mod.events:on(eventName, function()
      safeCall(eventName, requestWrite, eventName)
    end)
  end
end
