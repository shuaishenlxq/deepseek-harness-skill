#!/usr/bin/env bash
# Fetch the full DeepSeek Harness documentation set (raw Markdown) into a local
# cache so it can be grepped offline. The page list comes from the site's
# llms.txt, which is the authoritative index.
#
#   fetch_docs.sh                       # ensure the cache exists (bootstrap if missing)
#   fetch_docs.sh --update              # force re-download of every page
#   fetch_docs.sh --list                # list cached pages
#   fetch_docs.sh --grep 'defineTool'   # search the cached docs
#   fetch_docs.sh --page develop/basic/tool
#   fetch_docs.sh --page /reference/subsystems/tools.md
#   fetch_docs.sh --lang en --page reference/index
#
# Env:
#   DSH_DOCS_CACHE  cache dir       (default: ~/.cache/dsh-docs)
#   DSH_DOCS_ORIGIN site origin     (default: https://deepseek-harness.github.io)
#   DSH_DOCS_JOBS   parallel curls  (default: 5)

set -euo pipefail

ORIGIN="${DSH_DOCS_ORIGIN:-https://deepseek-harness.github.io}"
SITE_PATH="/deepseek-harness"
INDEX_URL="$ORIGIN$SITE_PATH/llms.txt"
CACHE="${DSH_DOCS_CACHE:-$HOME/.cache/dsh-docs}"
JOBS="${DSH_DOCS_JOBS:-5}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Any accepted page reference -> cache-relative file name.
normalize() {
  local p="$1"
  p="${p#"$ORIGIN"}"
  p="${p#"$SITE_PATH"}"
  p="${p#/}"
  p="${p%.md}"
  [[ -z "$p" || "$p" == */ ]] && p="${p}index"
  printf '%s' "${p//\//_}.md"
}

# Build "<origin-url>\t<dest-path>" pairs for every page llms.txt lists.
build_manifest() {
  local index="$CACHE/llms.txt"
  curl -fsSL "$INDEX_URL" -o "$index" || die "cannot reach $INDEX_URL"
  local section="" line path rel dest
  : > "$CACHE/.manifest"
  while IFS= read -r line; do
    case "$line" in
      '## '*) case "$line" in
                *中文*)    section=zh ;;
                *English*) section=en ;;
                *)         section="" ;;
              esac
              continue ;;
    esac
    [[ -z "$section" ]] && continue
    path="$(printf '%s' "$line" | grep -oE "\($SITE_PATH/[^)]+\.md\)" | head -1 | tr -d '()')" || true
    [[ -z "$path" ]] && continue
    rel="${path#"$SITE_PATH"/}"
    rel="${rel#"$section"/}"          # English links carry an /en/ prefix already
    dest="$section/${rel//\//_}"
    printf '%s\t%s\n' "$ORIGIN$path" "$dest"
  done < "$index" >> "$CACHE/.manifest"
  mkdir -p "$CACHE/zh" "$CACHE/en"
}

# Download one list of "<url>\t<dest>" pairs at the given concurrency.
# Appends failing URLs to $2. Pairs are handed to xargs as NUL-delimited
# (url, dest) argument pairs — never use -I with a tab-separated line here,
# xargs would not keep the two fields together reliably.
# Download one page to the cache. On failure, append the URL to $3.
download_one() {
  local url="$1" dest="$2" log="$3"
  local tmp="$CACHE/$dest.tmp.$$"
  mkdir -p "$(dirname "$CACHE/$dest")" 2>/dev/null || return 0
  if curl -fsSL -m 25 "$url" -o "$tmp"; then
    mv "$tmp" "$CACHE/$dest"
  else
    rm -f "$tmp"
    printf '%s\n' "$url" >> "$log"
  fi
}

# Download a "<url>\t<dest>" list with simple batch parallelism (portable to
# bash 3.2 — no `wait -n`, no xargs field-splitting surprises).
download_list() {
  local list="$1" log="$2" jobs="$3"
  local n=0 url dest
  while IFS=$'\t' read -r url dest; do
    [[ -z "$url" || -z "$dest" ]] && continue
    download_one "$url" "$dest" "$log" &
    n=$((n + 1))
    if (( n % jobs == 0 )); then wait; fi
  done < "$list"
  wait
}

fetch_all() {
  local force="${1:-}"
  mkdir -p "$CACHE"
  build_manifest
  local total; total="$(wc -l < "$CACHE/.manifest" | tr -d ' ')"
  [[ "$total" -gt 0 ]] || die "llms.txt produced no page list"

  local todo="$CACHE/.todo" retry="$CACHE/.retry"
  : > "$todo"
  while IFS=$'\t' read -r url dest; do
    [[ -s "$CACHE/$dest" && -z "$force" ]] && continue
    printf '%s\t%s\n' "$url" "$dest" >> "$todo"
  done < "$CACHE/.manifest"

  local n; n="$(wc -l < "$todo" | tr -d ' ')"
  if [[ "$n" -eq 0 ]]; then
    printf 'docs cache: %s (%s pages, already up to date)\n' "$CACHE" "$total"
    return 0
  fi

  printf 'fetching %s/%s page(s) into %s (jobs=%s)\n' "$n" "$total" "$CACHE" "$JOBS"
  local fail_log="$CACHE/.failures"; : > "$fail_log"
  download_list "$todo" "$fail_log" "$JOBS"

  # Second, gentler pass for anything the CDN throttled.
  if [[ -s "$fail_log" ]]; then
    local first; first="$(wc -l < "$fail_log" | tr -d ' ')"
    printf 'retrying %s throttled page(s) with jobs=2 ...\n' "$first"
    : > "$retry"
    while IFS= read -r url; do
      pair="$(awk -F'\t' -v u="$url" '$1 == u { print; exit }' "$CACHE/.manifest")"
      [[ -n "$pair" ]] && printf '%s\n' "$pair" >> "$retry"
    done < "$fail_log"
    : > "$fail_log"
    sleep 3
    download_list "$retry" "$fail_log" 2
  fi

  local failed=0
  [[ -s "$fail_log" ]] && failed="$(wc -l < "$fail_log" | tr -d ' ')"
  printf 'docs cache: %s (%s page(s) available, %s failed)\n' \
    "$CACHE" "$(find "$CACHE/zh" "$CACHE/en" -name '*.md' | wc -l | tr -d ' ')" "$failed"
  if [[ "$failed" -gt 0 ]]; then
    printf 'failed URLs (re-run --update to retry):\n'; sed 's/^/  /' "$fail_log" >&2
    return 1
  fi
}

ensure_cache() {
  if ! ls "$CACHE"/zh/*.md >/dev/null 2>&1 && ! ls "$CACHE"/en/*.md >/dev/null 2>&1; then
    fetch_all ""
  fi
}

lang_dir() {
  local want="${1:-zh}"
  if ls "$CACHE/$want"/*.md >/dev/null 2>&1; then printf '%s' "$want"
  elif ls "$CACHE/en"/*.md >/dev/null 2>&1; then printf 'en'
  else die "no cached docs; run $0 --update"; fi
}

# Resolve a page ref to a cached file, downloading it on demand if needed.
resolve_page() {
  local ref="$1" want="${2:-zh}" name f
  name="$(normalize "$ref")"
  for lang in "$want" en; do
    f="$CACHE/$lang/$name"
    [[ -s "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  # on-demand: /deepseek-harness/<rel>.md, or /deepseek-harness/<rel>/index.md
  local rel="${ref#"$ORIGIN"}"; rel="${rel#"$SITE_PATH"}"; rel="${rel#/}"; rel="${rel%.md}"
  mkdir -p "$CACHE/$want"
  for candidate in "$SITE_PATH/$rel.md" "$SITE_PATH/$rel/index.md"; do
    if curl -fsSL -m 20 "$ORIGIN$candidate" -o "$CACHE/$want/$name" 2>/dev/null; then
      printf '%s' "$CACHE/$want/$name"; return 0
    fi
  done
  rm -f "$CACHE/$want/$name"
  return 1
}

cmd="${1:-}"
shift || true

case "$cmd" in
  "" )
    ensure_cache
    printf 'docs cache: %s\n' "$CACHE"
    printf 'zh pages: %s | en pages: %s\n' \
      "$(find "$CACHE/zh" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')" \
      "$(find "$CACHE/en" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
    printf 'hint: --grep <pat> | --page <path> | --list | --update\n'
    ;;

  --update )  fetch_all force ;;

  --list )
    ensure_cache
    find "$CACHE" -name '*.md' | sed "s|^$CACHE/||" | sort
    ;;

  --grep )
    pat="${1:-}"
    [[ -z "$pat" ]] && die "usage: $0 --grep <pattern>"
    shift || true
    lang="$(lang_dir zh)"
    dir="$CACHE/$lang"
    printf '== grep %s in %s ==\n' "$pat" "$dir"
    grep -rniE --include='*.md' -- "$pat" "$dir" | sed "s|^$dir/||" | head -n "${HEAD:-80}"
    ;;

  --page )
    ref="${1:-}"
    [[ -z "$ref" ]] && die "usage: $0 --page <path>"
    shift || true
    lang=zh
    [[ "${1:-}" == "--lang" ]] && lang="${2:-zh}"
    ensure_cache
    f="$(resolve_page "$ref" "$lang")" || die "page not found: $ref"
    printf '# source: %s\n\n' "$ORIGIN$SITE_PATH/${ref#"$SITE_PATH"/}"
    cat "$f"
    ;;

  -h|--help ) sed -n '2,22p' "$0" | sed 's|^# \{0,1\}||' ;;

  * ) die "unknown command: $cmd (try --help)" ;;
esac
