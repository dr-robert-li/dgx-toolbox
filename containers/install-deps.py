#!/usr/bin/env python3
"""
Install Python packages into NGC-style containers without clobbering pre-installed
pinned versions (e.g. torch, torchvision, torchaudio, torchcodec).

NGC PyTorch images ship custom-compiled torch + torchvision wheels built against
the image's CUDA / C++ ABI. If pip's normal resolver runs while installing a
package that declares a torch/torchvision constraint, it replaces the NGC wheel
with a vanilla PyPI build whose compiled `.so` no longer matches torch's C++
symbols.

Strategy:
  1. Install every requested top-level package with `pip install --no-deps`.
  2. BFS through each installed package's declared requirements
     (`importlib.metadata.requires`), filtering out extras and unsatisfied
     environment markers and skipping anything in TORCH_FAMILY.
  3. Across all parents, intersect the version specifiers per package so the
     final constraint reflects every requester (e.g. transformers ends up with
     `>=4.51.3,<=5.5.0` rather than whichever parent we saw first).
  4. For each requirement whose installed version does not satisfy the combined
     specifier (or which is not installed at all), pip-install it with
     `--no-deps --no-build-isolation`, preserving the combined specifier so pip
     picks a satisfying version.
  5. Recurse into newly-installed packages' transitives until stable.

Every install uses `--no-deps`, so pip's resolver never touches the torch
family. Cross-parent specifier intersection avoids the common failure mode
where the first-seen parent's loose specifier wins and a later, stricter
constraint is silently ignored.

Usage:
  install-deps.py <pkg> [<pkg> ...]
  install-deps.py -r <requirements-file>
"""
import argparse
import subprocess
import sys
from importlib import metadata as md

from packaging.requirements import Requirement
from packaging.specifiers import SpecifierSet

# Packages we never install or upgrade. NGC's torch stack is fixed by the base
# image; we always defer to whatever is already there.
TORCH_FAMILY = frozenset({"torch", "torchvision", "torchaudio", "torchcodec"})


def _norm(name):
    """Canonical package name per PEP 503."""
    return name.lower().replace("_", "-")


TORCH_FAMILY_NORM = frozenset(_norm(n) for n in TORCH_FAMILY)


def parse_requirements_file(path):
    specs = []
    with open(path) as f:
        for raw in f:
            line = raw.split("#", 1)[0].strip()
            if line:
                specs.append(line)
    return specs


def pip_install(*args):
    subprocess.check_call([sys.executable, "-m", "pip", "install", *args])


def declared_runtime_requires(pkg_name):
    """Yield Requirement objects for the runtime deps of an installed package."""
    try:
        raws = md.requires(pkg_name) or []
    except md.PackageNotFoundError:
        return
    for raw in raws:
        try:
            req = Requirement(raw)
        except Exception:
            continue
        if req.extras:
            continue
        if req.marker and not req.marker.evaluate():
            continue
        yield req


def installed_version(name):
    try:
        return md.distribution(name).version
    except md.PackageNotFoundError:
        return None


def intersect(a, b):
    """Intersect two SpecifierSets (commutative union of their specifiers)."""
    if not str(a):
        return b
    if not str(b):
        return a
    return SpecifierSet(",".join(filter(None, [str(a), str(b)])))


def install_recursively(top_specs):
    # plan[canonical_name] = (display_name, combined SpecifierSet)
    plan = {}
    # canonical names whose md.requires() we have walked
    walked = set()
    # canonical names we have pip-installed (top-level or transitive) this run
    installed_here = set()

    def add(req):
        key = _norm(req.name)
        if key in TORCH_FAMILY_NORM:
            return
        if key in plan:
            display, spec = plan[key]
            plan[key] = (display, intersect(spec, req.specifier))
        else:
            plan[key] = (req.name, req.specifier)

    # Phase 1: install requested top-level packages with --no-deps.
    print(
        f"install-deps: installing {len(top_specs)} top-level package(s) with --no-deps"
    )
    pip_install("--no-deps", *top_specs)
    to_walk = []
    for spec in top_specs:
        try:
            req = Requirement(spec)
        except Exception:
            print(f"WARN: cannot parse top-level spec '{spec}'", file=sys.stderr)
            continue
        add(req)
        installed_here.add(_norm(req.name))
        to_walk.append(req.name)

    # Phase 2: BFS through transitives until stable.
    while to_walk:
        # Walk requirements of newly added packages.
        for pkg in to_walk:
            key = _norm(pkg)
            if key in walked:
                continue
            walked.add(key)
            for req in declared_runtime_requires(pkg):
                add(req)

        # Decide what needs installing (or upgrading) in this pass.
        to_install = []  # list of (canonical_key, display, install_str)
        candidates_already_ok = []  # display names already satisfied — walk their deps
        for key, (display, spec) in plan.items():
            if key in installed_here:
                continue
            version = installed_version(display)
            spec_str = str(spec)
            if version is not None and (not spec_str or version in spec):
                installed_here.add(key)
                candidates_already_ok.append(display)
                continue
            install_str = f"{display}{spec_str}" if spec_str else display
            to_install.append((key, display, install_str))

        next_walk = list(candidates_already_ok)

        if to_install:
            print(
                f"install-deps: installing {len(to_install)} package(s) with --no-deps:"
            )
            for _, _, s in to_install:
                print(f"  - {s}")
            pip_install(
                "--no-deps", "--no-build-isolation", *[s for _, _, s in to_install]
            )
            for key, display, _ in to_install:
                installed_here.add(key)
                next_walk.append(display)

        to_walk = next_walk


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-r", "--requirements", help="requirements file")
    ap.add_argument("packages", nargs="*", help="package specs")
    args = ap.parse_args()

    specs = list(args.packages)
    if args.requirements:
        specs.extend(parse_requirements_file(args.requirements))
    if not specs:
        print("install-deps: nothing to install", file=sys.stderr)
        return 0

    install_recursively(specs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
