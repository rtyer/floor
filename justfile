# Floor: a read-only auction house scanner for WoW Forever.
# `just` alone lists these recipes. Needs just 1.39 or newer and, for the
# harness, luajit (macOS: brew install just luajit; Windows: winget install
# Casey.Just, and a LuaJIT build on the PATH). Recipes run in bash on macOS
# and Linux and in PowerShell on Windows.

set shell := ["bash", "-euo", "pipefail", "-c"]
set windows-shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-Command"]

name := "Floor"
# The files that make up the addon; everything else in the repo is for developing it.
files := "Floor.toc Core.lua History.lua Scan.lua Crafts.lua UI.lua README.md NOTES.md"
# The version from Floor.toc.
version := trim(replace_regex(read("Floor.toc"), '(?s).*## Version:[ \t]*([^\r\n]+).*', '$1'))

# The game's AddOns folder. Set WOW_ADDONS to point somewhere else, for example
# WOW_ADDONS=/path/to/Interface/AddOns just install
default_addons := if os_family() == "windows" {
    'C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns'
  } else if os() == "macos" {
    "/Applications/World of Warcraft/_forever_/Interface/AddOns"
  } else {
    ""
  }
addons := env_var_or_default("WOW_ADDONS", default_addons)
target := if os_family() == "windows" { addons + '\' + name } else { addons + "/" + name }

default:
    @just --list --unsorted

# Run the harness: the addon against fake auction data, no game needed
test:
    luajit tests/harness.lua .

# Print the version from Floor.toc
version:
    @echo "{{version}}"

# Copy the addon into the game's AddOns folder, then /reload in game
[unix]
install: test
    @[ -n "{{addons}}" ] || { echo "Set WOW_ADDONS to the game's Interface/AddOns folder, e.g. WOW_ADDONS=~/Games/wow/_forever_/Interface/AddOns just install"; exit 1; }
    rm -rf "{{target}}"
    mkdir -p "{{target}}"
    cp {{files}} "{{target}}/"
    @echo "Installed {{name}} {{version}} into {{target}}. Type /reload in game."

[windows]
install: test
    if (Test-Path "{{target}}") { Remove-Item -Recurse -Force "{{target}}" }
    New-Item -ItemType Directory -Force "{{target}}" | Out-Null
    Copy-Item {{replace(files, " ", ", ")}} -Destination "{{target}}"
    Write-Host "Installed {{name}} {{version}} into {{target}}. Type /reload in game."

# Build dist/Floor-<version>.zip, which unzips to a Floor/ folder for any AddOns directory
[unix]
package: test
    rm -rf "dist/{{name}}" "dist/{{name}}-{{version}}.zip"
    mkdir -p "dist/{{name}}"
    cp {{files}} "dist/{{name}}/"
    cd dist && zip -qr "{{name}}-{{version}}.zip" "{{name}}"
    rm -rf "dist/{{name}}"
    @echo "dist/{{name}}-{{version}}.zip"

[windows]
package: test
    if (Test-Path "dist\{{name}}") { Remove-Item -Recurse -Force "dist\{{name}}" }
    New-Item -ItemType Directory -Force "dist\{{name}}" | Out-Null
    Copy-Item {{replace(files, " ", ", ")}} -Destination "dist\{{name}}"
    Compress-Archive -Path "dist\{{name}}" -DestinationPath "dist\{{name}}-{{version}}.zip" -Force
    Remove-Item -Recurse -Force "dist\{{name}}"
    Write-Host "dist\{{name}}-{{version}}.zip"

# Tag v<version> from Floor.toc and publish a GitHub release with the zip attached
[unix]
release: package
    git diff --quiet || { echo "commit your changes first"; exit 1; }
    git tag -a "v{{version}}" -m "{{name}} {{version}}"
    git push origin "v{{version}}"
    gh release create "v{{version}}" "dist/{{name}}-{{version}}.zip" --title "{{name}} {{version}}" --generate-notes

[windows]
release: package
    git diff --quiet; if ($LASTEXITCODE -ne 0) { Write-Host "commit your changes first"; exit 1 }
    git tag -a "v{{version}}" -m "{{name}} {{version}}"
    git push origin "v{{version}}"
    gh release create "v{{version}}" "dist\{{name}}-{{version}}.zip" --title "{{name}} {{version}}" --generate-notes
