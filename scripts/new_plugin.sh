#!/usr/bin/env bash
# Scaffold a minimal DeepSeek Harness plugin that is BOTH loadable via a
# `--patch` overlay and publishable as a bundle.
#
#   new_plugin.sh ./my-plugin                  # JS plugin, name = my-plugin
#   new_plugin.sh ./my-plugin hello-plugin     # explicit plugin name
#   new_plugin.sh ./my-plugin hello --ts       # TypeScript source variant
#
# Produces:
#   <dir>/package.json       declares dsh.bundle -> cordis.patch.yml
#   <dir>/cordis.patch.yml   insert row referencing the package by name
#   <dir>/index.js           plugin entry (or src/index.ts with --ts)

set -euo pipefail

TARGET="${1:-}"
shift || true
NAME=""
TS=0
for a in "$@"; do
  case "$a" in
    --ts) TS=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's|^# \{0,1\}||'; exit 0 ;;
    -*) printf 'error: unknown flag %s\n' "$a" >&2; exit 2 ;;
    *) NAME="$a" ;;
  esac
done

[[ -n "$TARGET" ]] || { printf 'usage: %s <target-dir> [plugin-name] [--ts]\n' "$0" >&2; exit 2; }

BASE="$(basename "$TARGET")"
NAME="${NAME:-$BASE}"

if ! printf '%s' "$NAME" | grep -qE '^[a-z0-9]+(-[a-z0-9]+)*$'; then
  printf 'error: plugin name must be kebab-case (^[a-z0-9]+(-[a-z0-9]+)*$): %s\n' "$NAME" >&2
  exit 2
fi

if [[ -e "$TARGET/package.json" ]]; then
  printf 'error: %s/package.json already exists; refusing to overwrite\n' "$TARGET" >&2
  exit 1
fi

mkdir -p "$TARGET"
PKG_NAME="dsh-$NAME"

if [[ $TS -eq 1 ]]; then
  mkdir -p "$TARGET/src"
  ENTRY='src/index.ts'
  PATCH_MAIN='"main": "lib/index.js",'
  FILES_LIST='"lib/index.js",'
  EXTRA_NOTE=$'# NOTE: TypeScript bundle — the published entry is lib/index.js, so you must\n# provide a self-contained build step (e.g. `prepare`) that emits lib/.\n# For a zero-build plugin drop --ts and ship index.js instead.'
else
  ENTRY='index.js'
  PATCH_MAIN='"main": "index.js",'
  FILES_LIST='"index.js",'
  EXTRA_NOTE=''
fi

cat > "$TARGET/package.json" <<JSON
{
  "name": "$PKG_NAME",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "A DeepSeek Harness plugin.",
  $PATCH_MAIN
  "files": [
    $FILES_LIST
    "cordis.patch.yml"
  ],
  "dsh": {
    "bundle": {
      "patch": "./cordis.patch.yml"
    }
  }
}
JSON

cat > "$TARGET/cordis.patch.yml" <<YAML
# Layer contributed by $PKG_NAME when a profile lists this bundle.
# The plugin row references the package by NAME (not a path) so Node module
# resolution can find the installed code.
- insert:
    - id: $NAME
      name: $PKG_NAME
YAML

if [[ $TS -eq 1 ]]; then
  cat > "$TARGET/$ENTRY" <<'TS'
import type { Context } from '@deepseek-ai/cordis'

export const name = 'REPLACE_ME'

export function apply(ctx: Context) {
  // Register capabilities here. Anything registered through `ctx` is torn down
  // automatically when this plugin unloads; use ctx.effect() for hand-managed
  // resources.
  console.log('[REPLACE_ME] plugin loaded!')
}
TS
  sed -i '' "s/REPLACE_ME/$NAME/g" "$TARGET/$ENTRY" 2>/dev/null \
    || sed -i "s/REPLACE_ME/$NAME/g" "$TARGET/$ENTRY"
else
  cat > "$TARGET/$ENTRY" <<'JS'
export const name = 'REPLACE_ME'

export function apply(ctx) {
  // Register capabilities here. Anything registered through `ctx` is torn down
  // automatically when this plugin unloads; use ctx.effect() for hand-managed
  // resources.
  console.log('[REPLACE_ME] plugin loaded!')
}
JS
  sed -i '' "s/REPLACE_ME/$NAME/g" "$TARGET/$ENTRY" 2>/dev/null \
    || sed -i "s/REPLACE_ME/$NAME/g" "$TARGET/$ENTRY"
fi

ABS="$(cd "$TARGET" && pwd)"
if [[ $TS -eq 1 ]]; then OVERLAY_ENTRY="$ABS/src/index.ts"; else OVERLAY_ENTRY="$ABS/index.js"; fi

# Ready-to-use `--patch` overlay for local development. It references the plugin
# by ABSOLUTE PATH, because an overlay is applied without installing anything.
cat > "$TARGET/dev.overlay.yml" <<YAML
# Local-development overlay: load the plugin straight from this directory.
#   pnpm dsh web --patch $ABS/dev.overlay.yml
# Overlay plugin paths MUST be absolute. Use cordis.patch.yml instead once the
# plugin is installed into a profile as a bundle.
- insert:
    - id: $NAME
      name: '$OVERLAY_ENTRY'
YAML

cat <<EOF

created $PKG_NAME in $ABS

$EXTRA_NOTE

Run it locally (source checkout, nothing to install):

    pnpm dsh web --patch $ABS/dev.overlay.yml

Install it into a profile as a bundle:

    dsh plugin --profile demo add $ABS
    dsh --profile demo --dump-config     # expect a "# == $PKG_NAME" layer
    dsh --profile demo

Files: package.json | cordis.patch.yml (bundle layer) | dev.overlay.yml (--patch) | $ENTRY

Reminders:
- Overlay plugin paths MUST be absolute; a bundle patch references the package by name.
- A patch replaces the target row's whole \`config\`; it does not deep-merge keys.
- Ship a self-contained build (or plain JS) — git installs pull source, not artifacts.
  If you do ship a \`prepare\` script, the user must allow it via pnpm-workspace.yaml
  \`allowBuilds\`.
EOF
