#!/usr/bin/env python3
"""Regenerate gitops/manifests/hermes-skills/configmap.yaml from the
SKILL.md and post-issue.py sources colocated under hermes-skills/.

Pattern matches scripts/regen-issue-creator-configmap.py: source-of-
truth is the .md / .py files; the ConfigMap is their compiled-into-
cluster mirror. Edit the source files, run me, commit both.
"""

from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC_DIR = REPO / "gitops/manifests/hermes-skills"
# Output lives in the hermes/ Argo path so it's picked up by the existing
# hermes Application. The src/ tree is an inert source-only directory.
DEST = REPO / "gitops/manifests/hermes/configmap-skills.yaml"

# Each entry: (ConfigMap key, source path)
ENTRIES = [
    ("triage-alert.SKILL.md", SRC_DIR / "triage-alert/SKILL.md"),
    ("spec-driver.SKILL.md", SRC_DIR / "spec-driver/SKILL.md"),
    ("post-issue.py", SRC_DIR / "bin/post-issue.py"),
]

HEADER = """\
---
# AUTO-GENERATED from gitops/manifests/hermes-skills/{triage-alert,spec-driver}/SKILL.md
# and gitops/manifests/hermes-skills/bin/post-issue.py via
# scripts/regen-hermes-skills-configmap.py. Do not edit by hand —
# edit the source files and re-run the regen script before committing.
#
# Argo CD applies this ConfigMap; the Hermes Deployment mounts each
# key at a specific path via subPath (see hermes/deployment.yaml).
# Pod restart required after edits (subPath mounts are frozen at
# pod-start time).
apiVersion: v1
kind: ConfigMap
metadata:
  name: hermes-agent-loop-skills
  namespace: hermes
data:
"""


def indent(text: str, by: int = 4) -> str:
    pad = " " * by
    return "".join(pad + line if line.strip() else "\n" for line in text.splitlines(keepends=True))


def main() -> None:
    out = HEADER
    for key, path in ENTRIES:
        if not path.exists():
            raise SystemExit(f"missing source: {path}")
        content = path.read_text(encoding="utf-8")
        out += f"  {key}: |\n"
        out += indent(content, by=4)
    DEST.write_text(out, encoding="utf-8")
    total = sum(p.stat().st_size for _, p in ENTRIES)
    print(f"wrote {DEST} ({total} bytes from {len(ENTRIES)} sources)")


if __name__ == "__main__":
    main()
