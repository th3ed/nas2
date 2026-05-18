#!/usr/bin/env python3
"""Regenerate gitops/manifests/issue-creator/configmap.yaml from app.py.

The issue-creator's Python source lives next to its manifests at
gitops/manifests/issue-creator/app.py. The ConfigMap that ships it to
the cluster needs the same text inlined under data.app.py (Kubernetes
ConfigMap data values are YAML strings, so the file is embedded as a
block scalar). This script is the single-step rebuild: edit app.py, run
me, commit both files.

Run: python3 scripts/regen-issue-creator-configmap.py
"""

from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "gitops/manifests/issue-creator/app.py"
DEST = REPO / "gitops/manifests/issue-creator/configmap.yaml"

HEADER = """\
---
# AUTO-GENERATED from gitops/manifests/issue-creator/app.py via
# scripts/regen-issue-creator-configmap.py. Do not edit by hand —
# edit app.py and re-run the regen script before committing.
#
# Argo CD applies this ConfigMap; the Deployment mounts it at
# /opt/app/app.py via subPath. A pod restart picks up source changes
# (subPath mounts are frozen at pod-start time).
apiVersion: v1
kind: ConfigMap
metadata:
  name: issue-creator-src
  namespace: github-app
data:
  app.py: |
"""


def main() -> None:
    src_text = SRC.read_text(encoding="utf-8")
    indented = "".join("    " + line if line.strip() else "\n" for line in src_text.splitlines(keepends=True))
    DEST.write_text(HEADER + indented, encoding="utf-8")
    print(f"wrote {DEST} ({len(src_text)} chars from {SRC})")


if __name__ == "__main__":
    main()
