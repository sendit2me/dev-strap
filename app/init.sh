#!/bin/sh
# =============================================================================
# App Init Script
# =============================================================================
# This runs inside the app container after the stack starts.
# Use it for project-specific initialization (migrations, seeding, etc.)
# =============================================================================

echo "[init] Installing dependencies..."
cd /app && npm install --silent

echo "[init] App initialization complete."
