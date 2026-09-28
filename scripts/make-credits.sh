#!/usr/bin/env bash
#
# make-credits.sh — emit the "What's New" Credits.html shown in the standard
# macOS About panel, generated from the same notes.md used for the appcast and
# the GitHub release (the reviewed, committed versioned notes file). Keeping
# one source means the About panel never drifts from the release notes.
#
# The standard About panel (NSApplication.orderFrontStandardAboutPanel, which
# SwiftUI's default "About Toki" item calls) auto-loads
# Contents/Resources/Credits.html and renders it below the version. So bundling
# this file is all that's needed to show release notes in About — no app code.
#
# Usage:
#   make-credits.sh <version> <notes-file> > App/Resources/Credits.html
#
#   <version>     bare SemVer, e.g. 0.3.0 (a leading "v" is prepended in the
#                 heading, so pass it WITHOUT the "v").
#   <notes-file>  markdown release notes (see notes-to-html.sh for what is supported).
set -euo pipefail

VERSION="$1"
NOTES_FILE="$2"

# The same converter as the appcast, so the About panel and the update window can never
# render the same notes differently.
# Section headings sit under the panel's own "What's New" title, so they drop a level.
BODY="$("$(dirname "$0")/notes-to-html.sh" "${NOTES_FILE}" \
    | sed -e 's#<h[1-3]>#<h4>#g' -e 's#</h[1-3]>#</h4>#g')"

cat <<HTML
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body>
<h3>What's New in v${VERSION}</h3>
${BODY}
</body>
</html>
HTML
