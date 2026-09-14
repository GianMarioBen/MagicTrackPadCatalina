#!/bin/bash
# Controllo di sintassi dei sorgenti macOS su una macchina qualsiasi.
#
# Non produce binari: usa header fittizi per far arrivare il compilatore
# fino in fondo ai file e intercettare errori di sintassi, identificatori
# non dichiarati e firme sbagliate — cioe' la classe di errori che
# altrimenti si scopre solo sul Mac.
#
#   tools/syntax-check/check.sh
set -u
cd "$(dirname "$0")/../.."
STUBS="tools/syntax-check/stubs"
CC=${CC:-gcc}
fail=0

for f in tools/mt_enable.c tools/mt_desc_dump.c tools/mt_sweep.c src/mammetta_bridge.m; do
  [ -f "$f" ] || continue
  case "$f" in *.m) lang="-x c" ;; *) lang="" ;; esac
  if $CC -fsyntax-only $lang -I "$STUBS" -Wall -Wextra "$f" 2>/tmp/sc.$$; then
    printf '  OK        %s\n' "$f"
  else
    printf '  FALLITO   %s\n' "$f"
    sed 's/^/      /' /tmp/sc.$$
    fail=1
  fi
  rm -f /tmp/sc.$$
done

exit $fail
