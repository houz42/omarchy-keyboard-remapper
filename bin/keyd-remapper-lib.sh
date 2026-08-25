#!/bin/bash
# Shared constants + the keyd config renderer for the "Keyboard Remapper"
# bar-widget plugin. Sourced by both the read-only status collector and the
# privileged apply script so "rule -> keyd config text" has exactly one
# implementation on the shell side.

set -u

KEYD_REMAPPER_CONF="/etc/keyd/houz42-keyboard-remapper.conf"

# pkexec resets $HOME to the target user's home (root's, i.e. /root), not the
# invoking user's -- using plain $HOME here would make apply-keyd-config
# compute the wrong state dir and reject every real pending-file path it's
# handed. pkexec does reliably set PKEXEC_UID to the invoking user's uid, so
# resolve that user's actual home via getent when present; fall back to
# plain $HOME for the non-privileged status script, which never runs under
# pkexec and has a correct $HOME already.
_keyd_remapper_home() {
  if [[ -n ${PKEXEC_UID:-} ]]; then
    getent passwd "$PKEXEC_UID" | cut -d: -f6
  else
    printf '%s' "$HOME"
  fi
}

KEYD_REMAPPER_STATE_DIR="${XDG_STATE_HOME:-$(_keyd_remapper_home)/.local/state}/omarchy/houz42.keyboard-remapper"

# Renders the keyd config for the alt-tap-f13 rule. When enabled, a tap of
# $source alone emits $tap; holding $source still passes through as the
# $hold_layer modifier (keyd's built-in layer name, e.g. "alt"). When
# disabled, only the header is emitted -- no active mappings.
keyd_remapper_render() {
  local enabled="$1" source="$2" hold_layer="$3" tap="$4"
  if [[ $enabled == "true" ]]; then
    printf '[ids]\n*\n\n[main]\n%s = overload(%s, %s)\n' "$source" "$hold_layer" "$tap"
  else
    printf '[ids]\n*\n\n[main]\n'
  fi
}
