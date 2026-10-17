#!/bin/sh
# Wrapper around Strata's docker-entrypoint.sh (kept as it is):
#   1. PARALLEL / CONTEXT follow the environment on every start (patch-config.py).
#   2. STRATA_ARENA_MMAP=1: the experts are read from a file (experts.bin) that the engine writes at
#      the first start that has the variable, and maps from the next start on, instead of keeping a
#      second copy of 23 GiB in RAM next to the GPU's. That first start still loads them in RAM, so
#      it is made small (no batch slots, short context) and stopped as soon as the file is written;
#      the real start follows in the same container.
cd /opt/strata || exit 1
UP=./docker-entrypoint.sh
PY=/opt/strata/.venv/bin/python
DATA="${STRATA_DATA:-/data}"

have_arena() { ls "$DATA"/packs/*/experts.bin >/dev/null 2>&1; }
arena_written() { grep -qs "STRATA_ARENA_MMAP: wrote" /opt/strata/strata-*.log 2>/dev/null; }

if [ "${STRATA_ARENA_MMAP:-0}" = "1" ] && ! have_arena; then
  echo "[strix] STRATA_ARENA_MMAP=1 and no experts.bin yet: small first start to write it"
  $PY ./patch-config.py --parallel 1 --context 65536 || exit 1
  CONTEXT=65536 PARALLEL=1 $UP &
  child=$!
  trap 'kill -TERM "$child" 2>/dev/null; wait "$child" 2>/dev/null; exit 143' TERM INT
  while kill -0 "$child" 2>/dev/null && ! arena_written; do sleep 5; done
  if arena_written; then
    echo "[strix] experts.bin written: restarting on the final settings"
    kill -TERM "$child" 2>/dev/null
    i=0
    while kill -0 "$child" 2>/dev/null && [ "$i" -lt 90 ]; do sleep 1; i=$((i + 1)); done
    kill -KILL "$child" 2>/dev/null
    # the engine is a child of the server: none may be left holding the GPU
    if command -v pgrep >/dev/null 2>&1; then
      for p in $(pgrep -f "engine/strata" 2>/dev/null); do kill -KILL "$p" 2>/dev/null; done
    fi
    sleep 3
  else
    wait "$child"      # the first start ended by itself (an error): report its status
    exit $?
  fi
  trap - TERM INT
fi

$PY ./patch-config.py || exit 1
exec $UP
