#!/usr/bin/env bash
set -euo pipefail

# Applies Patrick's curated macOS user-domain defaults across exactly four
# domains -- Dock, Finder, keyboard & trackpad, screenshots & misc (D-01).
# Every value below is a delta from a clean macOS factory default, taken
# directly from a `defaults read` of this machine (D-02/D-03) -- not an
# imported opinionated baseline (e.g. Mathias Bynens' .macos). User-domain
# only: no `sudo`, no /Library writes, runs fully unattended with no
# password prompt (D-04). Intentionally never invoked by bootstrap.sh or
# bin/dot (D-07) -- see 05-CONTEXT.md. Does not force-restart Dock/Finder/
# SystemUIServer, to avoid a visible flash or closed windows -- it prints a
# note instead (D-05).

macos_dock() {
  defaults write com.apple.dock autohide -bool true
  defaults write com.apple.dock show-recents -bool false
  defaults write com.apple.dock tilesize -float 56
  defaults write com.apple.dock wvous-bl-corner -int 5
  defaults write com.apple.dock wvous-bl-modifier -int 0
  defaults write com.apple.dock wvous-br-corner -int 14
}

macos_finder() {
  defaults write com.apple.finder FXPreferredViewStyle -string "clmv"
}

macos_keyboard_trackpad() {
  defaults write NSGlobalDomain KeyRepeat -float 2
  defaults write NSGlobalDomain InitialKeyRepeat -float 15
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true
  defaults write NSGlobalDomain com.apple.springing.enabled -bool true
  defaults write NSGlobalDomain com.apple.springing.delay -float 0.5
}

macos_screenshots_misc() {
  # No screenshot-related defaults are currently set on this machine (a live
  # `defaults read com.apple.screencapture` shows only internal bookkeeping
  # keys -- last-analytics-stamp, last-selection, last-selection-display --
  # no location/type/disable-shadow deltas from factory). Per D-02/D-03,
  # nothing is codified here until Patrick actually customizes screenshot
  # behavior; this function is kept so the four-domain structure (D-01)
  # stays explicit and easy to extend later.
  :
}

macos_dock
macos_finder
macos_keyboard_trackpad
macos_screenshots_misc

echo "macos.sh: done. Some changes take effect after logout or after relaunching the affected app."
