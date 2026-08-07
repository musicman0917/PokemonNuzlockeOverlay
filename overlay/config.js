// Where the Lua mod's stream_party.json actually lands. The mod writes
// it with love.filesystem.write(), which is rooted at the LOVE save
// directory (confirmed via the Gen1Recomp wiki's Guide-Save-Editor page,
// the same folder save.lua lives in):
//
//   Windows: %APPDATA%\love\pokemon-love2d\stream_party.json
//   macOS:   ~/Library/Application Support/LOVE/pokemon-love2d/stream_party.json
//   Linux:   ~/.local/share/love/pokemon-love2d/stream_party.json
//
// That's a different folder from this overlay/ directory, so point
// DATA_URL at the absolute path for your OS/username below. In OBS,
// add index.html as a Browser Source with "Local file" checked and
// this path resolves relative to that file - an absolute path here
// always works regardless of where index.html itself is loaded from.
//
// Left as a relative path by default, which only works if you copy
// index.html/style.css/app.js/config.js/sprites/ directly into that
// save-data folder alongside stream_party.json.

window.OVERLAY_CONFIG = {
  DATA_URL: "stream_party.json",
};
