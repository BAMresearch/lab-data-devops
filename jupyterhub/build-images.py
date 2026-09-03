#!/usr/bin/env python3
# ~/bin/build-images.py
"""Build repo2docker images from repos.toml. Skips repos already built at
their current remote HEAD. Writes images.generated.toml listing successes."""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

import tomli_w
import tomllib


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Build repo2docker images listed in a TOML file and "
                    "write a manifest of successfully built images.")
    p.add_argument(
        "-i", "--infile",
        default=Path("~/jupyterhub/config/repos.toml").expanduser(),
        help="input TOML listing repos to build (default: %(default)s)")
    p.add_argument(
        "-o", "--outfile",
        default=Path("~/jupyterhub/config/images.generated.toml").expanduser(),
        help="output manifest of built images (default: %(default)s)")
    p.add_argument(
        "-e", "--venv",
        default=Path("~/.venvs/r2d").expanduser(),
        help="virtualenv containing jupyter-repo2docker (default: %(default)s)")
    p.add_argument(
        "-f", "--force", action="store_true",
        help="rebuild even if an image for the current SHA already exists")
    return p.parse_args(argv)


def slug(url, ref):
    owner, name = Path(url).parts[-2:]
    slug = f"{owner}-{name.split(".")[0]}-{ref}".lower()
    return re.sub(r"[^a-z0-9]+", "-", slug).strip("-")


def exists(tag):
    args = ["podman", "image", "exists", tag]
    return (subprocess.run(args, check=False).returncode == 0)


def remote_sha(url, ref):
    args = ["git", "ls-remote", url, ref]
    out = subprocess.run(args, capture_output=True, text=True, check=True)
    if not out.stdout.strip():
        raise RuntimeError(f"ref {ref!r} not found at {url}")
    return out.stdout.split()[0]


def main(argv=None):
    args = parse_args(argv)
    r2d = Path(args.venv) / "bin" / "jupyter-repo2docker"
    if not os.access(r2d, os.X_OK):
        sys.exit(f"repo2docker not found or not executable at {r2d} (check --venv)")
    cfg = {}
    with open(args.infile, "rb") as fd:
        cfg = tomllib.load(fd)
    built, failed = [], []

    BUILD_ERRORS = (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError)

    timeoutSec = 150
    for i, r in enumerate(cfg.get("repo", [])):
        try:
            label = r["label"]
            url = r["url"]
            ref = r.get("ref", "HEAD")
            assert len(label)
            assert len(url)
            assert len(ref)
        except (KeyError, AssertionError) as e:
            print(f"repo #{i}: missing required field (label or url) {e}",
                  file=sys.stderr)
            failed.append(f"#{i}")
            continue

        base = f"localhost/binder-{slug(url, ref)}"
        try:
            sha = remote_sha(url, ref)
            tag = f"{base}:{sha[:12]}"
            if args.force or not exists(tag):
                subprocess.run([r2d, "--no-run", "--image-name", tag, "--ref", sha, url], check=True)
            subprocess.run(["podman", "tag", tag, f"{base}:latest"], check=True)
            built.append(
                {
                    "label": label,
                    "image": f"{base}:latest",
                    "index_ipynb": r.get("index_ipynb", "/lab"),
                }
            )
            # start the container once headless so first-run caches land in a committed layer
            # or at least prove the cold start completes
            # Bounded by `timeout` with SIGTERM (graceful) rather than Python's SIGKILL,
            # so podman tears down its container/layer cleanly if the limit is hit."""
            #subprocess.run(["podman", "run", "--rm",
            #                "-e", "JUPYTERHUB_SERVICE_URL=http://localhost:8888",
            #                "-e", "JUPYTERHUB_API_TOKEN=dummy",
            #                tag, "jupyterhub-singleuser", "--version"],
            #               check=True, timeout=120)
            cmd = ["timeout", "--signal=TERM", str(timeoutSec),
                   "podman", "run", "--rm",
                   "-e", "JUPYTERHUB_SERVICE_URL=http://localhost:8888",
                   "-e", "JUPYTERHUB_API_TOKEN=dummy",
                   tag, "jupyterhub-singleuser", "--version"]
            r = subprocess.run(cmd, capture_output=True, text=True,
                               timeout=int(timeoutSec*1.2),  # backstop only, > the 60s TERM
                               check=True)
            print(f"warm up {label}:", r.stdout.strip(), file=sys.stderr)
        except BUILD_ERRORS as e:
            print(f"{label}: build failed: {e}", file=sys.stderr)
            print(e.stderr, file=sys.stderr)
            failed.append(label)
    with open(args.outfile, "wb") as fd:
        tomli_w.dump({"repo": built}, fd)
    if failed:
        print(f"failed: {', '.join(failed)}", file=sys.stderr)


if __name__ == "__main__":
    main()
