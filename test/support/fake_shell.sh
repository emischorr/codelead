#!/bin/sh
# A scripted stand-in for the terminal shell, selected via the
# :terminal_command config as ["sh", <this file>] — Session tests drive
# it instead of a real interactive shell. Prints a marker so tests can
# await startup, echoes stdin lines back tagged, and exits 7 on "exit".

echo "FAKE SHELL READY"

while IFS= read -r line; do
  if [ "$line" = "exit" ]; then
    exit 7
  fi
  echo "echo:$line"
done
