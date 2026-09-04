# Stream Party Overlay - installer
#
# Downloads the latest published release of the Gen1Recomp Lua mod and
# OBS overlay from GitHub and installs them, so this script itself
# almost never needs to change or be redistributed - re-running it
# later just pulls whatever the newest release is. Run this via
# install.bat (just double-click that), or manually with:
#   powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$Owner = "musicman0917"
$Repo = "PokemonNuzlockeOverlay"
$UserAgent = "StreamPartyOverlayInstaller"

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-LatestReleaseTag {
  param([string]$Owner, [string]$Repo)
  $uri = "https://api.github.com/repos/$Owner/$Repo/releases/latest"
  try {
    $release = Invoke-RestMethod -Uri $uri -Headers @{ "User-Agent" = $UserAgent } -ErrorAction Stop
    return $release.tag_name
  } catch {
    return $null
  }
}

function Get-RemoteFile {
  param([string]$Owner, [string]$Repo, [string]$Tag, [string]$SrcPath, [string]$DestPath)
  $rawUrl = "https://raw.githubusercontent.com/$Owner/$Repo/$Tag/$SrcPath"
  $destDir = Split-Path -Parent $DestPath
  if (-not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
  }
  Invoke-WebRequest -Uri $rawUrl -OutFile $DestPath -Headers @{ "User-Agent" = $UserAgent } -ErrorAction Stop
}

function Exit-Installer {
  param([int]$Code = 0)
  Write-Host ""
  Write-Host "Press Enter to close..."
  Read-Host | Out-Null
  exit $Code
}

Write-Host "Installing Stream Party Overlay..." -ForegroundColor Cyan
Write-Host "Checking GitHub for the latest release..."
$Tag = Get-LatestReleaseTag -Owner $Owner -Repo $Repo

if (-not $Tag) {
  Write-Host ""
  Write-Host "Could not reach GitHub, or no release has been published yet." -ForegroundColor Red
  Write-Host "Check your internet connection and try again. If this keeps happening, check:"
  Write-Host "  https://github.com/$Owner/$Repo/releases/latest"
  Exit-Installer -Code 1
}
Write-Host "Found release: $Tag" -ForegroundColor Green
Write-Host ""

$ModId = "stream-party-overlay"
$AppData = $env:APPDATA
$ModsDir = Join-Path $AppData "pokemon-love2d\mods\$ModId"
$OverlayDir = Join-Path $AppData "pokemon-love2d\mod_compat\$ModId"

Write-Host "  Mod folder:     $ModsDir"
Write-Host "  Overlay folder: $OverlayDir"
Write-Host ""

# ---------------------------------------------------------------------
# Download the mod + overlay from the release tag
# ---------------------------------------------------------------------

$filesToFetch = @(
  @{ Src = "lua-mod/manifest.json"; Dest = (Join-Path $ModsDir "manifest.json") },
  @{ Src = "lua-mod/main.lua";      Dest = (Join-Path $ModsDir "main.lua") },
  @{ Src = "overlay/index.html";    Dest = (Join-Path $OverlayDir "index.html") },
  @{ Src = "overlay/style.css";     Dest = (Join-Path $OverlayDir "style.css") },
  @{ Src = "overlay/app.js";        Dest = (Join-Path $OverlayDir "app.js") }
)

foreach ($f in $filesToFetch) {
  Write-Host "  Downloading $($f.Src)..."
  try {
    Get-RemoteFile -Owner $Owner -Repo $Repo -Tag $Tag -SrcPath $f.Src -DestPath $f.Dest
  } catch {
    Write-Host ""
    Write-Host "Failed to download $($f.Src): $_" -ForegroundColor Red
    Write-Host "Check your internet connection and run this installer again."
    Exit-Installer -Code 1
  }
}

# config.js is generated locally rather than downloaded - it holds a
# machine-specific setting (nothing to fetch, and the repo's own copy
# may carry a path from someone else's earlier troubleshooting). A
# fresh install always starts from the safe relative default, which
# works as long as index.html and stream_party.json stay colocated
# (true here, since the mod writes into this same overlay folder).
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

function Select-GameFolder {
  # Try a real folder-picker dialog first; fall back to $null (caller
  # prompts for typed input instead) if Windows Forms isn't available
  # for any reason, or the user cancels the dialog.
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = "Select the folder gen1recomp.exe is installed in (Cancel to type the path instead, or to skip)"
    $dialog.ShowNewFolderButton = $false
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
      return $dialog.SelectedPath
    }
    return $null
  } catch {
    return $null
  }
}

Write-Host "One more thing - which folder is Gen1Recomp installed in?" -ForegroundColor Cyan
Write-Host "This drops the launcher right next to the game and builds one script that starts the overlay server AND the game together."
Write-Host "A folder picker window should open - if it doesn't appear, alt-tab to check, or just type the path when prompted below."

$gameFolderInput = Select-GameFolder
if (-not $gameFolderInput) {
  $gameFolderInput = Read-Host "Folder gen1recomp.exe lives in (press Enter to skip and set this up later)"
}

$gameExeName = $null
if (-not [string]::IsNullOrWhiteSpace($gameFolderInput)) {
  $gameFolderInput = $gameFolderInput.Trim('"')
  $candidate = Join-Path $gameFolderInput "gen1recomp.exe"
  if (Test-Path -LiteralPath $candidate) {
    $gameExeName = "gen1recomp.exe"
  } else {
    # Name might differ by version/build - fall back to any single .exe
    # in that folder rather than assuming the name is wrong entirely.
    $exeMatches = @(Get-ChildItem -LiteralPath $gameFolderInput -Filter "*.exe" -File -ErrorAction SilentlyContinue)
    if ($exeMatches.Count -eq 1) {
      $gameExeName = $exeMatches[0].Name
    } else {
      Write-Host "Couldn't find a single .exe in that folder (found $($exeMatches.Count)) - falling back to a placeholder you can edit in by hand." -ForegroundColor Yellow
    }
  }
}

if (-not $gameExeName) {
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
  $launchDir = $gameFolderInput
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
Write-Host "Done! Installed $Tag." -ForegroundColor Green
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
Write-Host "Re-running this installer later will pick up whatever the newest published release is."
Exit-Installer -Code 0
