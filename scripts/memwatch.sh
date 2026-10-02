#!/bin/bash
# Samples Switchboard's memory over hours, to show whether it grows.
# One line every INTERVAL seconds for HOURS hours: time, resident MB, CPU %.
#
#   scripts/memwatch.sh [hours] [interval-seconds] [out.tsv]
#   defaults: 12 hours, every 300 s, ./memwatch.tsv
HOURS="${1:-12}"
INTERVAL="${2:-300}"
OUT="${3:-memwatch.tsv}"

printf 'time\tpid\trss_mb\tcpu\n' > "$OUT"
END=$(( $(date +%s) + HOURS * 3600 ))
while [ "$(date +%s)" -lt "$END" ]; do
  PID="$(pgrep -x Switchboard | head -1)"
  if [ -n "$PID" ]; then
    LINE="$(ps -o rss=,%cpu= -p "$PID")"
    RSS="$(echo "$LINE" | awk '{printf "%.1f", $1/1024}')"
    CPU="$(echo "$LINE" | awk '{print $2}')"
    printf '%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$PID" "$RSS" "$CPU" >> "$OUT"
  else
    printf '%s\t-\t-\t-\n' "$(date '+%F %T')" >> "$OUT"
  fi
  sleep "$INTERVAL"
done
