"""Entry point so `python -m briefings_mcp` starts the stdio MCP server.

Critical stdio rule: stdout carries JSON-RPC framed traffic, so a stray `print()` corrupts
the protocol. All diagnostic output goes through Python `logging` to stderr; the FastMCP
banner is suppressed for the same reason. This is the only correct place to configure
logging — importing modules must not call `basicConfig`.
"""

from __future__ import annotations

import logging
import os
import sys

from .server import mcp


def _configure_logging() -> None:
    """Send all logs to stderr at a level the user can tune via BRIEFINGS_MCP_LOG_LEVEL."""
    level_name = os.environ.get("BRIEFINGS_MCP_LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)
    handler = logging.StreamHandler(stream=sys.stderr)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)


def main() -> None:
    _configure_logging()
    logging.getLogger(__name__).info("Starting briefings MCP server (stdio)")
    # Default transport is stdio. show_banner=False keeps the FastMCP rich banner out of the
    # protocol stream (it goes to stderr anyway, but the noise is unnecessary).
    mcp.run(show_banner=False)


if __name__ == "__main__":
    main()
