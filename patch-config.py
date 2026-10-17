#!/usr/bin/env python3
"""Apply PARALLEL and CONTEXT to the install config Strata generated.

Strata's own entrypoint writes /data/config/strata-<family>-<model>.json once (setup.py) and only
changes it again with REINSTALL=1, and it has no variable for the number of batch slots. This
makes both settings follow the environment at every start:

  PARALLEL  >= 2 : "parallel": N in the config (N conversations decoded together, docs/BATCHING.md)
            1    : the key is removed (one request at a time, Strata's default)
            unset: untouched
  CONTEXT        : the value after "--max-context" in the config's args (unset: untouched)

Command line options (--parallel, --context) win over the environment. A missing config (first
install) is not an error: setup.py has not written it yet and will use CONTEXT itself.
"""
import argparse
import json
import os
import sys


def config_path():
    if os.environ.get("CONFIG"):
        return os.environ["CONFIG"]
    family = os.environ.get("FAMILY", "qwen")
    model = os.environ.get("MODEL", "IQ2_XS")
    prefix = "" if family == "qwen" else f"{family}-"      # same rule as docker-entrypoint.sh
    return os.path.join(os.environ.get("STRATA_DATA", "/data"), "config", f"strata-{prefix}{model.lower()}.json")


def positive_int(name, value, low, high):
    try:
        n = int(value)
    except (TypeError, ValueError):
        sys.exit(f"[strix] {name}={value!r}: expected an integer")
    if not low <= n <= high:
        sys.exit(f"[strix] {name}={n}: expected {low}..{high}")
    return n


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--parallel", help="batch slots (default: $PARALLEL)")
    ap.add_argument("--context", help="context length in tokens (default: $CONTEXT)")
    a = ap.parse_args()
    parallel = a.parallel if a.parallel is not None else os.environ.get("PARALLEL")
    context = a.context if a.context is not None else os.environ.get("CONTEXT")

    path = config_path()
    if not os.path.isfile(path):
        print(f"[strix] no config at {path} yet: nothing to patch")
        return 0
    with open(path, encoding="utf-8") as f:
        cfg = json.load(f)
    changed = []

    if parallel not in (None, ""):
        n = positive_int("PARALLEL", parallel, 1, 8)
        if n >= 2 and cfg.get("parallel") != n:
            changed.append(f"parallel {cfg.get('parallel')} -> {n}")
            cfg["parallel"] = n
        elif n == 1 and "parallel" in cfg:
            changed.append(f"parallel {cfg['parallel']} -> (removed)")
            del cfg["parallel"]

    if context not in (None, ""):
        n = positive_int("CONTEXT", context, 4096, 1048576)
        args = cfg.get("args")
        if isinstance(args, list) and "--max-context" in args[:-1]:
            i = args.index("--max-context") + 1
            if str(args[i]) != str(n):
                changed.append(f"--max-context {args[i]} -> {n}")
                args[i] = str(n)

    if changed:
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=1)
        os.replace(tmp, path)
    print(f"[strix] {path}: " + ("; ".join(changed) if changed else "already up to date"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
