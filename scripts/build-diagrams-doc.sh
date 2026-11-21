#!/usr/bin/env bash
# Regenerates docs/ARCHITECTURE_DIAGRAM.md from diagrams/*.mmd so the two never drift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/ARCHITECTURE_DIAGRAM.md"
{
  echo "# Architecture Diagrams"
  echo
  echo "Generated from the Mermaid sources in [\`diagrams/\`](../diagrams/) by \`scripts/build-diagrams-doc.sh\`."
  echo "GitHub renders these diagrams directly; paste a \`.mmd\` file into any Mermaid editor to export PNG/SVG."
  echo "A self-contained SVG of the network topology (no renderer needed) is [\`diagrams/network-topology.svg\`](../diagrams/network-topology.svg)."
  echo
  echo "![Network topology](../diagrams/network-topology.svg)"
  echo
  echo "> Diagrams describe the **design**. They are not evidence that anything ran: the evidence is in [\`evidence/\`](../evidence/)."
  for f in "$ROOT"/diagrams/*.mmd; do
    title=$(head -1 "$f" | sed 's/^%% *//')
    base=$(basename "$f" .mmd)
    echo; echo "## ${title}"; echo
    echo "Source: [\`diagrams/$base.mmd\`](../diagrams/$base.mmd)"
    echo; echo '```mermaid'; tail -n +2 "$f"; echo '```'
  done
} > "$OUT"
echo "wrote ${OUT#$ROOT/}"
