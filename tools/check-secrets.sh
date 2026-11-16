#!/usr/bin/env bash
# Before pushing: scan the files git would publish (tracked + untracked, not ignored) for keys,
# credentials and personal identifiers. Exits 1 on a hit. Add your own patterns (your Tailscale
# host, your band's address) in ~/.config/bandit/private-patterns, one regex per line.
set -euo pipefail
cd "$(dirname "$0")/.."
patterns=(
  'BEGIN [A-Z ]*PRIVATE KEY'
  '"owner_key"[[:space:]]*:[[:space:]]*"[A-Za-z0-9+/=]{20,}'
  'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}'
  'xox[bpas]-[A-Za-z0-9-]{10,}'
  'AKIA[0-9A-Z]{16}'
  '[A-Z]{2,4}\|[0-9]{12,}\|[0-9a-f]{32}'
  '^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*[A-Z0-9]{10}[[:space:]]*$'
  '[a-z0-9-]+\.tail[a-z0-9]+\.ts\.net'
)
private="$HOME/.config/bandit/private-patterns"
if [ -f "$private" ]; then while IFS= read -r line; do [ -n "$line" ] && patterns+=("$line"); done < "$private"; fi
files=$( { git ls-files; git ls-files --others --exclude-standard; } | sort -u | grep -v -E '^firmware/dongle-pack/vendor/|\.example$')
status=0
for pattern in "${patterns[@]}"; do
  if hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -n -I -E -e "$pattern" -- 2>/dev/null); then
    echo "possible secret or personal data ($pattern):"; echo "$hits" | cut -c1-160; status=1
  fi
done
for file in $(printf '%s\n' "$files" | grep -E '(band\.json|\.npbackup|\.npfw|owner(\.pending)?\.key|meta-session\.json|\.banditfw|signing\.key)$' || true); do
  echo "credential-like file would be published: $file"; status=1
done
[ $status -eq 0 ] && echo "check-secrets: clean ($(printf '%s\n' "$files" | wc -l | tr -d ' ') files)"
exit $status
