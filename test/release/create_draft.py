#!/usr/bin/env python3
"""Attach verified assets to a draft. Never edit an already-published release."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess

from release_artifact import ROOT, inspect_archive, metadata, validate_windows_report


def gh(*arguments, check=True):
    result = subprocess.run(["gh", *map(str, arguments)], text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "GitHub CLI operation failed")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset-directory", type=Path, required=True)
    parser.add_argument("--windows-report", type=Path, required=True)
    args = parser.parse_args()
    release = metadata()
    assert os.environ.get("GITHUB_REPOSITORY") == release["repository"], "Wrong release repository"
    assert os.environ.get("GITHUB_REF_TYPE") == "tag", "Release requires an existing pushed tag"
    assert os.environ.get("GITHUB_REF_NAME") == release["tag"], "Release tag differs from metadata"
    archive = args.asset_directory / release["asset_name"]
    checksum = Path(str(archive) + ".sha256")
    files, digest = inspect_archive(archive, release, checksum)
    validate_windows_report(args.windows_report, digest, release["version"], files)
    notes = ROOT / "docs/releases" / (release["version"] + ".md")
    assert notes.is_file(), "Release notes are missing"
    title = release["product_name"] + " " + release["display_version"]
    common = ["--repo", release["repository"]]
    previous = gh("release", "view", release["tag"], *common, "--json", "isDraft", check=False)
    assets = [archive, checksum, args.windows_report]
    if previous.returncode == 0:
        assert json.loads(previous.stdout)["isDraft"], "Refusing to replace a published release"
        gh("release", "upload", release["tag"], *assets, *common, "--clobber")
        result = gh("release", "edit", release["tag"], *common, "--draft",
                    "--title", title, "--notes-file", notes)
    else:
        # Do not turn network/authentication errors into a second mutation attempt.
        assert "release not found" in previous.stderr.lower(), previous.stderr
        result = gh("release", "create", release["tag"], *assets, *common,
                    "--verify-tag", "--draft", "--title", title, "--notes-file", notes)
    print(result.stdout.strip() or f"Updated draft {release['tag']}")


if __name__ == "__main__":
    main()
