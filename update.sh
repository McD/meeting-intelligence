#!/bin/bash
# meeting-intelligence — Update Script
# Pulls the latest version from git, re-installs commands and scheduler.
# version: 2026-05-27 Phase 3 — registers commands/digest.md alongside briefing.md and follow-up.md; version detection takes max date across all three.
#
# Run from inside the cloned repo: bash update.sh

set -e

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${BOLD}→${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${BOLD}Meeting Intelligence — Update${NC}"
echo "=============================="
echo ""

# ── Load existing config ─────────────────────────────────────────────────────
[ -f ~/.briefings_config ] || fail "No ~/.briefings_config found. Run install.sh first."
MY_EMAIL=$(grep '^MY_EMAIL=' ~/.briefings_config | cut -d= -f2)
COMPANY_DOMAIN=$(grep '^COMPANY_DOMAIN=' ~/.briefings_config | cut -d= -f2)
[ -z "$MY_EMAIL" ] && fail "MY_EMAIL missing from ~/.briefings_config. Re-run install.sh."
[ -z "$COMPANY_DOMAIN" ] && fail "COMPANY_DOMAIN missing from ~/.briefings_config. Re-run install.sh."

# ── Pull latest from git ─────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
if [ -d .git ]; then
    info "Pulling latest from git..."
    git pull --ff-only || fail "git pull failed. Resolve manually and re-run."
    ok "Repo up to date."
else
    warn "Not a git checkout — skipping pull, using local templates as-is."
fi

# ── Check sidecar files exist ────────────────────────────────────────────────
for f in commands/briefing.md commands/follow-up.md commands/digest.md scripts/scheduler.sh; do
    [ -f "$SCRIPT_DIR/$f" ] || fail "Missing required file: $f"
done

# ── Show version change ──────────────────────────────────────────────────────
# The plugin "version" is the most recent date stamp across all command files —
# /briefing or /follow-up may move independently, so take the max of both.
extract_version() {
    local briefing_md="$1/commands/briefing.md"
    local followup_md="$1/commands/follow-up.md"
    local digest_md="$1/commands/digest.md"
    { grep -m1 'version:' "$briefing_md" 2>/dev/null; \
      grep -m1 'version:' "$followup_md" 2>/dev/null; \
      grep -m1 'version:' "$digest_md"   2>/dev/null; } \
        | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' \
        | sort -r \
        | head -1
}
NEW_VERSION=$(extract_version "$SCRIPT_DIR")
NEW_VERSION=${NEW_VERSION:-unknown}
OLD_VERSION=$(extract_version "$HOME/.claude")
OLD_VERSION=${OLD_VERSION:-unknown}
if [ "$NEW_VERSION" = "$OLD_VERSION" ] && [ "$OLD_VERSION" != "unknown" ]; then
    info "Already on latest version ($OLD_VERSION). Re-applying anyway."
else
    info "Updating from $OLD_VERSION → $NEW_VERSION"
fi

# ── Re-install command files ─────────────────────────────────────────────────
mkdir -p ~/.claude/commands
cp "$SCRIPT_DIR/commands/briefing.md"  ~/.claude/commands/briefing.md
cp "$SCRIPT_DIR/commands/follow-up.md" ~/.claude/commands/follow-up.md
cp "$SCRIPT_DIR/commands/digest.md"    ~/.claude/commands/digest.md
ok "briefing.md, follow-up.md, and digest.md updated."

# ── Re-install scheduler ─────────────────────────────────────────────────────
mkdir -p ~/Briefings
cp "$SCRIPT_DIR/scripts/scheduler.sh" ~/Briefings/scheduler.sh
chmod +x ~/Briefings/scheduler.sh
ok "scheduler.sh updated."

# ── Refresh briefings_mcp runtime ────────────────────────────────────────────
# Editable install means git pull above has already propagated source changes;
# a re-install only matters when pyproject.toml dependencies have changed
# (e.g. a fastmcp pin bump). Doing it unconditionally is cheap and keeps drift
# from accumulating silently.
VENV_DIR="$HOME/.briefings/venv"
VENV_PY="$VENV_DIR/bin/python"

if [ ! -x "$VENV_PY" ]; then
    warn "Runtime venv missing at $VENV_DIR. Re-run install.sh to set it up."
else
    info "Refreshing briefings_mcp package..."
    if "$VENV_PY" -m pip install --quiet --editable "$SCRIPT_DIR"; then
        ok "briefings_mcp refreshed (editable install)."
    else
        warn "pip install failed. Re-run: $VENV_PY -m pip install --editable $SCRIPT_DIR"
    fi

    # Re-validate MCP registration. If the entry was removed (e.g. user reset
    # claude config), re-add it pointing at the same venv python.
    CLAUDE_BIN="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"
    if [ -x "$CLAUDE_BIN" ] || command -v claude >/dev/null 2>&1; then
        if "$CLAUDE_BIN" mcp list 2>/dev/null | grep -qE '^briefings:'; then
            ok "MCP server 'briefings' is registered."
        else
            info "MCP server 'briefings' not registered. Adding..."
            if "$CLAUDE_BIN" mcp add briefings --scope user -- "$VENV_PY" -m briefings_mcp >/dev/null 2>&1; then
                ok "MCP server registered."
            else
                warn "Could not register. Run: $CLAUDE_BIN mcp add briefings --scope user -- $VENV_PY -m briefings_mcp"
            fi
        fi
    else
        warn "claude CLI not found. Skipping MCP re-registration check."
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}Update complete!${NC} Now on version $NEW_VERSION."
echo ""
