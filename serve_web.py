#!/usr/bin/env python3
"""Launcher for the unified Flutter WebAssembly + Live WebSocket 1v1 Room Server."""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_MJS = os.path.join(HERE, "serve_arena.mjs")

if __name__ == "__main__":
    os.execvp("node", ["node", SERVER_MJS, *sys.argv[1:]])
