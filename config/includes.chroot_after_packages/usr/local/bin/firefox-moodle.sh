#!/bin/bash
# firefox-moodle.sh
# Opens Moodle MSE in a locked private kiosk window.
# Uses an isolated /tmp profile so it never conflicts with other Firefox instances.

PROFILE="/tmp/ff-moodle"
URL="https://moodle.msengineering.ch"

# Create a fresh profile directory on each launch
rm -rf "${PROFILE}"
mkdir -p "${PROFILE}"

# Write user.js preferences to lock down the browser
cat > "${PROFILE}/user.js" << 'PREFS'
// Disable address bar editing
user_pref("browser.urlbar.readonly", true);

// Disable new tab page content
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.newtab.url", "about:blank");

// Disable password manager
user_pref("signon.rememberSignons", false);

// Disable telemetry
user_pref("toolkit.telemetry.enabled", false);

// Suppress first-run UI
user_pref("browser.startup.firstrunSkipsHomepage", true);
user_pref("trailhead.firstrun.didSeeAboutWelcome", true);
PREFS

exec firefox \
  --profile "${PROFILE}" \
  --no-remote \
  --kiosk \
  --private-window \
  "${URL}"
