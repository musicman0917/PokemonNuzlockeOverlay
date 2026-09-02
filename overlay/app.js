// Polls stream_party.json (written by the Gen1Recomp Lua mod) and renders
// the party as a fixed 6-slot bar. Fails soft: any fetch/parse problem —
// missing file, empty file, or a read that landed mid-write — just keeps
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
