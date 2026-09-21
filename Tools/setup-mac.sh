#!/usr/bin/env bash
# One-time setup for a Mac that has Xcode and nothing else.
#
# Installs Homebrew if it is missing, then XcodeGen, then generates the Xcode
# project. Safe to run more than once: everything it does is a no-op when the
# thing is already there.
set -uo pipefail

cd "$(dirname "$0")/.."
ok()   { printf "  \033[32mok\033[0m    %s\n" "$1"; }
step() { printf "\n\033[1m%s\033[0m\n" "$1"; }
warn() { printf "  \033[33mnote\033[0m  %s\n" "$1"; }
die()  { printf "  \033[31mstop\033[0m  %s\n" "$1"; exit 1; }

step "1. Xcode"
if ! command -v xcodebuild >/dev/null 2>&1; then
    die "Xcode is not installed, or its command line tools are not selected.
        Install Xcode from the App Store, open it once to accept the licence,
        then run: sudo xcode-select -s /Applications/Xcode.app"
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    die "Xcode is installed but not usable yet. Open Xcode once to accept the
        licence and let it install its components, then run this again."
fi
ok "$(xcodebuild -version | head -1)"

step "2. Command line tools"
if ! xcode-select -p >/dev/null 2>&1; then
    warn "Installing. A dialog will appear; accept it, wait, then run this again."
    xcode-select --install
    exit 1
fi
ok "$(xcode-select -p)"

step "3. Python"
command -v python3 >/dev/null 2>&1 || die "python3 not found. It normally comes with the command line tools."
ok "$(python3 --version)"

step "4. Homebrew"
if ! command -v brew >/dev/null 2>&1; then
    warn "Not installed. Installing now; it will ask for your password."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || die "Homebrew install failed."
    # Apple Silicon puts brew somewhere not on the default PATH, which is the
    # single most common reason the next step fails on a new Mac.
    for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        [ -x "$candidate" ] && eval "$("$candidate" shellenv)" && break
    done
    command -v brew >/dev/null 2>&1 || die "Homebrew installed but is not on your PATH.
        Close this window, open a new one, and run this script again."
fi
ok "$(brew --version | head -1)"

step "5. XcodeGen"
if ! command -v xcodegen >/dev/null 2>&1; then
    warn "Installing."
    brew install xcodegen || die "Could not install XcodeGen."
fi
ok "xcodegen $(xcodegen --version 2>&1 | tail -1)"

step "6. Generating the Xcode project"
xcodegen generate >/dev/null || die "xcodegen failed. Run 'xcodegen generate' to see why."
ok "WalkTracker.xcodeproj"

step "Done"
cat <<'NEXT'
  Next, in order:

  1. Give the app your own identifier. Open project.yml and change BOTH lines
     that say com.example.walktracker to something unique, for example
     com.yourname.walktracker and com.yourname.walktracker.tests.
     Apple will not sign anything under com.example.

  2. Re-run:  xcodegen generate

  3. Open it:  open WalkTracker.xcodeproj

  4. In Xcode: Settings, Accounts, add your Apple ID. A free one is fine.
     Then select the WalkTracker target, Signing and Capabilities, and pick
     your name under Team.

  5. Pick an iPhone simulator at the top and press Run. The first build takes
     a few minutes.

  6. Build street data:  cd Tools/citypack && ./fetch_and_build.sh manhattan

  See docs/first-run.md for the rest, including putting it on a real iPhone.
NEXT
