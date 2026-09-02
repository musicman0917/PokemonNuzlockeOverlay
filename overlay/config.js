// Where the Lua mod's stream_party.json actually lands. Confirmed by
// direct observation on a Windows install (searching for recently
// written files after triggering a mod event in-game) rather than from
// docs alone - the wiki's generic examples turned out to differ from
// this build in two ways:
//
//   1. The identity folder is directly under %APPDATA% with no "love\"
//      wrapper: %APPDATA%\pokemon-love2d\, not %APPDATA%\love\pokemon-love2d\.
//   2. Mods don't write to the save-directory root. The mod loader
//      sandboxes each mod's love.filesystem calls into its own
//      mod_compat\<mod-id>\ subfolder, so main.lua's
//      love.filesystem.write("stream_party.json", ...) actually landed at:
//
//   %APPDATA%\pokemon-love2d\mod_compat\stream-party-overlay\stream_party.json
//
// If this doesn't match on macOS/Linux, search for the file after
// triggering a mod event rather than assuming a path:
//   macOS:   find ~/Library/Application\ Support -iname stream_party.json
//   Linux:   find ~/.local/share ~/.config -iname stream_party.json
//
// In OBS, add index.html as a Browser Source with "Local file" checked;
// an absolute path here works regardless of where index.html is loaded
// from, so point DATA_URL at your resolved path below (forward slashes,
// %20 for spaces in the username).

window.OVERLAY_CONFIG = {
  DATA_URL: "file:///C:/Users/music/AppData/Roaming/pokemon-love2d/mod_compat/stream-party-overlay/stream_party.json",
};
