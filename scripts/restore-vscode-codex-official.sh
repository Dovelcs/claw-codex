#!/usr/bin/env bash
set -euo pipefail

settings="${1:-/home/donovan/.vscode-server/data/Machine/settings.json}"
ts="$(date +%Y%m%d%H%M%S)"

if [[ ! -f "$settings" ]]; then
  echo "settings not found: $settings" >&2
  exit 1
fi

backup="${settings}.bak-restore-official-${ts}"
cp "$settings" "$backup"

python3 - "$settings" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
data.pop("chatgpt.cliExecutable", None)
path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

echo "backup: $backup"
echo "removed chatgpt.cliExecutable from $settings"
