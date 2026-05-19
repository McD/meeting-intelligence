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
echo "  - A Claude Max subscription (for unattended scheduler runs)"
echo "  - A Google Workspace account"
echo ""
read -rp "Press Enter to start, or Ctrl+C to cancel..."

# ── macOS check ──────────────────────────────────────────────────────────────
if [[ "$OSTYPE" != "darwin"* ]]; then
    fail "This installer only supports macOS."
fi

# ── Required sidecar files ───────────────────────────────────────────────────
for f in templates/briefing.md templates/follow-up.md templates/scheduler.sh; do
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
CLAUDE=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")
if command -v claude &>/dev/null || [ -f "$HOME/.local/bin/claude" ]; then
    ok "Claude Code already installed."
else
    info "Installing Claude Code..."
    npm install -g @anthropic-ai/claude-code
    CLAUDE=$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")
    ok "Claude Code installed."
fi

echo ""
echo "Claude Code needs you to sign in (Claude Max recommended)."
echo "If you haven't signed in yet, open a new Terminal window and run: claude"
echo ""
read -rp "Press Enter once you're signed in to Claude..."

# ── Step 4: gws ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 4: gws — Google Workspace connector${NC}"
if command -v gws &>/dev/null; then
    ok "gws already installed."
else
    info "Installing gws..."
    npm install -g @googleworkspace/cli
    ok "gws installed."
fi

# ── Step 5: Authenticate Google ──────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 5: Connect your Google account${NC}"
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

# ── Step 6: Your email and company domain ────────────────────────────────────
echo ""
echo -e "${BOLD}Step 6: Your details${NC}"

# Load any existing values so re-running install is idempotent
EXISTING_EMAIL=""
EXISTING_DOMAIN=""
if [ -f ~/.briefings_config ]; then
    EXISTING_EMAIL=$(grep '^MY_EMAIL=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
    EXISTING_DOMAIN=$(grep '^COMPANY_DOMAIN=' ~/.briefings_config 2>/dev/null | cut -d= -f2)
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

umask 077
cat > ~/.briefings_config <<EOF
MY_EMAIL=$MY_EMAIL
COMPANY_DOMAIN=$COMPANY_DOMAIN
EOF
ok "Saved to ~/.briefings_config"

# ── Step 7: Slack (optional) ─────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 7: Slack notifications (optional)${NC}"
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

# ── Step 8: Install command files ────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 8: Installing slash commands${NC}"
mkdir -p ~/.claude/commands

# Substitute placeholders into the command templates
sed "s|{{COMPANY_DOMAIN}}|$COMPANY_DOMAIN|g" "$SCRIPT_DIR/templates/briefing.md"  > ~/.claude/commands/briefing.md
sed "s|{{COMPANY_DOMAIN}}|$COMPANY_DOMAIN|g" "$SCRIPT_DIR/templates/follow-up.md" > ~/.claude/commands/follow-up.md
ok "/briefing and /follow-up installed."

echo ""
echo -e "${YELLOW}Note:${NC} If you have Claude Code open in another window, close and"
echo "reopen it so the new commands are picked up before the Step 11 test."

# ── Step 9: Scheduler ────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 9: Background scheduler${NC}"
umask 077
mkdir -p ~/Briefings
cp "$SCRIPT_DIR/templates/scheduler.sh" ~/Briefings/scheduler.sh
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

# ── Step 10: Enable Claude integrations ──────────────────────────────────────
echo ""
echo -e "${BOLD}Step 10: Enable Claude integrations${NC}"
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

# ── Step 11: Test ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 11: Running a test${NC}"
info "Asking Claude to check for upcoming meetings (takes ~30 seconds)..."
echo ""
"$CLAUDE" -p --dangerously-skip-permissions "Run /briefing all" 2>&1 | tail -10
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
echo ""
