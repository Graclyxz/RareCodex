"""Every `run:` script in the GitHub workflows must be valid bash after YAML parsing.

Catches YAML pitfalls such as `run: printf 'Closes #%s'`, where " #" silently starts a YAML
comment and truncates the command.
"""

import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"
BASH = shutil.which("bash")


def run_scripts() -> list[tuple[str, str]]:
    scripts = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        for job_name, job in doc["jobs"].items():
            for index, step in enumerate(job["steps"]):
                if "run" in step:
                    scripts.append(
                        (f"{path.name}:{job_name}:{step.get('name', index)}", step["run"])
                    )
    return scripts


@pytest.mark.skipif(BASH is None, reason="bash not available")
@pytest.mark.parametrize(("where", "script"), run_scripts(), ids=lambda v: v if ":" in v else "")
def test_run_script_is_valid_bash(where: str, script: str) -> None:
    assert BASH is not None
    result = subprocess.run([BASH, "-n"], input=script, capture_output=True, text=True, check=False)
    assert result.returncode == 0, f"{where}: {result.stderr}"
