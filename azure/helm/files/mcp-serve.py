# flyte-mcp builds uvicorn.Config(app, port=port) and has no --host flag, so uvicorn would bind 127.0.0.1 and the
# pod would never be reachable. Default the host to all interfaces, then run the CLI unchanged.
import sys

import uvicorn

_init = uvicorn.Config.__init__


def _init_all_interfaces(self, *args, **kwargs):
    kwargs.setdefault("host", "0.0.0.0")
    _init(self, *args, **kwargs)


uvicorn.Config.__init__ = _init_all_interfaces

from flyte._bin.mcp import main  # noqa: E402

sys.exit(main())
