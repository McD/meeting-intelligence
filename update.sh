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
MY_NAME=$(grep '^MY_NAME=' ~/.briefings_config | cut -d= -f2-)
LOOKBACK_DAYS=$(grep '^LOOKBACK_DAYS=' ~/.briefings_config | cut -d= -f2)
[ -z "$MY_EMAIL" ] && fail "MY_EMAIL missing from ~/.briefings_config. Re-run install.sh."
[ -z "$COMPANY_DOMAIN" ] && fail "COMPANY_DOMAIN missing from ~/.briefings_config. Re-run install.sh."
# MY_NAME falls back to local-part of MY_EMAIL; LOOKBACK_DAYS defaults to 60.
[ -z "$MY_NAME" ] && MY_NAME="${MY_EMAIL%%@*}"
[ -z "$LOOKBACK_DAYS" ] && LOOKBACK_DAYS=60
MY_FIRST_NAME="${MY_NAME%% *}"

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

# ── Re-install command files with identity substitution ─────────────────────
# The command .md files reference identity values as $MY_EMAIL, $COMPANY_DOMAIN,
# $MY_NAME, $MY_FIRST_NAME, $LOOKBACK_DAYS (both bare and braced forms). We
# substitute these to LITERAL values at install time so Claude never generates
# runtime lookup shell (like `MY_EMAIL=$(grep ...)`) whose leading token is a
# variable assignment — those bypass the allowlist and cause permission-prompt
# floods. Only dollar-prefixed forms are substituted; bare occurrences like
# `os.environ["MY_EMAIL"]` (a Python string literal) are left untouched.
mkdir -p ~/.claude/commands
MY_EMAIL="$MY_EMAIL" COMPANY_DOMAIN="$COMPANY_DOMAIN" MY_NAME="$MY_NAME" \
MY_FIRST_NAME="$MY_FIRST_NAME" LOOKBACK_DAYS="$LOOKBACK_DAYS" \
SRC="$SCRIPT_DIR/commands" DST="$HOME/.claude/commands" \
python3 <<'PYEOF' || fail "Command file substitution failed."
import os, re
from pathlib import Path

vars = {k: os.environ[k] for k in ("MY_EMAIL", "COMPANY_DOMAIN", "MY_NAME", "MY_FIRST_NAME", "LOOKBACK_DAYS")}
src, dst = Path(os.environ["SRC"]), Path(os.environ["DST"])

# Match $VAR (word-boundary) and ${VAR} — dollar-prefixed only, so Python string
# literals like os.environ["MY_EMAIL"] are safe.
patterns = [(re.compile(r'\$\{' + name + r'\}|\$' + name + r'\b'), value)
            for name, value in vars.items()]

for md in ("briefing.md", "follow-up.md", "digest.md"):
    text = (src / md).read_text()
    for pat, val in patterns:
        text = pat.sub(val, text)
    (dst / md).write_text(text)
PYEOF
ok "briefing.md, follow-up.md, and digest.md installed (identity substituted)."

# ── Re-install scheduler ─────────────────────────────────────────────────────
mkdir -p ~/Briefings
cp "$SCRIPT_DIR/scripts/scheduler.sh" ~/Briefings/scheduler.sh
chmod +x ~/Briefings/scheduler.sh
ok "scheduler.sh updated."

# ── Install/refresh TCC stuck-row cleanup helper ─────────────────────────────
# claude-tcc-unstick clears auth_value=5 rows from ~/Library/Application
# Support/com.apple.TCC/TCC.db for known active binaries (Claude Code per-
# version path, gtimeout from Homebrew coreutils). Sequoia's
# kTCCServiceSystemPolicyAppData consent storage writes auth_value=5 for
# adhoc-signed CLI binaries instead of the expected auth_value=2, causing
# recurring "would like to access data from other apps" prompts. Running this
# helper after a prompt fires forces the next access to take the fresh-consent
# path (writes auth_value=2 cleanly). See docs/solutions/integration-issues/
# macos-sequoia-tcc-gtimeout-stuck-state-2026-06-01.md for the full pattern.
#
# Optional opt-in: scripts/tcc-unstick.plist.template ships a launchd plist
# that runs this helper daily at 06:00. Not installed by default.
mkdir -p ~/.local/bin
cp "$SCRIPT_DIR/scripts/claude-tcc-unstick" ~/.local/bin/claude-tcc-unstick
chmod +x ~/.local/bin/claude-tcc-unstick
ok "claude-tcc-unstick installed to ~/.local/bin/."

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

# ── Ensure tool permissions are up to date ───────────────────────────────────
# New permissions may be required by updated command files. Merge without
# removing any existing entries the user may have added themselves.
MERGE_RESULT=$(HOME="$HOME" python3 <<'PYEOF'
import json, os

settings_path = os.path.join(os.environ['HOME'], '.claude', 'settings.json')
home = os.environ['HOME']

REQUIRED = [
    # Space-before-wildcard is the current Claude Code pattern form. Historical
    # colon-form (`Bash(foo:*)`) was silently no-op'd by a Claude Code syntax
    # migration in mid-2026, causing prompt-flood regressions — do NOT revert.
    "Bash(gws *)", "Bash(python3 *)", "Bash(curl *)", "Bash(date *)",
    "Bash(ls *)", "Bash(find *)", "Bash(grep *)", "Bash(mv *)",
    "Bash(chmod *)", "Bash(cat *)", "Bash(readlink *)", "Bash(echo *)",
    "Bash(sqlite3 *)",
    f"Read({home}/.briefings_config)",
    f"Read({home}/.slack_webhook)",
    f"Read({home}/Briefings/*)",
    f"Read({home}/.briefings/*)",
    f"Read({home}/Documents/*)",
    f"Read({home}/Desktop/*)",
    f"Read({home}/Downloads/*)",
    f"Write({home}/Briefings/*)",
    "mcp__claude_ai_Gmail__search_threads",
    "mcp__claude_ai_Gmail__get_thread",
    "mcp__claude_ai_Gmail__list_labels",
    "mcp__claude_ai_Gmail__list_drafts",
    "mcp__claude_ai_Gmail__create_draft",
    "mcp__claude_ai_Gmail__label_message",
    "mcp__claude_ai_Gmail__label_thread",
    "mcp__claude_ai_Gmail__unlabel_message",
    "mcp__claude_ai_Gmail__unlabel_thread",
    "mcp__claude_ai_Google_Calendar__list_events",
    "mcp__claude_ai_Google_Calendar__get_event",
    "mcp__claude_ai_Google_Calendar__list_calendars",
    "mcp__claude_ai_Google_Drive__search_files",
    "mcp__claude_ai_Google_Drive__read_file_content",
    "mcp__claude_ai_Google_Drive__download_file_content",
    "mcp__claude_ai_Google_Drive__get_file_metadata",
    "mcp__claude_ai_Slack__slack_send_message",
    "mcp__claude_ai_Slack__slack_search_public_and_private",
    "mcp__claude_ai_Slack__slack_search_users",
    "mcp__claude_ai_Slack__slack_read_channel",
    "mcp__claude_ai_Slack__slack_read_thread",
    "mcp__claude_ai_Slack__slack_read_user_profile",
    "mcp__briefings__search_decisions",
    "mcp__briefings__get_decision_by_id",
    "mcp__briefings__list_attendees",
    "WebFetch(*)",
    "WebSearch(*)",
]

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
try:
    with open(settings_path) as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

perms = settings.setdefault('permissions', {})
existing = set(perms.get('allow', []))
added = [e for e in REQUIRED if e not in existing]

if added:
    perms['allow'] = list(existing | set(REQUIRED))
    tmp = settings_path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    os.replace(tmp, settings_path)
    print(f"ADDED:{len(added)}")
else:
    print("PRESENT")
PYEOF
)

if echo "$MERGE_RESULT" | grep -q "^ADDED:"; then
    COUNT=$(echo "$MERGE_RESULT" | grep "^ADDED:" | cut -d: -f2)
    ok "Added $COUNT new tool permission(s) to ~/.claude/settings.json."
elif echo "$MERGE_RESULT" | grep -q "^PRESENT"; then
    ok "Tool permissions up to date."
else
    warn "Could not update ~/.claude/settings.json — re-run install.sh if the scheduler stalls."
fi

echo ""
echo -e "${GREEN}${BOLD}Update complete!${NC} Now on version $NEW_VERSION."
echo ""
