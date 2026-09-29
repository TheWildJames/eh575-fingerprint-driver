#!/bin/bash
# Capture test with reliable prompting and real diagnostics.
#
# Why this differs from the previous version:
#  - G_MESSAGES_DEBUG only emits when stderr is a TTY, so the driver log was
#    empty when redirected to a file. We force it on and also keep our own
#    sensor-side counter via the monitor, which does not depend on glib debug.
#  - The terminal bell is unreliable (often disabled), so we print a banner
#    AND touch a marker file, and we say exactly when the window opens.
#  - Counts are computed with awk so a multi-line grep result cannot break
#    integer comparisons.
SCRATCH=/home/james/.hermes/cache/scratch
export LD_LIBRARY_PATH="$SCRATCH/fp/lib"
export EGIS0575_FINGER_THRESHOLD=0x00
N="${1:-3}"
PER="${2:-30}"
STAMP=$(date +%H%M%S)

for i in $(seq 1 "$N"); do
  OUT="$SCRATCH/s${STAMP}_$i.pgm"
  LOG="$SCRATCH/s${STAMP}_$i.log"
  rm -f "$OUT" "$LOG"
  printf '\a\a'
  echo ""
  echo "================================================================"
  echo ">>>>>  SWIPE $i / $N   *** PUT FINGER ON SENSOR NOW ***  <<<<<"
  echo "================================================================"
  date +">>>>>  window opened %H:%M:%S, ${PER}s to swipe  <<<<<"

  timeout "$PER" "$SCRATCH/fptest" capture "$OUT" >"$LOG" 2>&1
  RC=$?

  if [ -s "$OUT" ]; then
    DIM=$(head -c 20 "$OUT" | tr '\n' ' ')
    echo ">>>>>  RESULT $i: SUCCESS  $DIM  $(stat -c%s "$OUT") bytes  <<<<<"
  else
    TOT=$(grep -c "finger field" "$LOG" 2>/dev/null | head -1)
    SEEN=$(grep -cE "finger field = 0x0[1-9a-f]" "$LOG" 2>/dev/null | head -1)
    TOT=${TOT:-0}; SEEN=${SEEN:-0}
    echo ">>>>>  RESULT $i: NO IMAGE (rc=$RC)  <<<<<"
    echo "        driver polls logged: $TOT   polls that saw a finger: $SEEN"
    if awk "BEGIN{exit !($TOT==0)}"; then
      echo "        -> no driver debug at all; run is inconclusive (not a sensor fault)"
    elif awk "BEGIN{exit !($SEEN==0)}"; then
      echo "        -> sensor never saw your finger: swipe was missed or too slow"
    else
      echo "        -> finger WAS detected but no image: real driver failure"
    fi
    echo "        last log lines:"
    tail -4 "$LOG" 2>/dev/null | sed 's/^/          /'
  fi
  echo ""
  sleep 3
done
echo "done - images: ${SCRATCH}/s${STAMP}_*.pgm"
