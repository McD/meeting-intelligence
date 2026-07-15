#!/bin/bash
# meeting-intelligence — Install Script
# Sets up automated meeting briefings and follow-ups on macOS.
# version: 2026-05-19

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
LAUNCH_AGENT_LABEL="com.${USER}.briefings"
PLIST_PATH="$HOME/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

echo ""
echo -e "${BOLD}Meeting Intelligence — Setup${NC}"
echo "============================="
echo ""
echo "Automated pre-meeting briefings and post-meeting follow-ups."
echo "Reads your Google Calendar, Gmail, Drive, and Slack to build context;"
echo "uses Claude Code to write the briefing; delivers to email and Slack."
echo ""
echo "Setup takes about 15 minutes. You'll be asked a few questions."
echo ""
echo "Prerequisites:"
echo "  - macOS (Apple Silicon or Intel)"
echo "  - A paid Claude Code account (Pro, Max, Team, or Enterprise)"
echo "  - A Google Workspace account"
echo ""
read -rp "Press Enter to start, or Ctrl+C to cancel..."

# ── macOS check ──────────────────────────────────────────────────────────────
if [[ "$OSTYPE" != "darwin"* ]]; then
    fail "This installer only supports macOS."
fi

# ── Required sidecar files ───────────────────────────────────────────────────
for f in commands/briefing.md commands/follow-up.md commands/digest.md scripts/scheduler.sh; do
    [ -f "$SCRIPT_DIR/$f" ] || fail "Missing required file: $f (run install.sh from the cloned repo)"
done

# ── Step 1: Homebrew ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 1: Homebrew${NC}"
if command -v brew &>/dev/null; then
    ok "Homebrew already installed."
else
    info "Installing Homebrew. Your Mac will ask for your password."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
    fi
    ok "Homebrew installed."
fi

# ── Step 2: Node.js ──────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 2: Node.js${NC}"
if command -v node &>/dev/null; then
    ok "Node.js already installed ($(node --version))."
else
    info "Installing Node.js..."
    brew install node
    ok "Node.js installed."
fi

# ── Step 3: Claude Code ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 3: Claude Code${NC}"
if command -v claude &>/dev/null || [ -f "$HOME/.local/bin/claude" ]; then
    ok "Claude Code already installed."
else
    info "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
    ok "Claude Code installed."
fi
CLAUDE=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")

echo ""
echo "Claude Code needs you to sign in (any paid plan: Pro, Max, Team, or Enterprise)."
echo "If you haven't signed in yet, open a new Terminal window and run: claude"
echo ""
read -rp "Press Enter once you're signed in to Claude..."

# ── Step 4: TCC stuck-row cleanup helper ────────────────────────────────────
# Sequoia's kTCCServiceSystemPolicyAppData consent storage writes auth_value=5
# (a "needs re-verification" placeholder) instead of auth_value=2 (allowed)
# for adhoc-signed CLI binaries like Claude Code's per-version executable.
# Without remediation, every access re-prompts the user. The helper script
# installed here clears stuck rows when invoked; an opt-in launchd plist at
# scripts/tcc-unstick.plist.template can automate the cleanup daily. See
# docs/solutions/integration-issues/macos-sequoia-tcc-gtimeout-stuck-state-
# 2026-06-01.md for the full pattern.
#
# (Prior versions of Step 4 installed Homebrew coreutils for the gtimeout
# watchdog. As of 2026-06-01 the scheduler uses a Python-based watchdog via
# /usr/bin/python3, so coreutils is no longer required.)
echo ""
echo -e "${BOLD}Step 4: TCC stuck-row cleanup helper${NC}"
mkdir -p ~/.local/bin
cp "$SCRIPT_DIR/scripts/claude-tcc-unstick" ~/.local/bin/claude-tcc-unstick
chmod +x ~/.local/bin/claude-tcc-unstick
ok "claude-tcc-unstick installed to ~/.local/bin/. Run it when a macOS TCC prompt re-fires for an adhoc-signed binary."

# ── Step 5: gws ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 5: gws — Google Workspace connector${NC}"
if command -v gws &>/dev/null; then
    ok "gws already installed."
else
    info "Installing gws..."
    npm install -g @googleworkspace/cli
    ok "gws installed."
fi

# ── Step 6: Authenticate Google ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 6: Connect your Google account${NC}"
echo ""
echo "A browser window will open. Sign in with the Google account you want"
echo "briefings to read from."
echo ""
echo -e "${YELLOW}Tip:${NC} If Chrome has multiple Google accounts signed in,"
echo "double-check that you select the right one."
echo ""
read -rp "Press Enter to open the Google sign-in..."
gws auth login

echo ""
info "Testing Google Calendar access..."
if gws calendar +agenda > /dev/null 2>&1; then
    ok "Google Calendar connected."
else
    warn "Could not verify calendar access."
    warn "If briefings don't work, run: gws auth login"
fi

# ── Step 7: Your email and company domain ────────────────────────────────────
echo ""
echo -e "${BOLD}Step 7: Your details${NC}"

# Load any existing values so re-running install is idempotent
EXISTING_EMAIL=""
EXISTING_DOMAIN=""
EXISTING_NAME=""
if [ -f ~/.briefings_config ]; then
    EXISTING_EMAIL=$(grep '^MY_EMAIL=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
    EXISTING_DOMAIN=$(grep '^COMPANY_DOMAIN=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
    EXISTING_NAME=$(grep '^MY_NAME=' ~/.briefings_config 2>/dev/null | cut -d= -f2-)
fi

echo "Briefings and follow-ups will be sent to this address."
PROMPT_EMAIL="Enter your work email"
[ -n "$EXISTING_EMAIL" ] && PROMPT_EMAIL="$PROMPT_EMAIL [$EXISTING_EMAIL]"
PROMPT_EMAIL="$PROMPT_EMAIL: "
read -rp "$PROMPT_EMAIL" MY_EMAIL
MY_EMAIL="${MY_EMAIL:-$EXISTING_EMAIL}"
[ -z "$MY_EMAIL" ] && fail "Email address is required."

echo ""
echo "Your company's email domain. This is used to classify meetings as"
echo "internal (everyone is from your company) or external (mixed/outside)."
PROMPT_DOMAIN="Enter your company domain (e.g. acme.com)"
[ -n "$EXISTING_DOMAIN" ] && PROMPT_DOMAIN="$PROMPT_DOMAIN [$EXISTING_DOMAIN]"
PROMPT_DOMAIN="$PROMPT_DOMAIN: "
read -rp "$PROMPT_DOMAIN" COMPANY_DOMAIN
COMPANY_DOMAIN="${COMPANY_DOMAIN:-$EXISTING_DOMAIN}"
[ -z "$COMPANY_DOMAIN" ] && fail "Company domain is required."

echo ""
echo "Your display name. Used to match commitments where the owner is recorded"
echo "as your full name (e.g. 'Jane Doe') rather than your email. Optional —"
echo "press Enter to skip and the matcher will fall back to the local-part of"
echo "your email."
PROMPT_NAME="Enter your full name"
[ -n "$EXISTING_NAME" ] && PROMPT_NAME="$PROMPT_NAME [$EXISTING_NAME]"
PROMPT_NAME="$PROMPT_NAME: "
read -rp "$PROMPT_NAME" MY_NAME
MY_NAME="${MY_NAME:-$EXISTING_NAME}"

umask 077
cat > ~/.briefings_config <<EOF
MY_EMAIL=$MY_EMAIL
COMPANY_DOMAIN=$COMPANY_DOMAIN
MY_NAME=$MY_NAME
EOF
ok "Saved to ~/.briefings_config"

# ── Step 8: Slack (optional) ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 8: Slack notifications (optional)${NC}"
if [ -f ~/.slack_webhook ]; then
    ok "Slack webhook already configured. Press Enter to keep, or paste a new URL to replace."
fi
echo ""
echo "Briefings can also post to a private Slack channel."
echo ""
echo "To get a webhook URL:"
echo "  1. Go to api.slack.com/apps"
echo "  2. Create an app → Incoming Webhooks → Add New Webhook"
echo "  3. Choose a private channel"
echo "  4. Copy the URL that starts with https://hooks.slack.com/..."
echo ""
read -rp "Slack webhook URL (Enter to skip/keep current): " SLACK_WEBHOOK
if [ -n "$SLACK_WEBHOOK" ]; then
    echo "$SLACK_WEBHOOK" > ~/.slack_webhook
    chmod 600 ~/.slack_webhook
    ok "Slack webhook saved."
fi

# ── Step 9: Install command files ────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 9: Installing slash commands${NC}"
mkdir -p ~/.claude/commands

cp "$SCRIPT_DIR/commands/briefing.md"  ~/.claude/commands/briefing.md
cp "$SCRIPT_DIR/commands/follow-up.md" ~/.claude/commands/follow-up.md
cp "$SCRIPT_DIR/commands/digest.md"    ~/.claude/commands/digest.md
ok "/briefing, /follow-up, and /digest installed."

echo ""
echo -e "${YELLOW}Note:${NC} If you have Claude Code open in another window, close and"
echo "reopen it so the new commands are picked up before the Step 13 test."

# ── Step 10: Scheduler ───────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 10: Background scheduler${NC}"
umask 077
mkdir -p ~/Briefings
cp "$SCRIPT_DIR/scripts/scheduler.sh" ~/Briefings/scheduler.sh
chmod +x ~/Briefings/scheduler.sh
ok "Scheduler script installed."

# Install LaunchAgent (better than cron — fires every 15 min and survives sleep)
if launchctl list | grep -q "$LAUNCH_AGENT_LABEL"; then
    info "Reloading existing scheduler..."
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST_PATH" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LAUNCH_AGENT_LABEL</string>

    <!-- 077 octal = 63 decimal. Forces scheduler.log to mode 600 from first creation. -->
    <key>Umask</key>
    <integer>63</integer>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$HOME/Briefings/scheduler.sh</string>
    </array>

    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Minute</key><integer>0</integer></dict>
        <dict><key>Minute</key><integer>15</integer></dict>
        <dict><key>Minute</key><integer>30</integer></dict>
        <dict><key>Minute</key><integer>45</integer></dict>
    </array>

    <key>StandardOutPath</key>
    <string>$HOME/Briefings/scheduler.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Briefings/scheduler.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>

    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST_EOF
launchctl load "$PLIST_PATH"
ok "Scheduler installed and running (fires every 15 min)."

# ── Step 11: Ledger + MCP server ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 11: Decision ledger and MCP server${NC}"
#
# v1 adds a JSONL decision ledger at ~/.briefings/decisions.jsonl and a local
# read-only MCP server (briefings_mcp) so /briefing can pull "what did we last
# decide with these attendees" inline and external Claude sessions can query
# the same corpus.
#
# Runtime layout decision: a dedicated Python venv at ~/.briefings/venv with an
# editable install of this repo. The alternatives were considered and rejected:
#   * `pip install --user` collides with PEP 668 on brew Python (which is what
#     macOS users actually have, since /usr/bin/python3 is pinned to 3.9 and
#     pyproject.toml requires >=3.10).
#   * `uv tool install` would be cleaner but isn't yet a baseline tool here;
#     adding it just for this would be friction for everyone.
# A venv is in stdlib, never collides with system packages, and editable
# install means `git pull` + `update.sh` picks up briefings_mcp/ changes with
# no re-install. The MCP server is registered as the absolute venv-python
# path, so `python -m briefings_mcp` resolves from any cwd Claude launches in.

# Step 11a: detect (or install) a Python >=3.10
RUNTIME_PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3.10; do
    if command -v "$candidate" >/dev/null 2>&1; then
        RUNTIME_PYTHON="$(command -v "$candidate")"
        break
    fi
done
if [ -z "$RUNTIME_PYTHON" ] && command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
        RUNTIME_PYTHON="$(command -v python3)"
    fi
fi
if [ -z "$RUNTIME_PYTHON" ]; then
    info "No Python ≥3.10 found. Installing via Homebrew..."
    brew install python@3.13
    RUNTIME_PYTHON="$(command -v python3.13)"
    [ -z "$RUNTIME_PYTHON" ] && fail "Could not install python3.13. Run 'brew install python@3.13' manually, then re-run install.sh."
fi
ok "Using Python: $RUNTIME_PYTHON ($("$RUNTIME_PYTHON" --version 2>&1))"

# Step 11b: ledger directory + runtime venv (idempotent)
umask 077
mkdir -p "$HOME/.briefings"
chmod 700 "$HOME/.briefings"

VENV_DIR="$HOME/.briefings/venv"
VENV_PY="$VENV_DIR/bin/python"
if [ ! -x "$VENV_PY" ]; then
    info "Creating runtime venv at $VENV_DIR..."
    "$RUNTIME_PYTHON" -m venv "$VENV_DIR" || fail "Could not create venv at $VENV_DIR"
    ok "Runtime venv created."
else
    ok "Runtime venv exists at $VENV_DIR."
fi

# Step 11c: install briefings_mcp editable so git pull propagates changes
info "Installing briefings_mcp package (editable from $SCRIPT_DIR)..."
"$VENV_PY" -m pip install --quiet --upgrade pip >/dev/null 2>&1 || warn "pip upgrade failed; continuing."
if ! "$VENV_PY" -m pip install --quiet --editable "$SCRIPT_DIR"; then
    fail "Could not install briefings_mcp. Re-run: $VENV_PY -m pip install --editable $SCRIPT_DIR"
fi
"$VENV_PY" -c "import briefings_mcp; import fastmcp" 2>/dev/null \
    || fail "briefings_mcp or fastmcp not importable from $VENV_PY after install."
ok "briefings_mcp installed (editable). fastmcp resolved."

# Step 11d: initialise the ledger file (never truncate — preserves prior decisions)
if [ ! -f "$HOME/.briefings/decisions.jsonl" ]; then
    touch "$HOME/.briefings/decisions.jsonl"
    chmod 600 "$HOME/.briefings/decisions.jsonl"
    ok "Created ~/.briefings/decisions.jsonl (mode 600)."
else
    chmod 600 "$HOME/.briefings/decisions.jsonl"
    ok "Ledger file already exists; preserved untouched."
fi

# Step 11e: append LOOKBACK_DAYS=60 to ~/.briefings_config (idempotent;
# double-append would not break anything but would clutter the config)
if ! grep -q '^LOOKBACK_DAYS=' "$HOME/.briefings_config" 2>/dev/null; then
    umask 077
    echo "LOOKBACK_DAYS=60" >> "$HOME/.briefings_config"
    ok "Added LOOKBACK_DAYS=60 to ~/.briefings_config."
else
    ok "LOOKBACK_DAYS already configured in ~/.briefings_config."
fi

# Step 11f: register MCP server (idempotent — `claude mcp add` would re-add,
# so skip if already registered)
if "$CLAUDE" mcp list 2>/dev/null | grep -qE '^briefings:'; then
    ok "MCP server 'briefings' already registered."
else
    info "Registering briefings MCP server with Claude Code..."
    if "$CLAUDE" mcp add briefings --scope user -- "$VENV_PY" -m briefings_mcp >/dev/null 2>&1; then
        ok "MCP server registered (user scope): briefings → $VENV_PY -m briefings_mcp"
    else
        warn "claude mcp add failed. Register manually with:"
        warn "  $CLAUDE mcp add briefings --scope user -- $VENV_PY -m briefings_mcp"
    fi
fi

# ── Step 12: Configure tool permissions ──────────────────────────────────────
echo ""
echo -e "${BOLD}Step 12: Configuring tool permissions${NC}"
echo ""
info "The headless scheduler runs \`claude -p\` without a user present to approve"
info "tool calls interactively. The required permissions must be pre-approved in"
info "~/.claude/settings.json so the scheduler never stalls waiting for input."
echo ""

MERGE_RESULT=$(HOME="$HOME" python3 <<'PYEOF'
import json, os

settings_path = os.path.join(os.environ['HOME'], '.claude', 'settings.json')
home = os.environ['HOME']

REQUIRED = [
    "Bash(gws:*)", "Bash(python3:*)", "Bash(curl:*)", "Bash(date:*)",
    "Bash(ls:*)", "Bash(find:*)", "Bash(grep:*)", "Bash(mv:*)",
    "Bash(chmod:*)", "Bash(cat:*)", "Bash(readlink:*)", "Bash(echo:*)",
    "Bash(sqlite3:*)",
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
    ok "Added $COUNT tool permission(s) to ~/.claude/settings.json."
    info "These cover: bash utilities (gws, python3, curl, date, ls, find, grep,"
    info "mv, chmod, cat, readlink, echo, sqlite3), read access to ~/Briefings/,"
    info "~/.briefings/, ~/Documents/, ~/Desktop/, ~/Downloads/, config files,"
    info "write access to ~/Briefings/, and all Gmail/Calendar/Drive/Slack MCP tools."
elif echo "$MERGE_RESULT" | grep -q "^PRESENT"; then
    ok "All required tool permissions already present in ~/.claude/settings.json."
else
    warn "Could not update ~/.claude/settings.json — you may need to add permissions"
    warn "manually. See the README for the full list, or re-run install.sh."
fi

# ── Step 13: Enable Claude integrations ──────────────────────────────────────
echo ""
echo -e "${BOLD}Step 13: Enable Claude integrations${NC}"
echo ""
echo -e "${YELLOW}One manual step required:${NC}"
echo ""
echo "A browser will open to claude.ai settings. You need to connect:"
echo "  - Google Calendar  (required, reads your meetings)"
echo "  - Gmail            (required, reads email context)"
echo "  - Slack            (recommended, reads Slack context)"
echo ""
open "https://claude.ai/settings/integrations" 2>/dev/null || \
    echo "Open this URL in your browser: https://claude.ai/settings/integrations"
echo ""
read -rp "Once you've enabled the integrations, press Enter..."

# ── Step 14: Test ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 14: Running a test${NC}"
info "Asking Claude to check for upcoming meetings (takes ~30 seconds)..."
echo ""

# Snapshot latest briefing's mtime so we can detect whether /briefing produced
# something new in this run (vs reporting on a pre-existing file).
PRE_MTIME=0
PRE_LATEST=$(ls -t "$HOME"/Briefings/*.md 2>/dev/null \
    | grep -vE 'followup|awaiting|scheduler' | head -1 || true)
if [ -n "$PRE_LATEST" ] && [ -f "$PRE_LATEST" ]; then
    PRE_MTIME=$(stat -f '%m' "$PRE_LATEST" 2>/dev/null \
        || stat -c '%Y' "$PRE_LATEST" 2>/dev/null || echo 0)
fi

"$CLAUDE" -p "Run /briefing all" 2>&1 | tail -10
echo ""

# Soft SITREP-shape assertion — best-effort, never fails the install. If no
# upcoming meeting exists in calendar, /briefing emits nothing and there's
# nothing to assert; if assertion fails it's a heads-up, not a blocker
# (a failed assertion here doesn't undo any of Steps 1–11).
LATEST=$(ls -t "$HOME"/Briefings/*.md 2>/dev/null \
    | grep -vE 'followup|awaiting|scheduler' | head -1 || true)
if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
    CUR_MTIME=$(stat -f '%m' "$LATEST" 2>/dev/null \
        || stat -c '%Y' "$LATEST" 2>/dev/null || echo 0)
    if [ "$CUR_MTIME" -gt "$PRE_MTIME" ]; then
        info "Checking SITREP shape in $(basename "$LATEST")..."
        VERDICT_RE='^# (DECIDE-TODAY|DELEGATE|DEFER|DECLINE|PREP-HARD|LOW-STAKES|MOVE-ASYNC) — '
        MISSING=0
        grep -qE "$VERDICT_RE"    "$LATEST" || { warn "verdict heading from closed set missing"; MISSING=1; }
        grep -qE '^## SITREP'     "$LATEST" || { warn "SITREP block missing";                  MISSING=1; }
        grep -qE '^\*\*Trap:\*\*' "$LATEST" || { warn "Trap label missing";                    MISSING=1; }
        grep -qE '^\*\*Delta:\*\*' "$LATEST" || { warn "Delta label missing";                  MISSING=1; }
        grep -qE '^\*\*Comment:\*\*' "$LATEST" || { warn "Comment label missing";              MISSING=1; }
        if [ "$MISSING" -eq 0 ]; then
            VERDICT=$(grep -E -m1 -o "$VERDICT_RE" "$LATEST" 2>/dev/null | awk '{print $2}')
            ok "Briefing landed with the SITREP shape (verdict: $VERDICT)."
        else
            warn "Briefing landed but SITREP markers were incomplete — see file for context."
            warn "  bash $SCRIPT_DIR/scripts/verify-v1.sh --with-briefing for a fresh check."
        fi
    else
        info "No new briefing this run (no upcoming meeting, or one was already on disk)."
        info "  bash $SCRIPT_DIR/scripts/verify-v1.sh --with-briefing to force a fresh one."
    fi
fi
echo ""

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo ""
echo "What to expect:"
echo "  - Before meetings: briefing email arrives up to 2 hours before"
echo "  - After meetings: follow-up email with actions arrives within 75 min"
echo "  - The scheduler checks every 15 minutes"
echo ""
echo "External meetings get the full briefing (email history, Slack, transcripts)."
echo "Internal meetings get the lighter version (Slack and shared docs)."
echo ""
echo "Useful commands:"
echo "  launchctl list | grep briefings    — confirm scheduler is running"
echo "  tail -30 ~/Briefings/scheduler.log — see what the scheduler has done"
echo "  bash <repo>/update.sh              — pull the latest version"
echo "  bash <repo>/scripts/verify-v1.sh   — end-to-end smoke check"
echo "  claude mcp list | grep briefings   — confirm MCP server is registered"
echo ""
