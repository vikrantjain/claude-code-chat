#!/bin/sh
set -e

# Install MCP dependencies
cd /app
bun install --frozen-lockfile

exec claude "$@"
