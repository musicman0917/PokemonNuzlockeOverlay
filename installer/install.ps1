# Stream Party Overlay - installer
#
# Installs the Gen1Recomp Lua mod (writes the live party to a JSON file)
# and the OBS browser-source overlay that displays it. Run this via
# install.bat (just double-click that), or manually with:
#   powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

$ModId = "stream-party-overlay"
$AppData = $env:APPDATA
$ModsDir = Join-Path $AppData "pokemon-love2d\mods\$ModId"
$OverlayDir = Join-Path $AppData "pokemon-love2d\mod_compat\$ModId"

Write-Host "Installing Stream Party Overlay..." -ForegroundColor Cyan
Write-Host "  Mod folder:     $ModsDir"
Write-Host "  Overlay folder: $OverlayDir"
Write-Host ""

# ---------------------------------------------------------------------
# Lua mod
# ---------------------------------------------------------------------

$manifestJson = @'
{
  "id": "stream-party-overlay",
  "name": "Stream Party Overlay",
  "version": "1.0.0",
  "entry": "main.lua",
  "api": 2
}
'@
Write-Utf8NoBom -Path (Join-Path $ModsDir "manifest.json") -Content $manifestJson

$mainLua = @'
-- Stream Party Overlay mod for Gen1Recomp (mod API 2)
--
-- Writes the player's current party (species, level, current HP, max HP)
-- to "stream_party.json" so an OBS browser source can poll it.

local OUTPUT_PATH = "stream_party.json"
local TMP_PATH = OUTPUT_PATH .. ".tmp"
local MIN_WRITE_INTERVAL = 0.15 -- seconds; coalesces bursts like multi-hit moves

return function(mod)
  local liveGame = nil
  local lastWriteAt = -math.huge
  local lastFingerprint = nil

  local function safeCall(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
      mod.log:error("stream-party-overlay: %s failed: %s", label, tostring(err))
    end
  end

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
      return
    end

    local fingerprint = fingerprintOf(snapshot)
    if fingerprint == lastFingerprint then
      return
    end

    local now = love.timer.getTime()
    if now - lastWriteAt < MIN_WRITE_INTERVAL then
      return
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

  mod.events:on("game.ready", function(payload)
    liveGame = payload and payload.game
    safeCall("initial write", requestWrite, "game.ready")
  end)

  mod.events:on("save.loaded", function(payload)
    if payload and payload.save then
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
'@
Write-Utf8NoBom -Path (Join-Path $ModsDir "main.lua") -Content $mainLua

# ---------------------------------------------------------------------
# Overlay (HTML/CSS/JS)
# ---------------------------------------------------------------------

$indexHtml = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Party Overlay</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
  <div id="party-board" class="party-board" aria-live="polite"></div>
  <script src="config.js"></script>
  <script src="app.js"></script>
</body>
</html>
'@
Write-Utf8NoBom -Path (Join-Path $OverlayDir "index.html") -Content $indexHtml

$styleCss = @'
/* Cozy tavern / wandering-bard theme for the party overlay.
   Laid out as a fixed 2-column x 3-row grid so it fits a compact
   corner of a scene rather than a wide landscape strip, but still
   flexes to whatever box size is set. */

:root {
  --wood-dark: #3b2417;
  --wood-mid: #5c3a21;
  --wood-light: #7a5230;
  --gold: #d4a24e;
  --gold-bright: #f0c987;
  --parchment: #f0e4c8;
  --parchment-dim: #d8c7a0;
  --hp-high: #4c7a3d;
  --hp-mid: #c98a2c;
  --hp-low: #8b2b2b;
  --shadow: rgba(0, 0, 0, 0.55);
}

* {
  box-sizing: border-box;
}

html, body {
  margin: 0;
  padding: 0;
  height: 100%;
  background: transparent; /* OBS composites over the scene, no page background */
  font-family: Georgia, "Iowan Old Style", "Palatino Linotype", "Book Antiqua", serif;
}

.party-board {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  grid-template-rows: repeat(3, 1fr);
  align-items: center;
  justify-items: center;
  gap: clamp(4px, 2%, 12px);
  padding: clamp(4px, 2%, 10px);
  width: 100%;
  height: 100%;
}

.party-board.is-placeholder {
  display: flex;
  align-items: center;
  justify-content: center;
}

.placeholder-banner {
  color: var(--parchment-dim);
  font-style: italic;
  font-size: clamp(14px, 2vw, 20px);
  text-shadow: 0 2px 3px var(--shadow);
}

.mon-slot {
  position: relative;
  display: flex;
  flex-direction: column;
  justify-content: center;
  width: 100%;
  max-width: 150px;
  background:
    linear-gradient(180deg, var(--wood-light) 0%, var(--wood-mid) 55%, var(--wood-dark) 100%);
  border: 3px solid var(--wood-dark);
  border-radius: 10px;
  padding: 6% 6% 7%;
  box-shadow:
    inset 0 0 0 2px rgba(212, 162, 78, 0.35),
    0 6px 10px var(--shadow);
  transition: opacity 0.3s ease, filter 0.3s ease;
}

.mon-slot.is-empty {
  background: linear-gradient(180deg, #2b1c12 0%, #1c120b 100%);
  box-shadow: inset 0 0 0 2px rgba(90, 62, 34, 0.4), 0 4px 8px var(--shadow);
  opacity: 0.55;
}

.mon-slot.is-fainted .portrait-frame img {
  filter: grayscale(1) brightness(0.55);
}

.mon-slot.is-fainted .mon-name::after {
  content: " (KO)";
  color: var(--hp-low);
  font-style: italic;
}

.portrait-frame {
  width: 68%;
  aspect-ratio: 1 / 1;
  border-radius: 50%;
  background: radial-gradient(circle at 35% 30%, #6b4526, #2a1a0f 75%);
  border: 3px solid var(--gold);
  box-shadow:
    inset 0 0 8px rgba(0, 0, 0, 0.6),
    0 2px 4px var(--shadow);
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  margin: 0 auto 4%;
}

.portrait-frame img {
  width: 82%;
  height: 82%;
  object-fit: contain;
  image-rendering: pixelated;
  filter: drop-shadow(0 2px 2px rgba(0, 0, 0, 0.5));
}

.mon-name {
  color: var(--parchment);
  font-weight: bold;
  font-size: clamp(12px, 1.3vw, 15px);
  text-align: center;
  text-shadow: 0 1px 2px var(--shadow);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.mon-level {
  color: var(--gold-bright);
  font-size: clamp(10px, 1vw, 12px);
  text-align: center;
  margin-bottom: 4px;
}

.hp-track {
  height: 10px;
  border-radius: 6px;
  background: #1a1008;
  box-shadow: inset 0 2px 3px rgba(0, 0, 0, 0.8), inset 0 -1px 0 rgba(255, 255, 255, 0.05);
  overflow: hidden;
  border: 1px solid var(--wood-dark);
}

.hp-fill {
  height: 100%;
  border-radius: 6px 0 0 6px;
  background: linear-gradient(180deg, var(--hp-high), #345a29);
  transition: width 0.5s ease, background-color 0.5s ease;
}

.hp-fill.mid {
  background: linear-gradient(180deg, var(--hp-mid), #8a5c1c);
}

.hp-fill.low {
  background: linear-gradient(180deg, var(--hp-low), #5c1c1c);
}

.hp-text {
  margin-top: 3px;
  font-size: clamp(9px, 0.95vw, 11px);
  color: var(--parchment-dim);
  text-align: center;
}
'@
Write-Utf8NoBom -Path (Join-Path $OverlayDir "style.css") -Content $styleCss

$appJs = @'
// Polls stream_party.json (written by the Gen1Recomp Lua mod) and renders
// the party as a fixed 6-slot grid. Fails soft: any fetch/parse problem -
// missing file, empty file, or a read that landed mid-write - just keeps
// showing whatever was last rendered successfully.

const CONFIG = {
  DATA_URL: (window.OVERLAY_CONFIG && window.OVERLAY_CONFIG.DATA_URL) || "stream_party.json",
  // Public sprite CDN - sprites are loaded via <img src>, not fetch(), so
  // the file:// CORS restrictions that affect stream_party.json don't
  // apply here. Keyed by National Dex number, hence the lookup table below.
  SPRITE_BASE_URL: "https://raw.githubusercontent.com/PokeAPI/sprites/master/sprites/pokemon/",
  POLL_INTERVAL_MS: 2000,
  RETRY_DELAY_MS: 150,
  PARTY_SIZE: 6,
};

// Gen 1 species id (as written by the Lua mod) -> National Dex number,
// for building sprite URLs. Covers all 151 - anything not found (should
// never happen for this game) falls back to the placeholder icon.
const DEX_NUMBERS = {
  BULBASAUR: 1, IVYSAUR: 2, VENUSAUR: 3, CHARMANDER: 4, CHARMELEON: 5,
  CHARIZARD: 6, SQUIRTLE: 7, WARTORTLE: 8, BLASTOISE: 9, CATERPIE: 10,
  METAPOD: 11, BUTTERFREE: 12, WEEDLE: 13, KAKUNA: 14, BEEDRILL: 15,
  PIDGEY: 16, PIDGEOTTO: 17, PIDGEOT: 18, RATTATA: 19, RATICATE: 20,
  SPEAROW: 21, FEAROW: 22, EKANS: 23, ARBOK: 24, PIKACHU: 25,
  RAICHU: 26, SANDSHREW: 27, SANDSLASH: 28, NIDORAN_F: 29, NIDORINA: 30,
  NIDOQUEEN: 31, NIDORAN_M: 32, NIDORINO: 33, NIDOKING: 34, CLEFAIRY: 35,
  CLEFABLE: 36, VULPIX: 37, NINETALES: 38, JIGGLYPUFF: 39, WIGGLYTUFF: 40,
  ZUBAT: 41, GOLBAT: 42, ODDISH: 43, GLOOM: 44, VILEPLUME: 45,
  PARAS: 46, PARASECT: 47, VENONAT: 48, VENOMOTH: 49, DIGLETT: 50,
  DUGTRIO: 51, MEOWTH: 52, PERSIAN: 53, PSYDUCK: 54, GOLDUCK: 55,
  MANKEY: 56, PRIMEAPE: 57, GROWLITHE: 58, ARCANINE: 59, POLIWAG: 60,
  POLIWHIRL: 61, POLIWRATH: 62, ABRA: 63, KADABRA: 64, ALAKAZAM: 65,
  MACHOP: 66, MACHOKE: 67, MACHAMP: 68, BELLSPROUT: 69, WEEPINBELL: 70,
  VICTREEBEL: 71, TENTACOOL: 72, TENTACRUEL: 73, GEODUDE: 74, GRAVELER: 75,
  GOLEM: 76, PONYTA: 77, RAPIDASH: 78, SLOWPOKE: 79, SLOWBRO: 80,
  MAGNEMITE: 81, MAGNETON: 82, FARFETCHD: 83, DODUO: 84, DODRIO: 85,
  SEEL: 86, DEWGONG: 87, GRIMER: 88, MUK: 89, SHELLDER: 90,
  CLOYSTER: 91, GASTLY: 92, HAUNTER: 93, GENGAR: 94, ONIX: 95,
  DROWZEE: 96, HYPNO: 97, KRABBY: 98, KINGLER: 99, VOLTORB: 100,
  ELECTRODE: 101, EXEGGCUTE: 102, EXEGGUTOR: 103, CUBONE: 104, MAROWAK: 105,
  HITMONLEE: 106, HITMONCHAN: 107, LICKITUNG: 108, KOFFING: 109, WEEZING: 110,
  RHYHORN: 111, RHYDON: 112, CHANSEY: 113, TANGELA: 114, KANGASKHAN: 115,
  HORSEA: 116, SEADRA: 117, GOLDEEN: 118, SEAKING: 119, STARYU: 120,
  STARMIE: 121, MR_MIME: 122, SCYTHER: 123, JYNX: 124, ELECTABUZZ: 125,
  MAGMAR: 126, PINSIR: 127, TAUROS: 128, MAGIKARP: 129, GYARADOS: 130,
  LAPRAS: 131, DITTO: 132, EEVEE: 133, VAPOREON: 134, JOLTEON: 135,
  FLAREON: 136, PORYGON: 137, OMANYTE: 138, OMASTAR: 139, KABUTO: 140,
  KABUTOPS: 141, AERODACTYL: 142, SNORLAX: 143, ARTICUNO: 144, ZAPDOS: 145,
  MOLTRES: 146, DRATINI: 147, DRAGONAIR: 148, DRAGONITE: 149, MEWTWO: 150,
  MEW: 151,
};

// Inline SVG pokeball silhouette, used whenever a species has no sprite
// (or the network is unavailable) so the overlay never shows a broken image.
const PLACEHOLDER_SPRITE =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(`
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
      <circle cx="32" cy="32" r="28" fill="#d8c7a0" stroke="#3b2417" stroke-width="3"/>
      <path d="M4 32h56" stroke="#3b2417" stroke-width="3"/>
      <circle cx="32" cy="32" r="8" fill="#d8c7a0" stroke="#3b2417" stroke-width="3"/>
    </svg>
  `);

// A handful of Gen 1 species whose ids don't title-case cleanly.
const NAME_OVERRIDES = {
  NIDORAN_M: "Nidoran♂",
  NIDORAN_F: "Nidoran♀",
  MR_MIME: "Mr. Mime",
  FARFETCHD: "Farfetch'd",
};

const board = document.getElementById("party-board");

let lastRenderedKey = null;
let hasRenderedOnce = false;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function displayName(species) {
  if (!species) return "???";
  if (NAME_OVERRIDES[species]) return NAME_OVERRIDES[species];
  return species
    .toLowerCase()
    .split("_")
    .map((word) => word.charAt(0).toUpperCase() + word.slice(1))
    .join(" ");
}

function spriteUrlFor(species) {
  const dexNum = DEX_NUMBERS[species];
  return dexNum ? `${CONFIG.SPRITE_BASE_URL}${dexNum}.png` : PLACEHOLDER_SPRITE;
}

function hpBand(hp, maxHp) {
  if (maxHp <= 0) return "low";
  const pct = hp / maxHp;
  if (pct <= 0) return "low";
  if (pct <= 0.2) return "low";
  if (pct <= 0.5) return "mid";
  return "high";
}

async function fetchPartyOnce() {
  const res = await fetch(`${CONFIG.DATA_URL}?_=${Date.now()}`, { cache: "no-store" });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const text = await res.text();
  if (!text.trim()) throw new Error("empty file");
  const data = JSON.parse(text);
  if (!data || !Array.isArray(data.party)) throw new Error("malformed payload");
  return data;
}

function renderPlaceholder() {
  board.classList.add("is-placeholder");
  board.innerHTML = `<div class="placeholder-banner">Gathering the party...</div>`;
}

function buildSlot(mon) {
  const slot = document.createElement("div");
  slot.className = "mon-slot";

  if (!mon) {
    slot.classList.add("is-empty");
    slot.innerHTML = `
      <div class="portrait-frame"><img src="${PLACEHOLDER_SPRITE}" alt=""></div>
    `;
    return slot;
  }

  const hp = Math.max(0, Number(mon.hp) || 0);
  const maxHp = Math.max(0, Number(mon.maxHp) || 0);
  const pct = maxHp > 0 ? Math.min(100, Math.round((hp / maxHp) * 100)) : 0;
  const band = hpBand(hp, maxHp);
  const fainted = hp <= 0;
  const spriteSrc = spriteUrlFor(mon.species);
  const label = mon.nickname && mon.nickname !== mon.species ? mon.nickname : displayName(mon.species);

  if (fainted) slot.classList.add("is-fainted");

  slot.innerHTML = `
    <div class="portrait-frame">
      <img src="${spriteSrc}" alt="${displayName(mon.species)}"
           onerror="this.onerror=null; this.src='${PLACEHOLDER_SPRITE}';">
    </div>
    <div class="mon-name">${label}</div>
    <div class="mon-level">Lv. ${mon.level ?? "?"}</div>
    <div class="hp-track"><div class="hp-fill ${band}" style="width:${pct}%"></div></div>
    <div class="hp-text">${hp} / ${maxHp} HP</div>
  `;
  return slot;
}

function renderParty(data) {
  const party = data.party.slice(0, CONFIG.PARTY_SIZE);
  const key = JSON.stringify(party);
  if (key === lastRenderedKey) return; // nothing changed, skip DOM churn
  lastRenderedKey = key;

  board.classList.remove("is-placeholder");
  const frag = document.createDocumentFragment();
  for (let i = 0; i < CONFIG.PARTY_SIZE; i++) {
    frag.appendChild(buildSlot(party[i] || null));
  }
  board.innerHTML = "";
  board.appendChild(frag);
  hasRenderedOnce = true;
}

async function pollParty() {
  try {
    renderParty(await fetchPartyOnce());
    return;
  } catch (firstErr) {
    // Likely a torn read caught mid-write by the Lua mod; one quick retry
    // clears up almost all of these before we fall back to the last state.
    await sleep(CONFIG.RETRY_DELAY_MS);
    try {
      renderParty(await fetchPartyOnce());
    } catch (secondErr) {
      console.warn("party overlay: keeping last known state", secondErr);
      if (!hasRenderedOnce) renderPlaceholder();
    }
  }
}

renderPlaceholder();
pollParty();
setInterval(pollParty, CONFIG.POLL_INTERVAL_MS);
'@
Write-Utf8NoBom -Path (Join-Path $OverlayDir "app.js") -Content $appJs

$configJs = @'
window.OVERLAY_CONFIG = {
  DATA_URL: "stream_party.json",
};
'@
Write-Utf8NoBom -Path (Join-Path $OverlayDir "config.js") -Content $configJs

$Port = 8080

$startScript = @"
@echo off
cd /d "%~dp0"
echo Starting overlay server at http://localhost:$Port/index.html
echo Leave this window open while streaming. Close it or press Ctrl+C to stop.
python -m http.server $Port
pause
"@
Write-Utf8NoBom -Path (Join-Path $OverlayDir "start-overlay-server.bat") -Content $startScript

# ---------------------------------------------------------------------
# Combined launcher: starts the overlay server (minimized, in the
# background) and then the game itself, so there's one thing to double
# click before streaming. The Lua mod's sandbox can't launch external
# processes itself (confirmed via the wiki - it strips exactly this kind
# of capability), so this lives as a plain script alongside it instead.
# ---------------------------------------------------------------------

$overlayServerBat = Join-Path $OverlayDir "start-overlay-server.bat"

Write-Host "One more thing - where's your gen1recomp.exe?" -ForegroundColor Cyan
Write-Host "This drops the launcher right next to the game and builds one script that starts the overlay server AND the game together."
$gameExeInput = Read-Host "Full path to gen1recomp.exe (press Enter to skip and set this up later)"

if ([string]::IsNullOrWhiteSpace($gameExeInput)) {
  # Don't know where the game lives - fall back to keeping the launcher
  # with the rest of the overlay, with a placeholder path to edit in.
  $gameExeWasSkipped = $true
  $launchDir = $OverlayDir
  $launchEverything = @"
@echo off
set "GAME_EXE=C:\PATH\TO\YOUR\gen1recomp.exe"

if not exist "%GAME_EXE%" (
  echo Could not find gen1recomp.exe at:
  echo   %GAME_EXE%
  echo Edit this file (right-click it, Edit) and fix the GAME_EXE path above the line "if not exist".
  pause
  exit /b 1
)

start "Party Overlay Server" /min "$overlayServerBat"
timeout /t 1 /nobreak >nul
start "" "%GAME_EXE%"
"@
} else {
  # Known exe location - drop the launcher right next to it, and find the
  # exe via %~dp0 (relative to itself) so it still works if the whole
  # game folder ever gets moved, same as happened during testing.
  $gameExeWasSkipped = $false
  $launchDir = Split-Path -Parent $gameExeInput
  $gameExeName = Split-Path -Leaf $gameExeInput
  $launchEverything = @"
@echo off
start "Party Overlay Server" /min "$overlayServerBat"
timeout /t 1 /nobreak >nul
start "" "%~dp0$gameExeName"
"@
}

$launchEverythingPath = Join-Path $launchDir "launch-everything.bat"
Write-Utf8NoBom -Path $launchEverythingPath -Content $launchEverything

# ---------------------------------------------------------------------
# Wrap-up
# ---------------------------------------------------------------------

$pythonOk = [bool](Get-Command python -ErrorAction SilentlyContinue)

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host ""

if (-not $pythonOk) {
  Write-Host "NOTE: Python wasn't found on this PC." -ForegroundColor Yellow
  Write-Host "Install it from https://www.python.org/downloads/ (check 'Add python.exe to PATH' during setup)"
  Write-Host "- it's needed to run the local server the overlay uses."
  Write-Host ""
}

if ($gameExeWasSkipped) {
  Write-Host "NOTE: You skipped the gen1recomp.exe path, so launch-everything.bat landed in the overlay folder with a placeholder path." -ForegroundColor Yellow
  Write-Host "  Right-click $launchEverythingPath -> Edit, set GAME_EXE to your actual gen1recomp.exe path, and feel free to move the file next to the exe yourself."
  Write-Host ""
}

Write-Host "Next steps:"
Write-Host "  1. Double-click: $launchEverythingPath"
Write-Host "     (this starts the overlay server minimized in the background, then launches the game)"
Write-Host "  2. Load or start a save and open the party menu once so the mod writes its first data file."
Write-Host "  3. In OBS, add a Browser Source with URL http://localhost:$Port/index.html - leave 'Local file' UNCHECKED."
Write-Host "  4. Position/size it via the source's Properties (Width/Height) and Transform (Position) dialogs, not by dragging the corners."
Write-Host ""
Write-Host "($overlayServerBat also runs the server on its own, if you ever want it without the game.)"
Write-Host ""
Write-Host "Press Enter to close..."
Read-Host | Out-Null
