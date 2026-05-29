#!/usr/bin/env python3
"""Bitwarden Secrets Manager helper.

Security guarantee: secret values are generated internally and never appear in
stdout, stderr, or any output returned to Claude. The `value` key is deleted
from every bws response before printing.
"""
import argparse
import json
import os
import secrets
import subprocess
import sys


def _run_bws(args: list[str]) -> dict | list:
    """Run a bws command and return parsed JSON, raising on error."""
    result = subprocess.run(
        ["bws"] + args + ["--output", "json", "--color", "no"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(json.dumps({"error": result.stderr.strip()}))
        sys.exit(1)
    return json.loads(result.stdout)


def _strip_values(data: dict | list) -> dict | list:
    """Remove `value` from a secret object or list of secret objects."""
    if isinstance(data, list):
        return [_strip_values(item) for item in data]
    stripped = {k: v for k, v in data.items() if k != "value"}
    return stripped


def cmd_list_projects(_args) -> None:
    data = _run_bws(["project", "list"])
    projects = [{"id": p["id"], "name": p["name"]} for p in data]
    print(json.dumps(projects, indent=2))


def cmd_list(args) -> None:
    bws_args = ["secret", "list"]
    if args.project_id:
        bws_args.append(args.project_id)
    data = _run_bws(bws_args)
    print(json.dumps(_strip_values(data), indent=2))


def cmd_get_id(args) -> None:
    data = _run_bws(["secret", "list"])
    matches = [s for s in data if s.get("key", "").lower() == args.name.lower()]
    if not matches:
        print(json.dumps({"error": f"No secret found with key '{args.name}'"}))
        sys.exit(1)
    s = matches[0]
    print(json.dumps({"id": s["id"], "name": s["key"]}))


def cmd_create(args) -> None:
    value = secrets.token_urlsafe(32)
    data = _run_bws(["secret", "create", args.name, value, args.project_id])
    print(json.dumps({"id": data["id"], "name": data["key"], "project_id": data["projectId"]}))


def cmd_rotate(args) -> None:
    value = secrets.token_urlsafe(32)
    data = _run_bws(["secret", "edit", args.id, "--value", value])
    print(json.dumps({"id": data["id"], "name": data["key"]}))


def main() -> None:
    if not os.environ.get("BWS_ACCESS_TOKEN"):
        print(json.dumps({"error": "BWS_ACCESS_TOKEN is not set. Add it to ~/.zprofile and restart your shell."}))
        sys.exit(1)

    parser = argparse.ArgumentParser(description="Bitwarden SM helper — value-safe interface")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list-projects", help="List all projects")

    p_list = sub.add_parser("list", help="List secrets (value field omitted)")
    p_list.add_argument("--project-id", help="Filter by project ID")

    p_get = sub.add_parser("get-id", help="Get secret ID by key name")
    p_get.add_argument("--name", required=True, help="Secret key name (case-insensitive)")

    p_create = sub.add_parser("create", help="Create a secret with a generated random value")
    p_create.add_argument("--name", required=True, help="Secret key name (e.g. MY_API_KEY)")
    p_create.add_argument("--project-id", required=True, help="Project ID to add the secret to")

    p_rotate = sub.add_parser("rotate", help="Rotate a secret by generating a new random value")
    p_rotate.add_argument("--id", required=True, help="Secret ID (UUID) to rotate")

    args = parser.parse_args()
    dispatch = {
        "list-projects": cmd_list_projects,
        "list": cmd_list,
        "get-id": cmd_get_id,
        "create": cmd_create,
        "rotate": cmd_rotate,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
