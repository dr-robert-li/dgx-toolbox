#!/usr/bin/env python3
"""LiteLLM config.yaml model registration/deregistration helper.

Usage:
  _litellm_register.py add <model_name> <api_base>
  _litellm_register.py remove <model_name>
  _litellm_register.py list

WARNING: pyyaml does not preserve YAML comments. The 'remove' command
will strip comments from config.yaml. A backup is created first.
"""
import os
import sys
import yaml
import shutil
from datetime import datetime, timezone

CONFIG_PATH = os.path.expanduser("~/.litellm/config.yaml")


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f) or {}


def save_config(config):
    # Backup before destructive write
    backup = CONFIG_PATH + f".bak.{datetime.now().strftime('%Y%m%d%H%M%S')}"
    shutil.copy2(CONFIG_PATH, backup)
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    print(f"Backup saved: {backup}")


def add_model(model_name, api_base):
    config = load_config()
    model_list = config.setdefault("model_list", [])
    existing = [m["model_name"] for m in model_list if "model_name" in m]
    if model_name in existing:
        print(f"Already registered: {model_name}")
        return
    model_list.append({
        "model_name": model_name,
        "litellm_params": {
            "model": f"openai/{model_name}",
            "api_base": api_base,
            "api_key": "none"
        }
    })
    save_config(config)
    print(f"Registered: {model_name}")


def remove_model(model_name):
    config = load_config()
    model_list = config.get("model_list", [])
    original_count = len(model_list)
    config["model_list"] = [m for m in model_list if m.get("model_name") != model_name]
    if len(config["model_list"]) == original_count:
        print(f"Not found: {model_name}")
        sys.exit(1)
    save_config(config)
    print(f"Removed: {model_name}")


def list_models():
    config = load_config()
    for m in config.get("model_list", []):
        name = m.get("model_name", "?")
        base = m.get("litellm_params", {}).get("api_base", "?")
        print(f"  {name}  ->  {base}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "add" and len(sys.argv) == 4:
        add_model(sys.argv[2], sys.argv[3])
    elif cmd == "remove" and len(sys.argv) == 3:
        remove_model(sys.argv[2])
    elif cmd == "list":
        list_models()
    else:
        print(__doc__)
        sys.exit(1)
