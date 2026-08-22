#!/bin/sh
# Like fake_shell.sh, but backgrounds a long-lived grandchild first and
# records its pid — the process a stopper that signals only the shell
# would leave behind.
sleep 300 &
echo $! > "$CODELEAD_MARKER_FILE"

echo "FAKE SHELL READY"

while IFS= read -r line; do
  if [ "$line" = "exit" ]; then
    exit 7
  fi
  echo "echo:$line"
done
