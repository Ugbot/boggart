#!/bin/sh
printf 'BMUX_FAKE_CODEX_READY\n'
while IFS= read -r line; do
  printf 'BMUX_FAKE_CODEX:%s\n' "$line"
done
