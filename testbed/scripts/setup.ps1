# One-time: creates testbed\.venv with pytest. run-task.ps1 puts it first on the agent's PATH.
. "$PSScriptRoot\common.ps1"

if (-not (Test-Path $VenvPython)) { python -m venv $VenvDir }
& $VenvPython -m pip install --quiet --disable-pip-version-check --upgrade pytest
& $VenvPython -m pytest --version
