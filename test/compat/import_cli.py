#!/usr/bin/env python3
"""Test relative importer paths, deliberate input gaps and a complete import."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
runtime = Path(os.environ["W2L_TEST_RUNTIME"])
source = root / "data/warcraft-current/mpq"
gaps = ("units/humanunitstrings.txt", "ui/triggerstrings.txt")
with tempfile.TemporaryDirectory(prefix="w2l-import-cli-", dir=root.parent) as folder:
    temporary = Path(folder)
    raw = temporary / "mpq"
    shutil.copytree(source, raw)
    for name in gaps:
        (raw / name).unlink()
    target = root / "data" / temporary.name
    assert not target.exists(), "Test destination already exists"
    cases = [
        (root, "make/import-game-data.lua"),
        (root.parent, str(root / "make/import-game-data.lua")),
    ]
    try:
        for cwd, script in cases:
            result = subprocess.run(
                [str(runtime / "lua"), script, os.path.relpath(raw, cwd), target.name],
                cwd=cwd, text=True, capture_output=True, check=False,
            )
            assert result.returncode == 2, result.stdout + result.stderr
            for name in gaps:
                assert name in result.stdout, result.stdout + result.stderr
            assert "No generated files were written" in result.stdout
            assert not target.exists(), "Strict incomplete import created a dataset"

        # Restore only the intentional gaps, then exercise the same relative
        # source from outside the repository through the normal CLI save path.
        for name in gaps:
            shutil.copyfile(source / name, raw / name)
        cwd, script = cases[-1]
        result = subprocess.run(
            [str(runtime / "lua"), script, os.path.relpath(raw, cwd), target.name],
            cwd=cwd, text=True, capture_output=True, check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert "required input files present" in result.stdout
        assert (target / "version").read_bytes() == (source.parent / "version").read_bytes()
        assert b'name="Footman"' in (target / "prebuilt/melee/unit.ini").read_bytes()
        assert (target / "ui/triggerstrings.txt").read_bytes() == (source / "ui/triggerstrings.txt").read_bytes()
        # Extra supplied files must survive staging even when the converter
        # does not need them to generate its object defaults.
        assert (target / "mpq/units/unitglobalstrings.txt").read_bytes() == (source / "units/unitglobalstrings.txt").read_bytes()
    finally:
        if target.exists():
            shutil.rmtree(target)
print("PASS importer resolves relative source paths; deliberate missing-input runs write nothing; complete input saves a selectable dataset with localization and raw extras")
