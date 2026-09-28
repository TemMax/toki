#!/usr/bin/env bash
#
# notes-to-html.sh — convert release-notes Markdown into an HTML fragment.
#
#   notes-to-html.sh <notes-file>
#
# One converter for every surface that shows the notes: Sparkle's update window
# (`make-appcast.sh`) and the About panel (`make-credits.sh`). Sparkle renders an
# appcast `<description>` as HTML; Markdown pasted into it shows its `##` literally and
# runs every line together, because HTML collapses newlines. (Sparkle 2.9 can render
# Markdown itself, but the update window is drawn by the Sparkle inside the copy the
# user already has installed, so only HTML reads right for everyone.)
#
# Supported, which is all the notes use: `#` headings, `-`/`*` bullets, paragraphs
# (consecutive lines join), and inline `code`, **bold** and [links](https://…). Text is
# HTML-escaped first, so a `<` in a note can never become markup.
set -euo pipefail

awk '
  function esc(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    return s
  }
  # Replaces every `open…close` span (delimiters of length dlen) with tag, left to right.
  function wrap(s, re, dlen, tag,    out, inner) {
    out = ""
    while (match(s, re)) {
      inner = substr(s, RSTART + dlen, RLENGTH - 2 * dlen)
      out = out substr(s, 1, RSTART - 1) "<" tag ">" inner "</" tag ">"
      s = substr(s, RSTART + RLENGTH)
    }
    return out s
  }
  function links(s,    out, span, text, url, mid) {
    out = ""
    while (match(s, /\[[^]]+\]\([^)]+\)/)) {
      span = substr(s, RSTART, RLENGTH)
      mid = index(span, "](")
      text = substr(span, 2, mid - 2)
      url = substr(span, mid + 2, length(span) - mid - 2)
      out = out substr(s, 1, RSTART - 1) "<a href=\"" url "\">" text "</a>"
      s = substr(s, RSTART + RLENGTH)
    }
    return out s
  }
  function inline(s) {
    s = esc(s)
    s = wrap(s, "`[^`]+`", 1, "code")
    s = wrap(s, "\\*\\*[^*]+\\*\\*", 2, "strong")
    return links(s)
  }
  function close_blocks() {
    if (inlist) { print "</ul>"; inlist = 0 }
    if (para != "") { print "<p>" para "</p>"; para = "" }
  }
  BEGIN { inlist = 0; para = "" }
  {
    line = $0
    sub(/[[:space:]]+$/, "", line)
    if (line ~ /^#+[[:space:]]+/) {
      close_blocks()
      level = 0
      while (substr(line, level + 1, 1) == "#") level++
      if (level > 6) level = 6
      sub(/^#+[[:space:]]+/, "", line)
      print "<h" level ">" inline(line) "</h" level ">"
    } else if (line ~ /^[[:space:]]*[-*][[:space:]]+/) {
      if (para != "") { print "<p>" para "</p>"; para = "" }
      sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
      if (!inlist) { print "<ul>"; inlist = 1 }
      print "  <li>" inline(line) "</li>"
    } else if (line == "") {
      close_blocks()
    } else {
      if (inlist) { print "</ul>"; inlist = 0 }
      para = (para == "" ? "" : para " ") inline(line)
    }
  }
  END { close_blocks() }
' "${1:?usage: notes-to-html.sh <notes-file>}"
