#!/usr/bin/env bash
# Report DeepSeek Harness version / freshness facts before writing code.
# Never guess an API surface or version — run this first.
#
#   dsh_info.sh            # npm dist-tags + repo status + key package versions
#   dsh_info.sh --npm      # npm only
#   dsh_info.sh --repo     # repository only
#
# Env:
#   DSH_PKGS  space-separated extra packages to version-check

set -euo pipefail

PKGS="${DSH_PKGS:-@deepseek-ai/dsh @deepseek-ai/cordis @deepseek-ai/schemastery @deepseek-ai/dsh-tools @deepseek-ai/dsh-base @deepseek-ai/dsh-shell}"

need() { command -v "$1" >/dev/null 2>&1 || { printf 'error: %s not found\n' "$1" >&2; exit 1; }; }
need curl

json() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)" 2>/dev/null || echo 'n/a'; }

show_npm() {
  printf '== npm ==\n'
  printf '%-42s %s\n' "package" "latest"
  for p in $PKGS; do
    enc="$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$p")"
    latest="$(curl -fsSL "https://registry.npmjs.org/$enc/latest" 2>/dev/null | json "['version']")"
    printf '%-42s %s\n' "$p" "$latest"
  done
  printf '\n'
  printf 'dist-tags for @deepseek-ai/dsh:\n'
  curl -fsSL "https://registry.npmjs.org/@deepseek-ai/dsh" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
for k,v in sorted(d.get('dist-tags',{}).items()): print(f'  {k:<8} {v}')
ts=d.get('time',{})
rel=sorted(((v,t) for v,t in ts.items() if t and v not in ('created','modified')), key=lambda x:x[1])
print('recent releases:')
for v,t in rel[-5:]: print(f'  {v:<20} {t}')
" 2>/dev/null || echo '  n/a'

  printf '\nlocally installed:\n'
  if command -v dsh >/dev/null 2>&1; then
    printf '  dsh -> %s\n' "$(dsh --version 2>/dev/null || echo '(no --version)')"
  else
    printf '  dsh: not on PATH (use `npx @deepseek-ai/dsh ...`)\n'
  fi
}

show_repo() {
  printf '== repository ==\n'
  curl -fsSL "https://api.github.com/repos/deepseek-ai/deepseek-harness" 2>/dev/null \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
for k in ('full_name','description','default_branch','stargazers_count','open_issues_count','pushed_at'):
    print(f'  {k:<20} {d.get(k)}')
print(f\"  {'license':<20} {(d.get('license') or {}).get('spdx_id')}\")
" 2>/dev/null || printf '  (GitHub API unreachable)\n'

  printf '\nlatest commits on master:\n'
  curl -fsSL "https://api.github.com/repos/deepseek-ai/deepseek-harness/commits?per_page=3" 2>/dev/null \
    | python3 -c "
import sys,json
for c in json.load(sys.stdin):
    print('  {} {}  {}'.format(c['sha'][:8], c['commit']['author']['date'], c['commit']['message'].splitlines()[0][:70]))
" 2>/dev/null || printf '  (unreachable)\n'

  if [[ -n "${DSH_REPO_PATH:-}" && -d "${DSH_REPO_PATH:-}/.git" ]]; then
    printf '\nlocal checkout (%s):\n' "$DSH_REPO_PATH"
    git -C "$DSH_REPO_PATH" log -1 --format='  %h %ci %s' 2>/dev/null || true
    git -C "$DSH_REPO_PATH" status --short 2>/dev/null | head -5 || true
  fi
}

scope="${1:-all}"
case "$scope" in
  --npm)  show_npm ;;
  --repo) show_repo ;;
  all)    show_npm; printf '\n'; show_repo ;;
  *) printf 'usage: %s [--npm|--repo]\n' "$0" >&2; exit 2 ;;
esac
