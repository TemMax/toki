#!/usr/bin/env bash
#
# verify-no-debug-channel.sh — release-safety gate.
#
# Fails if a built .app bundle contains any trace of
# `App/Sources/Debug/DebugControlChannel.swift`. That file is a Unix-socket
# control channel that can drive Toki's UI without any TCC grant, entirely
# behind `#if DEBUG`. Toki stores real Claude OAuth refresh tokens, so a build
# that shipped the channel would be a local backdoor — "`#if DEBUG` stays
# correct by convention" is not a strong enough guarantee for that, hence this
# gate.
#
# THE TRAP THIS SCRIPT EXISTS TO AVOID: Xcode does NOT put Debug code in
# Contents/MacOS/<name>. In a Debug build that file is a small stub and the
# real code — including this channel — lives in
# Contents/MacOS/<name>.debug.dylib. A scan that only looks at
# Contents/MacOS/<name> reports "clean" for a Debug build too — it passes
# *vacuously*, having searched the wrong file. So this script:
#
#   1. Walks the WHOLE bundle and scans every Mach-O it finds (executables,
#      .dylib's, framework binaries, XPC services) — not a hardcoded list of
#      paths.
#   2. Asserts a POSITIVE CONTROL: a string known to be present in every
#      build ("Toki Dashboard", the dashboard window's title) must be found
#      somewhere in the scanned set before "found nothing" is trusted. If the
#      control is missing, the scan itself is broken — that must FAIL, not
#      pass.
#
# Usage:
#   scripts/verify-no-debug-channel.sh <path-to-.app>
#
# Exit 0 and a summary of what was scanned when clean. Non-zero, naming the
# offending file and marker, when the channel (or the positive control) is
# not found where expected.
set -euo pipefail

APP="${1:-}"
if [[ -z "${APP}" ]]; then
  echo "usage: $0 <path-to-.app>" >&2
  exit 1
fi
APP="${APP%/}"
if [[ ! -d "${APP}" ]]; then
  echo "error: no such app bundle: ${APP}" >&2
  exit 1
fi

# Markers that must never appear in a Release binary.
#
# Deliberately NOT the bare type name. A string scan cannot tell compiled code from
# prose, and the type name legitimately appears in prose: `GalleryView` renders an
# on-screen note about headless capture that mentions the channel, and that string
# literal ships. Scanning for it failed a Release build whose `nm` output contained
# zero channel symbols — the code was absent and the gate said otherwise.
#
# A gate that cries wolf gets switched off, so the string markers are now only things
# the channel's own code can emit: the socket filename and its startup log line. The
# type name is checked below through `nm`, where mangling makes a symbol unambiguous
# and a comment or UI string cannot masquerade as one.
STRING_MARKERS=(
  "toki-debug.sock"
  "control channel listening"
)

# A string that IS expected in every build (Debug or Release) — the
# dashboard window's title, set unconditionally in AppDelegate/DebugControlChannel.
POSITIVE_CONTROL="Toki Dashboard"

# --- Walk the bundle, keep only actual Mach-O binaries ----------------------
#
# Not a hardcoded list of paths: any regular file under the bundle whose
# `file` output says Mach-O is scanned — this is what reaches into
# Contents/MacOS/Toki.debug.dylib, nested frameworks, and XPC services alike.
machos=()
while IFS= read -r -d '' candidate; do
  if file -b "${candidate}" | grep -q "Mach-O"; then
    machos+=("${candidate}")
  fi
done < <(find "${APP}" -type f -print0)

if [[ "${#machos[@]}" -eq 0 ]]; then
  echo "error: no Mach-O binaries found under ${APP} — nothing was scanned" >&2
  exit 1
fi

echo "Scanning ${#machos[@]} Mach-O binaries under ${APP}:"
for f in "${machos[@]}"; do
  echo "  - ${f#"${APP}"/}"
done

# --- Positive control ---------------------------------------------------
#
# Before trusting "found nothing", prove the scan can actually read strings
# out of these binaries at all. Without this, "found nothing" would be
# indistinguishable from "searched nothing" (exactly the Contents/MacOS/Toki
# trap above).
#
# Strings/nm output is captured into a variable first, not piped straight
# into `grep -q`: `grep -q` exits the instant it finds a match, which sends
# SIGPIPE to whatever is still writing upstream, and under `pipefail` that
# SIGPIPE (not grep's own exit status) becomes the pipeline's result — a
# genuine match can come back looking like a failure. Capturing first means
# grep only ever reads from a variable, never from a pipe it can kill.
control_found=0
for f in "${machos[@]}"; do
  f_strings="$(strings -a "${f}" || true)"
  if grep -qF "${POSITIVE_CONTROL}" <<<"${f_strings}"; then
    control_found=1
    break
  fi
done
if [[ "${control_found}" -eq 0 ]]; then
  echo "FAIL: positive control not found — the scan is not reading the binary" >&2
  echo "  \"${POSITIVE_CONTROL}\" was not found in any of the ${#machos[@]} scanned binaries" >&2
  exit 1
fi
echo "Positive control OK: \"${POSITIVE_CONTROL}\" found in the scanned set."

# --- Debug-channel markers -----------------------------------------------
for f in "${machos[@]}"; do
  rel="${f#"${APP}"/}"
  f_strings="$(strings -a "${f}" || true)"
  for marker in "${STRING_MARKERS[@]}"; do
    if grep -qF "${marker}" <<<"${f_strings}"; then
      echo "FAIL: found marker \"${marker}\" in ${rel}" >&2
      exit 1
    fi
  done
  f_symbols="$(nm "${f}" 2>/dev/null || true)"
  if grep -q "DebugControlChannel" <<<"${f_symbols}"; then
    echo "FAIL: nm-visible symbol matching \"DebugControlChannel\" in ${rel}" >&2
    exit 1
  fi
done

echo "OK: no trace of DebugControlChannel in any of the ${#machos[@]} scanned binaries."
