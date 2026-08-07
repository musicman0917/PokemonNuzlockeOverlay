// Polls stream_party.json (written by the Gen1Recomp Lua mod) and renders
// the party as a fixed 6-slot bar. Fails soft: any fetch/parse problem —
// missing file, empty file, or a read that landed mid-write — just keeps
// showing whatever was last rendered successfully.

const CONFIG = {
  DATA_URL: (window.OVERLAY_CONFIG && window.OVERLAY_CONFIG.DATA_URL) || "stream_party.json",
  SPRITE_DIR: "sprites/",
  POLL_INTERVAL_MS: 2000,
  RETRY_DELAY_MS: 150,
  PARTY_SIZE: 6,
};

// Inline SVG pokeball silhouette, used whenever a species has no sprite
// file yet (or the filename doesn't match) so the overlay never shows a
// broken-image icon.
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
  const spriteSrc = `${CONFIG.SPRITE_DIR}${mon.species}.png`;
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
