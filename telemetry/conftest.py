"""Root conftest.py: ensure the telemetry package from this source tree is used.

When `/home/robert_li/dgx-toolbox` is on sys.path, Python discovers
`dgx-toolbox/telemetry/` as a namespace package and shadows the editable
install. Inserting the package source root ahead of sys.path fixes the
resolution order so `import telemetry` finds the correct package.
"""
import sys
import pathlib

# Insert the telemetry source root at the front so `import telemetry` resolves
# to dgx-toolbox/.../telemetry/telemetry/ (the actual package) rather than
# the namespace package at dgx-toolbox/telemetry/ (which has no modules).
_here = pathlib.Path(__file__).parent.resolve()
if str(_here) not in sys.path:
    sys.path.insert(0, str(_here))
