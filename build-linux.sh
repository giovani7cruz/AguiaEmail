#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
ACBR="${1:-$ROOT/../../Delphi/Componentes/ACBr}"
mkdir -p "$ROOT/bin" "$ROOT/lib"
python3 - "$ROOT/source/AguiaEmail.lpi" "$ACBR/Fontes/Terceiros/synalist" <<'PY'
import os,sys,xml.etree.ElementTree as ET
p=sys.argv[1]; t=ET.parse(p)
t.find('./CompilerOptions/SearchPaths/OtherUnitFiles').set('Value',os.path.relpath(sys.argv[2],os.path.dirname(p)))
t.write(p,encoding='utf-8',xml_declaration=True)
PY
lazbuild --pcp="$ROOT/.lazcfg-linux" --ws=nogui "$ROOT/source/AguiaEmail.lpi" > "$ROOT/lib/build-linux.log" 2>&1 || {
  tail -30 "$ROOT/lib/build-linux.log"; exit 1;
}
ls -l "$ROOT/bin/AguiaEmail"

