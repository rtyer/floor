# Floor: a read-only auction house scanner for WoW Forever.
# `just` alone lists these recipes. Needs just and luajit (brew install just luajit).

set shell := ["bash", "-euo", "pipefail", "-c"]

# The game's AddOns folder. Override with WOW_ADDONS=/path/to/AddOns just install
addons := env_var_or_default("WOW_ADDONS", "/Applications/World of Warcraft/_forever_/Interface/AddOns")
name := "Floor"
version := `sed -n 's/^## Version: *//p' Floor.toc`

# Files that are part of the repo but not of the addon.
dev_files := "--exclude .git --exclude tests --exclude justfile --exclude dist --exclude '*.zip' --exclude .gitignore --exclude .DS_Store"

default:
    @just --list --unsorted

# Run the harness: the addon against fake auction data, no game needed
test:
    luajit tests/harness.lua .

# Copy the addon into the game's AddOns folder, then /reload in game
install: test
    mkdir -p "{{addons}}/{{name}}"
    rsync -a --delete {{dev_files}} ./ "{{addons}}/{{name}}/"
    @echo "Installed {{name}} {{version}} into {{addons}}/{{name}}. Type /reload in game."

# Build dist/Floor-<version>.zip, which unzips to a Floor/ folder for any AddOns directory
package: test
    rm -rf "dist/{{name}}"
    mkdir -p "dist/{{name}}"
    rsync -a {{dev_files}} ./ "dist/{{name}}/"
    cd dist && rm -f "{{name}}-{{version}}.zip" && zip -qr "{{name}}-{{version}}.zip" "{{name}}"
    rm -rf "dist/{{name}}"
    @echo "dist/{{name}}-{{version}}.zip"

# Tag v<version> from Floor.toc and publish a GitHub release with the zip attached
release: package
    git diff --quiet || (echo "commit your changes first" && exit 1)
    git tag -a "v{{version}}" -m "{{name}} {{version}}"
    git push origin "v{{version}}"
    gh release create "v{{version}}" "dist/{{name}}-{{version}}.zip" --title "{{name}} {{version}}" --generate-notes

# Print the version from Floor.toc
version:
    @echo "{{version}}"
