#!/bin/sh
set -eu

cleanup() {
  if [ -f "$BMUX_AUTOSTART_PIDFILE" ]; then
    pid=$(cat "$BMUX_AUTOSTART_PIDFILE" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        kill -TERM "$pid" 2>/dev/null || true
        n=0
        while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 30 ]; do sleep 0.1; n=$((n+1)); done
        kill -KILL "$pid" 2>/dev/null || true
        ;;
    esac
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

BMUX_AUTOSTART_HOME="${BMUX_AUTOSTART_HOME}-$$"
HOME=$BMUX_AUTOSTART_HOME
USERPROFILE=$BMUX_AUTOSTART_HOME
LOCALAPPDATA=$BMUX_AUTOSTART_HOME/AppData/Local
BOGGART_HOME=$BMUX_AUTOSTART_HOME/data
BMUX_AUTOSTART_STATE=$BMUX_AUTOSTART_HOME/state.json
BMUX_AUTOSTART_PIDFILE=$BMUX_AUTOSTART_HOME/server.pid
export BMUX_AUTOSTART_HOME HOME USERPROFILE LOCALAPPDATA BOGGART_HOME BMUX_AUTOSTART_STATE BMUX_AUTOSTART_PIDFILE
mkdir -p "$BOGGART_HOME"
BMUX_AUTOSTART_PHASE=first "$BOGGART_STUDIO_BIN" "$BMUX_AUTOSTART_PROJECT"
BMUX_AUTOSTART_PHASE=second "$BOGGART_STUDIO_BIN" "$BMUX_AUTOSTART_PROJECT"
