#!/usr/bin/env bash
# tests/fm-composer-lib.test.sh - the shared composer-content classifier
# (bin/fm-composer-lib.sh), the ONE fleet-wide owner every backend adapter
# delegates its empty|pending|unknown verdict to.
#
# The load-bearing contract, task fm-composer-shellglyph-safety:
#   1. A BARE shell prompt glyph (`>`/`$`/`%`/`#`) on an unstructured row is a
#      dead shell, NOT an empty agent composer - it must read `unknown`
#      (unsafe-for-injection), never `empty`. This is the safety fix.
#   2. The SAME shell glyph INSIDE a bordered composer box is the harness's own
#      prompt and still reads `empty` (existing behavior preserved).
#   3. The AGENT prompt glyphs `❯` (claude), `›` (codex), `⟩` (muse), and `→`
#      (cursor) are a genuine empty agent composer either way, bordered or bare.
#   4. Real unsubmitted text reads `pending`; a known idle placeholder reads
#      `empty`.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# classify <bordered> <content> [idle_re] -> echoes the verdict.
classify() { fm_composer_classify_content "$@"; }

# --- Safety fix: bare shell prompt is NOT an empty agent composer -----------

test_bare_shell_glyphs_are_unknown() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 0 "$g")
    [ "$out" = unknown ] \
      || fail "bare shell glyph '$g' must read unknown (dead shell, unsafe), got '$out'"
  done
  pass "fm_composer_classify_content: a bare shell prompt glyph (>/\$/%/#) reads unknown, never empty"
}

test_stripped_unbordered_content_uses_plain_content() {
  local plain out
  for plain in '$' 'user@host $'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = unknown ] \
      || fail "stripped unbordered content '$plain' must retain its unknown safety verdict, got '$out'"
  done
  # muse draws `⟩` at luminance ~150, the tightest margin over the 128 ghost
  # threshold in the fleet, so a raised threshold really can strip it to empty
  # and leave only the plain row. This branch is what keeps that pane readable.
  for plain in '❯' '›' '⟩'; do
    out=$(classify 0 '' '' sensitive "$plain")
    [ "$out" = empty ] \
      || fail "a stripped agent glyph '$plain' must remain empty, got '$out'"
  done
  pass "fm_composer_classify_content: stripped unbordered content is unknown except verified agent glyphs"
}

test_bare_shell_prompt_with_command_is_not_empty() {
  local out
  # A dead shell showing a typed command must not read empty either.
  out=$(classify 0 '$ ls -la')
  [ "$out" != empty ] || fail "a bare shell prompt with a command must not read empty, got '$out'"
  pass "fm_composer_classify_content: a bare shell prompt carrying a command is not empty"
}

# --- Preserved: shell glyph inside a composer box is the harness prompt ------

test_bordered_shell_glyph_is_empty() {
  local g out
  for g in '>' '$' '%' '#'; do
    out=$(classify 1 "$g")
    [ "$out" = empty ] \
      || fail "a shell glyph '$g' inside a bordered composer box must read empty, got '$out'"
  done
  pass "fm_composer_classify_content: a bare prompt glyph inside a bordered composer box reads empty (claude's own idle composer)"
}

# --- Agent glyphs are empty either way --------------------------------------

test_agent_glyphs_are_empty_bordered_and_bare() {
  local out
  out=$(classify 0 '❯'); [ "$out" = empty ] || fail "bare claude '❯' should read empty, got '$out'"
  out=$(classify 0 '›'); [ "$out" = empty ] || fail "bare codex '›' should read empty, got '$out'"
  out=$(classify 1 '❯'); [ "$out" = empty ] || fail "bordered claude '❯' should read empty, got '$out'"
  out=$(classify 1 '›'); [ "$out" = empty ] || fail "bordered codex '›' should read empty, got '$out'"
  out=$(classify 0 '⟩'); [ "$out" = empty ] || fail "bare muse '⟩' should read empty, got '$out'"
  out=$(classify 1 '⟩'); [ "$out" = empty ] || fail "bordered muse '⟩' should read empty, got '$out'"
  pass "fm_composer_classify_content: agent prompt glyphs (❯ claude, › codex, ⟩ muse) read empty bordered or bare"
}

# --- Empty content and idle placeholder -------------------------------------

test_empty_content_is_empty() {
  local out
  out=$(classify 0 ''); [ "$out" = empty ] || fail "empty bare content should read empty, got '$out'"
  out=$(classify 1 ''); [ "$out" = empty ] || fail "empty bordered content should read empty, got '$out'"
  pass "fm_composer_classify_content: an empty composer reads empty"
}

test_idle_placeholder_is_empty() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'Type a message...' "$idle" sensitive 'Type a message...' 1 1)
  [ "$out" = pending ] || fail "placeholder-like text surviving a styled box capture should read pending, got '$out'"
  out=$(classify 1 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 1 0)
  [ "$out" = empty ] || fail "a glyph-bearing plain box placeholder should read empty, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 1)
  [ "$out" = pending ] || fail "placeholder text on a styled bare input row must be pending, got '$out'"
  out=$(classify 0 '❯ Type a message...' "$idle" sensitive '❯ Type a message...' 0 0)
  [ "$out" = unknown ] || fail "placeholder text on a plain bare input row must be unknown, got '$out'"
  out=$(classify 1 'Type a message...')
  [ "$out" = pending ] || fail "without an idle regex the placeholder text is pending, got '$out'"
  pass "fm_composer_classify_content: idle matching is limited to proven placeholder positions"
}

test_idle_placeholder_case_mode_is_explicit() {
  local idle='^Type a message\.\.\.$' out
  out=$(classify 1 'type a message...' "$idle" sensitive 'type a message...' 1 0)
  [ "$out" = pending ] || fail "a case-variant idle placeholder should remain pending by default, got '$out'"
  out=$(classify 1 'type a message...' "$idle" insensitive 'type a message...' 1 0)
  [ "$out" = empty ] || fail "an explicitly insensitive plain placeholder should read empty, got '$out'"
  pass "fm_composer_classify_content: idle matching preserves the caller's case mode"
}

# --- Real text is pending ---------------------------------------------------

test_real_text_is_pending() {
  local out
  out=$(classify 0 '❯ fix findings 1 and 3'); [ "$out" = pending ] || fail "bare '❯ <text>' should be pending, got '$out'"
  out=$(classify 1 '> deploy staging now'); [ "$out" = pending ] || fail "bordered '> <text>' should be pending, got '$out'"
  # muse restores the interrupted prompt into its composer after Escape, as real
  # bright text. Reading that as pending is correct - it really is unsubmitted.
  out=$(classify 0 '⟩ second turn to interrupt'); [ "$out" = pending ] || fail "bare '⟩ <text>' should be pending, got '$out'"
  # A slash-command popup argument-hint placeholder is still unsubmitted text.
  out=$(classify 1 '/compact compaction instructions'); [ "$out" = pending ] || fail "a popup placeholder fill should be pending, got '$out'"
  pass "fm_composer_classify_content: real unsubmitted text reads pending (including a popup argument-hint fill)"
}

# =============================================================================
# fm_composer_classify_screen: the adapter-facing screen classifier and the
# correctness matrix (audit data/fm-composer-consolidation-audit-s1, task
# fm-composer-thin-adapter-refactor-r1).
#
# Fixtures are the audit's byte-level captures of six REAL idle harnesses:
# claude 2.1.226 (bare `❯` + U+00A0 NO-BREAK SPACE), codex 0.146.0 (bold `›`
# + SGR-2 dim hint), codex 0.154.0 (the same `›` amid a braille starfield over
# a status footer, captured through Herdr on 2026-09-15), muse (truecolor `⟩`, 38;2;90;160;255), pi (blank row
# between solid `─` rules), opencode 1.14.46 (left-bar `┃` rows), and grok
# 1.0.0 (bordered box with a TITLED bottom border), plus claude captured
# inside zellij through `dump-screen --ansi` (`ESC[m` `❯` U+00A0).
#
# Capability profiles mirror the real adapters' descriptors: tmux
# (styled+cursor+identity), herdr/zellij (styled), cmux/orca (plain). Every
# emptiness verdict is asserted under the ambient UTF-8 locale AND LC_ALL=C,
# pinning the locale-safe Unicode-space normalization (issue #1988).
# =============================================================================

ESC=$(printf '\033')
NBSP=$(printf '\302\240')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_STYLED_NOID=$'styled=1\ncursor=0\nidentity=0\nrows=20' # zellij
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor] [identity]: one
# verdict, asserted under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

test_matrix_claude_bare_nbsp_row() {
  # Real idle claude: `❯` + U+00A0, borderless, between horizontal rules.
  # The audit's headline defect: this row read `pending` under LC_ALL=C
  # (issue #1988), deferring every away-mode escalation in daemon contexts.
  local screen typed
  screen=$'transcript line\n────────────────────────\n❯'"$NBSP"$'\n────────────────────────\n  bypass permissions'
  assert_screen "claude idle on tmux" empty "$CAPS_TMUX" "$screen" 2 probe-absent
  assert_screen "claude idle on herdr" empty "$CAPS_STYLED" "$screen" '' probe-absent
  assert_screen "claude idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  typed=$'────────────────────────\n❯ fix the login bug\n────────────────────────'
  assert_screen "claude typed on tmux" pending "$CAPS_TMUX" "$typed" 1 probe-absent
  # Plain capture cannot tell typed text from claude's rotating suggestion:
  # the styled=0 degradation defers instead of fabricating pending.
  assert_screen "claude typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  pass "matrix: claude's ❯+NBSP row reads empty on every profile in both locales (#1988)"
}

test_matrix_codex_dim_hint_row() {
  # Real idle codex: bold `›`, reset, then an SGR-2 dim hint. Styled captures
  # strip the ghost and prove empty; plain captures must defer as unknown -
  # NEVER the old false `pending` that read the hint as unsent text.
  local styled plain
  styled=$'banner\n'"${ESC}[1m›${ESC}[0m ${ESC}[2mUse /skills to list available skills${ESC}[0m"
  plain=$'banner\n› Use /skills to list available skills'
  assert_screen "codex idle on tmux" empty "$CAPS_TMUX" "$styled" 1
  assert_screen "codex idle on herdr" empty "$CAPS_STYLED" "$styled"
  assert_screen "codex idle on zellij" empty "$CAPS_STYLED_NOID" "$styled"
  assert_screen "codex idle on plain backends" unknown "$CAPS_PLAIN" "$plain"
  pass "matrix: codex's dim hint is empty when styling proves it, unknown (never pending) when it cannot"
}

test_matrix_muse_truecolor_glyph_survives_signal_loss() {
  # Real idle muse: truecolor `⟩` (38;2;90;160;255, luminance ~149.9) under a
  # TITLED rule. Two independent signals prove emptiness: the glyph surviving
  # the ghost strip, and the UNSTRIPPED plain row carrying an agent glyph.
  # Drive them apart: with the luma threshold raised past the glyph's
  # luminance, the ghost strip erases it, and the verdict must survive on the
  # plain-row signal alone.
  local screen plain out
  screen=$'── Voice input (⌥ + v to start) ─────\n'"${ESC}[0m${ESC}[38;2;90;160;255m⟩${ESC}[0m"
  plain=$'── Voice input (⌥ + v to start) ─────\n⟩'
  assert_screen "muse idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "muse idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "muse idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "muse idle on cmux/orca" empty "$CAPS_PLAIN" "$plain"
  out=$(FM_COMPOSER_GHOST_LUMA_MAX=200 fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] || fail "muse must stay empty when the ghost strip eats its glyph (plain-row signal), got '$out'"
  pass "matrix: muse's ⟩ reads empty everywhere and survives losing the styled-glyph signal"
}

test_matrix_cursor_reverse_video_placeholder_remnant() {
  # Real idle cursor-agent (2026.08.11-e8db854), captured byte-for-byte from a
  # live pane: the `→ ` glyph and the placeholder tail are dim (SGR 2), but the
  # cell under the terminal cursor is REVERSE VIDEO (SGR 0;7). Reverse video is
  # neither dim nor a dark foreground, so the ghost stripper keeps that one
  # character and an idle composer reduces to a lone `P`.
  local row screen plain out stripped
  row="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0;7m${ESC}[48;2;21;21;21mP"
  row="${row}${ESC}[0;2m${ESC}[48;2;21;21;21mlan, search, build anything${ESC}[0m"
  screen=$'transcript\n\n'"$row"
  plain=$'transcript\n\n  → Plan, search, build anything'

  # NON-VACUOUSNESS: prove the remnant really survives stripping. If the ghost
  # stripper ever learned SGR 7, `stripped` would be empty and the verdict below
  # would come from the empty-content path instead, silently retiring the
  # plain-row branch this case exists to cover.
  stripped=$(printf '%s' "$row" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = P ] \
    || fail "cursor's reverse-video remnant must survive ghost stripping as 'P', got '$stripped'"

  assert_screen "cursor idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "cursor idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  # An UNSTYLED capture carries no ghost-strip proof, so a bare row matching a
  # placeholder is indistinguishable from typed text and must stay unknown -
  # the same degradation every other bare-row placeholder already takes.
  assert_screen "cursor idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"

  # The dangerous direction: text a user actually TYPED is uniformly bright, so
  # stripping leaves it EQUAL to the plain row. Even when that text is exactly
  # the placeholder, it must stay pending - never a false empty.
  local typed typed_plain
  typed="${ESC}[48;2;21;21;21m ${ESC}[2m→ ${ESC}[0m${ESC}[38;2;224;222;244mAdd a follow-up${ESC}[0m"
  typed_plain=$'transcript\n\n  → Add a follow-up'
  assert_screen "cursor typed placeholder text stays pending" pending \
    "$CAPS_STYLED" $'transcript\n\n'"$typed"
  # Without styling there is no proof either way, so it must not read empty.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$typed_plain")
  [ "$out" != empty ] \
    || fail "an unstyled cursor row matching the placeholder must not read empty, got '$out'"
  pass "matrix: cursor's reverse-video placeholder remnant reads empty; real typed text stays pending"
}

test_matrix_herdr_halfblock_rule_bounds_bare_wrap() {
  # Herdr draws a composer's rules with half-block glyphs (▄ above, ▀ below)
  # rather than the box-drawing family. Without treating those as edges, a bare
  # composer's WRAP region walks through its own closing rule and swallows the
  # footer, whose real content turns an idle pane into a false `pending`.
  # Captured live from a herdr cursor pane.
  local screen plain out
  plain=$'transcript\n ▄▄▄▄▄▄▄▄\n  → Add a follow-up\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  # The closing rule must bound the region, so the footer below is not input.
  fm_composer_row_has_edge ' ▀▀▀' \
    || fail "a half-block rule row must count as a structural edge"
  fm_composer_row_has_edge ' ▄▄▄' \
    || fail "the upper half-block rule must count as a structural edge"
  # Non-vacuousness: the footer rows really are non-blank content that would be
  # swallowed if the rule did not bound the region.
  case "$plain" in *"Run Everything"*) : ;; *) fail "fixture lost its footer content" ;; esac
  ESC_LOCAL=$(printf '\033')
  screen=$'transcript\n ▄▄▄▄▄▄▄▄\n'"  ${ESC_LOCAL}[2m→ ${ESC_LOCAL}[0;7mA${ESC_LOCAL}[0;2mdd a follow-up${ESC_LOCAL}[0m"$'\n ▀▀▀▀▀▀▀▀\n  Cursor Grok 4.5 High · 6.7%   Run Everything\n  ~/wt · 64cdd3a'
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")
  [ "$out" = empty ] \
    || fail "an idle cursor composer inside herdr half-block rules must read empty, got '$out'"
  pass "matrix: herdr half-block rules bound a bare composer's wrap region"
}

test_matrix_omp_status_row_bounds_bare_composer() {
  # omp (Oh My Pi) draws its status line directly BELOW the borderless `❯`
  # composer. Captured live through Herdr on omp 18.1.11 under the captain's
  # unicode preset (idle), plus the nerd-preset idle row and the busy spinner
  # row from the 18.1.2 investigation. Without the status-row rule the bare
  # wrap region swallows that row and an idle omp pane reads `pending`, which
  # skipped the doorbell on the first live omp worker.
  local idle_unicode idle_nerd busy typed wrapped
  idle_unicode=$'transcript line

❯
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  idle_nerd=$'transcript line

❯
 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K'
  busy=$'transcript line

  ⎋ Working…

❯
 ⠧ 11s  · ◔ GPT-6-Astra · ◫ 15.4%/272K'
  typed=$'transcript line

❯ fix the flaky test
 π  · ◔ GPT-6-Astra · 🌳 …-workspace · ⑂ detached · ◫ 15.4%/272K ⟲ · (sub)'
  # Non-vacuousness: each status row is real non-blank content that the wrap
  # region would otherwise take as typed input.
  _fm_composer_row_is_omp_status ' π  · ◔ GPT-6-Astra · 🌳 …-workspace' \
    || fail "the unicode-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' 󰵗  ·  qwen3:8b ·  kun-agent-workspace/… ·  detached ?1 ·  36.7%/41K' \
    || fail "the nerd-preset omp status row must be recognized as furniture"
  _fm_composer_row_is_omp_status ' ⠧ 11s  · ◔ GPT-6-Astra' \
    || fail "the busy omp spinner row must be recognized as furniture"
  _fm_composer_row_is_omp_status 'fix the flaky test' \
    && fail "ordinary typed text must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status 'please rerun the suite and report' \
    && fail "ordinary prose must not be mistaken for omp status furniture"
  # Only omp's identity cell opens the row: a wrapped typed row that happens
  # to begin with a short word and a spaced middle dot is composer input.
  _fm_composer_row_is_omp_status 'fix · tests before pushing' \
    && fail "wrapped typed text with a middle dot must not be mistaken for omp status furniture"
  # The ascii preset's identity cell is `pi`, but that preset separates its
  # cells with ` - `, so a row opening `pi ·` is never omp furniture.
  _fm_composer_row_is_omp_status 'pi · e · phi as the three constants' \
    && fail "typed text opening 'pi ·' must not be mistaken for omp status furniture"
  _fm_composer_row_is_omp_status ' ⣾ 3s  · ◔ GPT-6-Astra' \
    || fail "the status-set omp spinner row must be recognized as furniture"
  assert_screen "idle omp (unicode preset)" empty "$CAPS_STYLED" "$idle_unicode"
  assert_screen "idle omp (nerd preset)" empty "$CAPS_STYLED" "$idle_nerd"
  assert_screen "busy omp keeps an empty composer" empty "$CAPS_STYLED" "$busy"
  assert_screen "typed omp text is pending" pending "$CAPS_STYLED" "$typed"
  assert_screen "idle omp on a plain capture" empty "$CAPS_PLAIN" "$idle_unicode"
  # The boundary must not cut a bare composer's own wrapped input: with the
  # cursor on a continuation row that opens `fix · tests`, the composer is a
  # proven wrap region and reads pending, exactly as it did before the rule.
  wrapped=$'transcript line\n\n❯ please run the suite and then\nfix · tests before pushing'
  assert_screen "wrapped typed text with a middle dot stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  wrapped=$'transcript line\n\n❯ document the constants in the order\npi · e · phi with one example each'
  assert_screen "wrapped typed text opening 'pi ·' stays pending" pending "$CAPS_TMUX" "$wrapped" 3
  pass "matrix: omp's status row bounds the bare composer's wrap region"
}

# codex_cell <grey> <glyph>: one codex 0.154 starfield cell exactly as the
# harness draws it - a truecolor grey foreground, the composer's grey
# background, the braille glyph, then a reset.
codex_cell() {
  printf '%s[38;2;%s;%s;%sm%s[48;2;57;57;57m%s%s[0m' "$ESC" "$1" "$1" "$1" "$ESC" "$2" "$ESC"
}

test_matrix_codex_idle_starfield_furniture() {
  # Real idle codex-cli 0.154.0 (gpt-6-astra, fast mode) captured byte-for-byte
  # through Herdr (`pane read --format ansi`) from the first codex second mate:
  # an animated braille "starfield" on the row above the bold `›`, on the `›`
  # row behind the SGR-2 dim `Ask Codex to do anything` placeholder, and on
  # the row below, then a bright model/path/title status footer. The cells are
  # truecolor greys on BOTH sides of the 128 ghost-luma ceiling, so the
  # brighter ones survive the ghost strip, and the rows below the glyph carry
  # no structural edge. The bare shape therefore extended its wrap region over
  # the two rows beneath the glyph and read the survivors as wrapped typed
  # input: `pending`, which deferred every steering doorbell for that pane.
  local bg="${ESC}[48;2;57;57;57m" above glyph glyph2 below footer
  local screen screen2 plain plain2 ascii_screen stripped out
  above="${ESC}[0m${bg}                         ${ESC}[0m$(codex_cell 82 ⢀)${bg}      ${ESC}[0m$(codex_cell 136 ⠂)${bg} ${ESC}[0m$(codex_cell 163 ⠄)${bg}     ${ESC}[0m$(codex_cell 118 ⠈)"
  glyph="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m${bg} ${ESC}[0m${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 117 ⡀)${bg}  ${ESC}[0m$(codex_cell 88 ⠈)${bg}       ${ESC}[0m$(codex_cell 156 ⠂)${bg}        ${ESC}[0m$(codex_cell 71 ⠁)$(codex_cell 161 ⠐)${bg} ${ESC}[0m$(codex_cell 165 ⠁)"
  # A second live sample of the same pane, minutes later: the animation had
  # placed a bright cell BETWEEN the glyph and the placeholder.
  glyph2="${ESC}[0m${ESC}[1m${bg}›${ESC}[0m$(codex_cell 138 ⠁)${ESC}[2m${bg}Ask Codex to do anything${ESC}[0m$(codex_cell 163 ⡀)${bg}  ${ESC}[0m$(codex_cell 132 ⠈)"
  below="${ESC}[0m${bg}        ${ESC}[0m$(codex_cell 101 ⠐)${bg}    ${ESC}[0m$(codex_cell 111 ⠄)${bg}   ${ESC}[0m$(codex_cell 165 ⠠)${bg}  ${ESC}[0m$(codex_cell 121 ⢀)$(codex_cell 122 ⠠)$(codex_cell 81 ⡀)$(codex_cell 150 ⠄⠂)"
  footer="  ${ESC}[0m${ESC}[38;2;246;226;183mgpt-6-astra high fast${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;171;223;167m~/Projects/purser${ESC}[0m${ESC}[2m · ${ESC}[0m${ESC}[38;2;156;222;211mLaunch Purser desk brief${ESC}[0m"
  screen=$'transcript line\n\n'"$above"$'\n'"$glyph"$'\n'"$below"$'\n'"$footer"
  screen2=$'transcript line\n\n'"$above"$'\n'"$glyph2"$'\n'"$below"$'\n'"$footer"
  plain=$(printf '%s\n' "$screen" | fm_composer_strip_ansi)
  plain2=$(printf '%s\n' "$screen2" | fm_composer_strip_ansi)

  # NON-VACUOUSNESS: the ghost strip really leaves braille survivors behind the
  # placeholder and on the row below (cells above the luma ceiling), and the
  # footer really is non-blank, edge-free content the wrap region would take.
  stripped=$(printf '%s\n' "$glyph" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" != '›' ] \
    || fail "the glyph row's starfield cells must survive ghost stripping, or the furniture case is vacuous"
  stripped=$(printf '%s\n' "$stripped" | fm_composer_strip_braille)
  fm_composer_normalize_trim_var stripped
  [ "$stripped" = '›' ] \
    || fail "everything surviving ghost stripping behind the glyph must be braille, got '$stripped'"
  stripped=$(printf '%s\n' "$below" | fm_composer_strip_ghost)
  fm_composer_normalize_trim_var stripped
  [ -n "$stripped" ] \
    || fail "the row below the glyph must keep starfield cells after ghost stripping"
  _fm_composer_row_is_braille_furniture "$stripped" \
    || fail "the row below the glyph must be recognized as braille furniture"
  fm_composer_row_has_edge '  gpt-6-astra high fast · ~/Projects/purser · Launch Purser desk brief' \
    && fail "fixture drift: the footer must carry no structural edge, or the boundary rule is untested"

  # The verdicts: empty wherever styling can prove the placeholder ghost, on
  # both live samples, in both locales; unknown (never pending) on a plain
  # capture, exactly as the codex dim-hint row above.
  assert_screen "codex 0.154 idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "codex 0.154 idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "codex 0.154 idle on tmux (cursor on the glyph row)" empty "$CAPS_TMUX" "$screen" 3
  assert_screen "codex 0.154 idle on cmux/orca" unknown "$CAPS_PLAIN" "$plain"
  assert_screen "codex 0.154 idle (second sample) on herdr" empty "$CAPS_STYLED" "$screen2"
  assert_screen "codex 0.154 idle (second sample) on tmux" empty "$CAPS_TMUX" "$screen2" 3
  assert_screen "codex 0.154 idle (second sample) on cmux/orca" unknown "$CAPS_PLAIN" "$plain2"
  # A cursor parked on the starfield row below the glyph is not inside a wrap
  # region, so the strict blank-row posture keeps it unknown.
  assert_screen "codex 0.154 cursor on the starfield row" unknown "$CAPS_TMUX" "$screen" 4

  # DIVERGENCE: the same screen with every starfield cell replaced by a letter
  # is wrapped typed input and must stay pending, so the furniture verdict
  # above cannot come from anything but the braille rule.
  ascii_screen=$(printf '%s\n' "$screen" | LC_ALL=C sed 's/⢀/x/g; s/⠂/x/g; s/⠄/x/g; s/⠈/x/g; s/⡀/x/g; s/⠁/x/g; s/⠐/x/g; s/⠠/x/g')
  case "$ascii_screen" in *'⠂'*|*'⠁'*) fail "fixture drift: the divergence screen still carries braille" ;; esac
  assert_screen "starfield replaced by letters on herdr" pending "$CAPS_STYLED" "$ascii_screen"
  assert_screen "starfield replaced by letters on tmux" pending "$CAPS_TMUX" "$ascii_screen" 3

  # NEGATIVES that keep the rule from over-stripping:
  # (i) a real message wrapped below the `›` row, footer beneath, stays pending.
  out=$'transcript line\n\n› please run the suite and then\ncontinue with the docs\n'"$footer"
  assert_screen "wrapped typed input above the codex footer on herdr" pending "$CAPS_STYLED" "$out"
  assert_screen "wrapped typed input above the codex footer on tmux" pending "$CAPS_TMUX" "$out" 3
  # (ii) braille mixed with typed text is typed text, on the glyph row and on
  # a wrapped row alike.
  assert_screen "braille mixed into the glyph row" pending "$CAPS_STYLED" $'transcript line\n\n› fix ⠂ the tests'
  assert_screen "braille mixed into a wrapped row" pending "$CAPS_STYLED" $'transcript line\n\n› please\nfix ⠂ the tests'
  # (iii) a typed row carrying a spaced middle dot is composer input.
  assert_screen "wrapped typed row with a middle dot on herdr" pending "$CAPS_STYLED" $'transcript line\n\n› deploy\nfix · tests before pushing'
  assert_screen "wrapped typed row with a middle dot on tmux" pending "$CAPS_TMUX" $'transcript line\n\n› deploy\nfix · tests before pushing' 3
  # (iv) the footer or a starfield row alone, with no bare glyph above, gains
  # no new verdict: still no container proof.
  assert_screen "codex footer alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$footer"
  assert_screen "codex footer alone on tmux" unknown "$CAPS_TMUX" $'transcript line\n\n'"$footer" 2
  assert_screen "starfield row alone on herdr" unknown "$CAPS_STYLED" $'transcript line\n\n'"$below"
  pass "matrix: codex 0.154's starfield rows are furniture; typed, mixed, and unanchored rows keep their verdicts"
}

test_matrix_pi_separated_needs_identity() {
  # Real idle pi: a blank row between two solid rules. The blank row alone is
  # exactly what the strict rule refuses; only structure PLUS a live
  # idle/done pi identity proves the composer (herdr's rule, now
  # fleet-wide; tmux supplies identity from its foreground-process probe).
  local screen typed pi_idle pi_working pi_blocked none
  screen=$'transcript\n────────────────────────\n\n────────────────────────\n footer'
  pi_idle=$(printf 'pi\tidle'); pi_working=$(printf 'pi\tworking'); none=$(printf 'zsh\t')
  pi_blocked=$(printf 'pi\tblocked')
  assert_screen "pi idle with identity" empty "$CAPS_STYLED" "$screen" '' "$pi_idle"
  assert_screen "pi idle on tmux with identity" empty "$CAPS_TMUX" "$screen" 2 "$pi_idle"
  assert_screen "pi idle on zellij" unknown "$CAPS_STYLED_NOID" "$screen"
  # Identity-capable but unfetched: the adapter is asked to probe lazily.
  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")" = need-identity ] \
    || fail "an identity-capable profile should request the lazy identity probe"
  # No identity capability (cmux/orca/zellij): the shape is unprovable.
  assert_screen "pi pair without identity capability" unknown "$CAPS_PLAIN" "$screen"
  # A working pi cannot authorize injection into the blank region.
  assert_screen "working pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_working"
  # A pi parked on an interactive prompt reports `blocked`: it is waiting on a
  # human keystroke, so the blank region is a menu's, not a free composer's.
  # Typing there answers the prompt and the text is discarded (issue #2797).
  assert_screen "blocked pi defers" unknown "$CAPS_STYLED" "$screen" '' "$pi_blocked"
  # The audit's live counterexample: a plain shell running sleep, cursor
  # parked on a blank line between two rules, NO pi process. The permissive
  # rule read this `empty`; identity+structure refuses it.
  assert_screen "sleep-pane counterexample" unknown "$CAPS_TMUX" "$screen" 2 "$none"
  assert_screen "absent identity cannot prove blank pi pair" unknown "$CAPS_TMUX" "$screen" 2 probe-absent
  typed=$'────────────────────────\nfix the flaky test\n────────────────────────'
  assert_screen "pi typed" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  typed=$'────────────────────────\n❯\n────────────────────────'
  assert_screen "pi lone-glyph draft with identity" pending "$CAPS_STYLED" "$typed" '' "$pi_idle"
  assert_screen "pi lone-glyph draft on tmux" pending "$CAPS_TMUX" "$typed" 1 "$pi_idle"
  assert_screen "lone glyph without identity capability" empty "$CAPS_STYLED_NOID" "$typed"
  assert_screen "lone glyph on plain backend" empty "$CAPS_PLAIN" "$typed"
  assert_screen "lone glyph with non-pi identity" empty "$CAPS_STYLED" "$typed" '' "$none"
  pass "matrix: pi's separated composer needs identity + structure; the blank row alone never proves it"
}

test_matrix_opencode_leftbar_signals() {
  # Real idle opencode: `┃`-prefixed rows holding an "Ask anything" hint,
  # blanks, and a Build-mode footer. Two independent idle signals: the shared
  # idle-placeholder pattern (works on plain captures) and the ghost strip
  # (works on styled captures even if the pattern is overridden away).
  local screen typed dim_screen captured_idle captured_pending out
  screen=$'  ┃\n  ┃  Ask anything... "What is the tech stack?"\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀'
  dim_screen=$'  ┃\n  ┃  '"${ESC}[2mAsk anything...${ESC}[0m"$'\n  ┃\n  ┃  Build · GPT-5.5 Fast OpenAI · high\n  ╹▀▀▀▀'
  assert_screen "opencode idle on tmux (cursor on hint)" empty "$CAPS_TMUX" "$dim_screen" 1
  assert_screen "opencode idle on herdr" empty "$CAPS_STYLED" "$dim_screen"
  assert_screen "opencode idle on zellij" empty "$CAPS_STYLED_NOID" "$dim_screen"
  assert_screen "opencode idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  # This sanitized live OpenCode 1.18.30 capture preserves its U+2026 hint and
  # RGB 128 styling. RGB 128 is deliberately outside the ghost threshold, so
  # the placeholder spelling is the independent empty signal. The completed-
  # turn row above the active composer also pins the incident's idle layout.
  captured_idle=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;128;128;128mAsk anything… \"Fix a TODO in the codebase\"${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn idle hint on tmux" empty "$CAPS_TMUX" "$captured_idle" 3
  captured_pending=$'  ▣ Build · Big Pickle · 3.4s\n\n  ┃\n  ┃  '"${ESC}[38;2;255;255;255mReply with OK.${ESC}[38;2;255;255;255m"$'\n  ┃\n  ┃  Build · Big Pickle OpenCode Zen\n  ╹▀▀▀▀▀▀▀▀'
  assert_screen "opencode 1.18.30 completed-turn typed composer on tmux" pending "$CAPS_TMUX" "$captured_pending" 3
  # Signal separation: with the idle pattern overridden to something that
  # cannot match, a DIM-styled hint still proves empty through the ghost strip.
  out=$(FM_COMPOSER_IDLE_RE='^NEVER-MATCHES$' fm_composer_classify_screen "$CAPS_TMUX" "$dim_screen" 1)
  [ "$out" = empty ] || fail "a dim opencode hint must stay empty via the ghost strip alone, got '$out'"
  typed=$'┃\n┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "opencode typed on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  Ask anything... please investigate\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀'
  assert_screen "opencode placeholder-like input on tmux" pending "$CAPS_TMUX" "$typed" 0
  assert_screen "opencode placeholder-like input on plain backends" unknown "$CAPS_PLAIN" "$typed"
  typed=$'┃  refactor the parser please\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high'
  assert_screen "opencode multiline draft above blank cursor row" pending "$CAPS_TMUX" "$typed" 1
  pass "matrix: opencode's left-bar composer reads empty everywhere and scans the full active run"
}

test_matrix_grok_titled_bottom_border() {
  # Grok 1.0.5 widened its titled BOTTOM border three columns past the top and
  # content rows. This is the idle capture from issue #3436; Herdr has no
  # cursor anchor, so the geometry mismatch used to make the proven box
  # ambiguous and the verdict unknown, stranding away-mode injection.
  local titled plain_border typed malformed placeholder_draft
  titled=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯\n\n  Shift+Tab:mode  │  Ctrl+x:shortcuts'
  plain_border=$'  ╭──────────────────────────────────────╮\n  │ ❯                                    │\n  ╰──────────────────────────────────────╯'
  assert_screen "grok titled on tmux" empty "$CAPS_TMUX" "$titled" 1
  assert_screen "grok titled on tmux bottom-border cursor" empty "$CAPS_TMUX" "$titled" 2
  assert_screen "issue #3436 idle grok 1.0.5 on herdr" empty "$CAPS_STYLED" "$titled"
  placeholder_draft=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ Type a message...                                                      │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok bright placeholder-like draft on tmux" pending "$CAPS_TMUX" "$placeholder_draft" 1
  assert_screen "grok placeholder on plain backends" empty "$CAPS_PLAIN" "$placeholder_draft"
  assert_screen "grok titled on cmux/orca" empty "$CAPS_PLAIN" "$titled"
  assert_screen "grok titled on zellij" empty "$CAPS_STYLED_NOID" "$titled"
  # The tolerance is additive: an untitled border still proves the same box.
  assert_screen "grok untitled border" empty "$CAPS_TMUX" "$plain_border" 1
  typed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯ deploy the fix                                                         │\n  ╰────────────────────────────────────────────────────────── Grok 4.6 (xhigh) ─╯'
  assert_screen "grok typed on tmux" pending "$CAPS_TMUX" "$typed" 1
  assert_screen "grok typed on herdr" pending "$CAPS_STYLED" "$typed"
  malformed=$'  ╭──────────────────────────────────────────────────────────────────────────╮\n  │ ❯                                                                        │\n  ╰────────────────────────────────────────────────────────── unknown surface ─╯'
  assert_screen "oversized unknown title on herdr" unknown "$CAPS_STYLED" "$malformed"
  pass "matrix: grok's real oversized titled bottom is empty while typed and unproved panes stay safe"
}

test_matrix_kimi_bordered_shell_glyph_box() {
  # Kimi's bordered `│ > │` composer - the shape fm-spawn.sh's retired
  # spawn-local regex used to own. Now the shared owner proves it everywhere,
  # which is what kimi launch-readiness and delivery route through.
  local screen
  screen=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯'
  assert_screen "kimi idle on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "kimi idle on cmux/orca" empty "$CAPS_PLAIN" "$screen"
  assert_screen "kimi idle on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "kimi idle on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  pass "matrix: kimi's bordered shell-glyph box reads empty through the shared owner (spawn's fourth copy retired)"
}

test_matrix_claude_inside_zellij_ansi_dump() {
  # Real claude captured through `zellij action dump-screen --ansi`
  # (capability established by the audit): `ESC[m` `❯` U+00A0.
  local screen plain
  screen=$'zellij pane transcript\n'"${ESC}[m❯${NBSP}"
  plain=$'zellij pane transcript\n❯'"$NBSP"
  assert_screen "claude-in-zellij on tmux" empty "$CAPS_TMUX" "$screen" 1
  assert_screen "claude-in-zellij on herdr" empty "$CAPS_STYLED" "$screen"
  assert_screen "claude-in-zellij on zellij" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "claude-in-zellij on plain backends" empty "$CAPS_PLAIN" "$plain"
  pass "matrix: the real claude-in-zellij --ansi dump reads empty in both locales"
}

test_strict_blank_row_divergence() {
  # THE STRICT POSTURE PIN (captain decision blank-row-injection-posture,
  # 2026-08-09): a blank or otherwise unidentified input row with no positive
  # container proof is `unknown`. Each case below read `empty` (or `pending`)
  # under the replaced permissive rule; if any of them drifts back, the
  # permissive posture has silently returned and away-mode injection would
  # again type escalations into unproven panes.
  local out
  # Permissive read this blank cursor row as empty = safe to inject.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'some output\nmore output\n' 2)
  [ "$out" = unknown ] || fail "a blank unidentified cursor row must be unknown (was permissive empty), got '$out'"
  # A dead shell's prompt row.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\n$ ' 1)
  [ "$out" = unknown ] || fail "a dead-shell prompt row must be unknown, got '$out'"
  # A bare busy-footer row is not a composer container.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'Working...' 0)
  [ "$out" = unknown ] || fail "a bare busy-footer row must be unknown (was permissive empty), got '$out'"
  # An unidentified free-text cursor row carries no container proof either.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'output\nhuman draft text' 1)
  [ "$out" = unknown ] || fail "an unidentified text row must be unknown under strict, got '$out'"
  # A blank screen with no cursor capability.
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'\n\n')
  [ "$out" = unknown ] || fail "a blank screen must be unknown, got '$out'"
  pass "strict posture: blank and unidentified rows are unknown, never injectable empty"
}

test_bare_wrap_region_classifies() {
  # Long typed input wraps below the glyph row; the cursor rides the wrapped
  # continuation. The region is IDENTIFIED (glyph row + contiguous non-blank,
  # non-structural rows), so a swallowed Enter still reads pending and earns
  # its retry; a wrapped GHOST suggestion still proves empty.
  local wrapped ghost_wrapped out
  wrapped=$'❯ a very long steer message that\nwraps onto the following line'
  assert_screen "wrapped typed input" pending "$CAPS_TMUX" "$wrapped" 1
  wrapped=$'❯ wrapped typed input\ncontinues without a terminal-inserted glyph'
  assert_screen "ordinary wrapped input" pending "$CAPS_TMUX" "$wrapped" 1
  ghost_wrapped=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$ghost_wrapped" 1)
  [ "$out" = empty ] || fail "a wrapped ghost suggestion should still prove empty, got '$out'"
  # A structural row between the glyph and the cursor breaks the wrap claim.
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n────────────────\nbelow the rule' 2)
  [ "$out" = unknown ] || fail "a rule between glyph and cursor must break the wrap region, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" $'❯ text\n$ live shell' 1)
  [ "$out" = unknown ] || fail "a shell prompt below a glyph row must not become wrapped input, got '$out'"
  pass "fm_composer_classify_screen: the bare composer's wrap region stays identified; structure breaks it"
}

test_contiguous_transcript_reanchors_on_live_prompt() {
  local screen
  screen=$'❯ hi\nHello!\n❯'
  assert_screen "contiguous transcript live prompt on cursorless styled backend" empty "$CAPS_STYLED_NOID" "$screen"
  assert_screen "contiguous transcript live prompt on cursorless plain backend" empty "$CAPS_PLAIN" "$screen"
  assert_screen "contiguous transcript live prompt with cursor" empty "$CAPS_TMUX" "$screen" 2
  pass "fm_composer_classify_screen: a row-leading agent glyph reanchors the live composer"
}

test_lower_dead_shell_invalidates_cursorless_candidate() {
  local stale live out
  stale=$'old transcript\n❯\nprocess exited\n$'
  assert_screen "stale composer above dead shell on herdr" unknown "$CAPS_STYLED" "$stale"
  assert_screen "stale composer above dead shell on zellij" unknown "$CAPS_STYLED_NOID" "$stale"
  assert_screen "stale composer above dead shell on cmux/orca" unknown "$CAPS_PLAIN" "$stale"
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$stale" 1)
  [ "$out" = empty ] \
    || fail "cursor mode must keep the cursor-anchored composer verdict, got '$out'"

  live=$'transcript shell snippet\n$ echo old output\nmore transcript\n❯'
  assert_screen "shell transcript above live composer on herdr" empty "$CAPS_STYLED" "$live"
  assert_screen "shell transcript above live composer on zellij" empty "$CAPS_STYLED_NOID" "$live"
  assert_screen "shell transcript above live composer on cmux/orca" empty "$CAPS_PLAIN" "$live"
  pass "fm_composer_classify_screen: a lower dead shell invalidates only cursorless stale composers"
}

test_cursorless_bare_wrap_region_classifies() {
  local activity status bounded ghost out
  activity=$'❯\nWorking on request...'
  assert_screen "cursorless activity below bare row on herdr" pending "$CAPS_STYLED" "$activity"
  assert_screen "cursorless activity below bare row on zellij" pending "$CAPS_STYLED_NOID" "$activity"
  assert_screen "cursorless activity below bare row on cmux/orca" unknown "$CAPS_PLAIN" "$activity"

  status=$'›\n\ncodex status line'
  assert_screen "blank-separated codex status on herdr" empty "$CAPS_STYLED" "$status"
  assert_screen "blank-separated codex status on zellij" empty "$CAPS_STYLED_NOID" "$status"
  assert_screen "blank-separated codex status on cmux/orca" empty "$CAPS_PLAIN" "$status"

  bounded=$'────────────────────────\n❯\n────────────────────────\nClaude 4.1'
  assert_screen "rule-bounded claude footer on herdr" empty "$CAPS_STYLED" "$bounded" '' probe-absent
  assert_screen "rule-bounded claude footer on zellij" empty "$CAPS_STYLED_NOID" "$bounded"
  assert_screen "rule-bounded claude footer on cmux/orca" empty "$CAPS_PLAIN" "$bounded"

  ghost=$'❯ '"${ESC}[2ma long rotating suggestion that${ESC}[0m"$'\n'"${ESC}[2mwraps onto the next line${ESC}[0m"
  out=$(fm_composer_classify_screen "$CAPS_STYLED" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on herdr should be empty, got '$out'"
  out=$(fm_composer_classify_screen "$CAPS_STYLED_NOID" "$ghost")
  [ "$out" = empty ] || fail "cursorless ghost wrap on zellij should be empty, got '$out'"
  pass "fm_composer_classify_screen: cursorless bare wrap regions participate in verdicts"
}

test_cursorless_container_rejects_contiguous_lower_activity() {
  local box leftbar grok kimi opencode
  box=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nWorking on request...'
  assert_screen "stale box above activity on herdr" unknown "$CAPS_STYLED" "$box"
  assert_screen "stale box above activity on zellij" unknown "$CAPS_STYLED_NOID" "$box"
  assert_screen "stale box above activity on cmux/orca" unknown "$CAPS_PLAIN" "$box"

  leftbar=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\nWorking on request...'
  assert_screen "stale left-bar above activity on herdr" unknown "$CAPS_STYLED" "$leftbar"
  assert_screen "stale left-bar above activity on zellij" unknown "$CAPS_STYLED_NOID" "$leftbar"
  assert_screen "stale left-bar above activity on cmux/orca" unknown "$CAPS_PLAIN" "$leftbar"

  grok=$'╭────────────────────────╮\n│ ❯                      │\n╰──────── Grok 4.5 ──────╯\n\nGrok status'
  kimi=$'╭────────────────────────╮\n│ >                      │\n╰────────────────────────╯\n\nKimi status'
  opencode=$'┃\n┃  Ask anything...\n┃\n┃  Build · GPT-5.5 Fast OpenAI · high\n╹▀▀▀▀▀▀▀▀\n\nOpenCode status'
  assert_screen "blank-separated grok footer" empty "$CAPS_STYLED_NOID" "$grok"
  assert_screen "blank-separated kimi footer" empty "$CAPS_PLAIN" "$kimi"
  assert_screen "left-bar floor and blank-separated footer" empty "$CAPS_STYLED_NOID" "$opencode"
  pass "fm_composer_classify_screen: cursorless containers reject only contiguous unclaimed activity"
}

test_bottom_most_candidate_wins() {
  # The one ranking rule: the live composer is bottom-anchored, so a stale
  # decorative box (codex's startup banner) can never outrank the real row
  # below it - the confidently-wrong orca case from the audit.
  local screen out
  screen=$'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n❯'"$NBSP"
  assert_screen "banner above live claude row" empty "$CAPS_PLAIN" "$screen"
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" $'╭────────────────────────╮\n│ permissions: YOLO mode │\n╰────────────────────────╯\n› Use /skills to list available skills')
  [ "$out" != pending ] || fail "a stale banner must never classify as pending composer text"
  screen=$'❯ old draft\n\n❯'
  assert_screen "blank-separated newer bare composer" empty "$CAPS_STYLED_NOID" "$screen"
  pass "fm_composer_classify_screen: the bottom-most candidate wins; stale banners cannot"
}

test_incomplete_lower_box_invalidates_stale_candidate() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯\nstartup complete\n╭────────────────────────╮\n│ ❯ clipped live draft  '
  out=$(fm_composer_classify_screen "$CAPS_PLAIN" "$screen")
  [ "$out" = unknown ] \
    || fail "an incomplete lower box must invalidate an earlier empty box, got '$out'"
  pass "fm_composer_classify_screen: incomplete lower structure invalidates stale boxes"
}

test_titled_bottom_requires_matching_width() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰─ Grok ─╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 1)
  [ "$out" = unknown ] \
    || fail "a short titled bottom must not prove an empty box, got '$out'"
  pass "fm_composer_classify_screen: titled bottoms retain full box geometry"
}

test_cursor_on_proven_box_bottom_classifies_content() {
  local screen out
  screen=$'╭────────────────────────╮\n│ ❯                      │\n╰────────────────────────╯'
  out=$(fm_composer_classify_screen "$CAPS_TMUX" "$screen" 2)
  [ "$out" = empty ] \
    || fail "a cursor on a proven box bottom must classify its content, got '$out'"
  pass "fm_composer_classify_screen: a proven box tolerates a bottom-border cursor"
}

test_selected_content_is_composer_scoped_and_wrap_normalized() {
  local screen out
  screen=$'hello captain in transcript\n╭────────────────────╮\n│ unrelated          │\n│ draft               │\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'unrelated draft' ] \
    || fail "box extraction should contain only normalized selected composer rows, got '$out'"
  screen=$'hello captain in transcript\n┃ hello\n┃ captain\n┃ Build · GPT-5.5 Fast OpenAI · high'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'hello captain' ] \
    || fail "left-bar extraction should join user rows without footer furniture, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost agent-prompt placeholders should be excluded from extracted user content, got '$out'"
  screen=$'╭────────────────────╮\n│ > '"${ESC}[2mType a message...${ESC}[0m"$'│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ -z "$out" ] \
    || fail "ghost shell-prompt placeholders should be excluded from boxed user content, got '$out'"
  screen=$'╭────────────────────╮\n│ ❯ Type a message...│\n╰────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'Type a message...' ] \
    || fail "surviving placeholder-like input should remain extracted user content, got '$out'"
  screen=$'❯ a legitimately long steer that\nwraps across the next bare row\n\ntranscript below the break'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'a legitimately long steer that wraps across the next bare row' ] \
    || fail "bare extraction should include only its contiguous wrap region, got '$out'"
  screen=$'❯ wrapped user content\ncontinuation preserves a mid-row ❯ glyph'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content continuation preserves a mid-row ❯ glyph' ] \
    || fail "bare extraction should preserve mid-row agent glyph bytes, got '$out'"
  screen=$'❯ stale composer\n$ live shell'
  if out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen"); then
    fail "a lower live shell must invalidate composer extraction, got '$out'"
  fi
  screen=$'╭──────────────────────────────╮\n│ > wrapped user content       │\n│ ❯ preserves its leading glyph│\n╰──────────────────────────────╯'
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED_NOID" "$screen")
  [ "$out" = 'wrapped user content ❯ preserves its leading glyph' ] \
    || fail "box extraction should strip only its actual prompt-row glyph, got '$out'"
  pass "fm_composer_extract_selected_content: scopes user content and excludes furniture"
}

test_bare_shell_glyphs_are_unknown
test_stripped_unbordered_content_uses_plain_content
test_bare_shell_prompt_with_command_is_not_empty
test_bordered_shell_glyph_is_empty
test_agent_glyphs_are_empty_bordered_and_bare
test_empty_content_is_empty
test_idle_placeholder_is_empty
test_idle_placeholder_case_mode_is_explicit
test_real_text_is_pending
test_matrix_claude_bare_nbsp_row
test_matrix_codex_dim_hint_row
test_matrix_muse_truecolor_glyph_survives_signal_loss
test_matrix_cursor_reverse_video_placeholder_remnant
test_matrix_herdr_halfblock_rule_bounds_bare_wrap
test_matrix_omp_status_row_bounds_bare_composer
test_matrix_codex_idle_starfield_furniture
test_matrix_pi_separated_needs_identity
test_matrix_opencode_leftbar_signals
test_matrix_grok_titled_bottom_border
test_matrix_kimi_bordered_shell_glyph_box
test_matrix_claude_inside_zellij_ansi_dump
test_strict_blank_row_divergence
test_bare_wrap_region_classifies
test_contiguous_transcript_reanchors_on_live_prompt
test_lower_dead_shell_invalidates_cursorless_candidate
test_cursorless_bare_wrap_region_classifies
test_cursorless_container_rejects_contiguous_lower_activity
test_bottom_most_candidate_wins
test_incomplete_lower_box_invalidates_stale_candidate
test_titled_bottom_requires_matching_width
test_cursor_on_proven_box_bottom_classifies_content
test_selected_content_is_composer_scoped_and_wrap_normalized

test_queued_enter_verdict_busy_pending_is_empty() {
  local out
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = empty ] || fail "busy + proven pending must be queued delivery (empty), got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + busy returns empty (queued Enter)"
}

test_queued_enter_verdict_idle_pending_stays_pending() {
  local out
  out=$(fm_composer_queued_enter_verdict pending idle)
  [ "$out" = pending ] || fail "idle + proven pending must stay a genuine swallow, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending unknown)
  [ "$out" = pending ] || fail "unknown busy is not proof of a queue, got '$out'"
  pass "fm_composer_queued_enter_verdict: pending + idle/unknown stays pending"
}

test_queued_enter_verdict_does_not_convert_other_states() {
  local state out
  for state in empty pending-unproven unknown send-failed future-state; do
    out=$(fm_composer_queued_enter_verdict "$state" busy)
    [ "$out" = "$state" ] || fail "busy must not convert '$state', got '$out'"
    out=$(fm_composer_queued_enter_verdict "$state" idle)
    [ "$out" = "$state" ] || fail "idle must not convert '$state', got '$out'"
  done
  pass "fm_composer_queued_enter_verdict: only proven pending is converted"
}

test_queued_enter_verdict_busy_pending_is_empty
test_queued_enter_verdict_idle_pending_stays_pending
test_queued_enter_verdict_does_not_convert_other_states

# =============================================================================
# pi 0.85 working-composer shapes, from byte-level captures of a REAL pi
# =============================================================================
# tests/assets/pi-0.85-composer/ holds tail captures of live pi 0.85.1 panes
# driven in a disposable tmux server, stock and with Calm on
# (docs/verification/pi-composer-shapes.md records how they were taken and
# what each one proves). They exist because the FIRST attempt at this fix was
# written from a guessed rendering and had to be reverted; every assertion
# below reads the captured bytes rather than a description of them.
#
# What the captures established, and what these cases pin:
#   - pi >=0.85 embeds its working indicator in the composer's own TOP border
#     instead of drawing a `Working...` row inside the separator pair, so the
#     pair itself has to be recognized through a titled rule.
#   - Calm clears that indicator and draws its boat ABOVE the pair, so the
#     composer region is blank in BOTH presentations while pi generates:
#     a working pi never holds unsubmitted input.
#   - Real typed text still reads `pending` in both states, and a pane whose
#     keyboard belongs to something in front of the composer reads `unknown`.
PI_085_ASSETS="$ROOT/tests/assets/pi-0.85-composer"

# pi_085_screen/pi_085_cursor: one captured frame and its captured cursor row.
pi_085_screen() { cat "$PI_085_ASSETS/$1.ansi"; }
pi_085_cursor() { cat "$PI_085_ASSETS/$1.cursor"; }

# pi_085_busy: the delivery busy verdict for a captured frame, read the way
# the herdr adapter reads a live pane (last 12 non-blank rows, opted into the
# pi shapes with `+pi-shapes`). The scope argument is the whole point: these
# captures came through herdr, so only a herdr delivery read may consult them.
# Read in BOTH locales, and disagreement is itself a failure: the daemons that
# consume this verdict run in the C locale, so a shape that matches only under
# a UTF-8 locale is dead exactly where an unconfirmed submit becomes a
# re-injection wedge (the issue #1988 class, which is why assert_screen above
# does the same for every classifier assertion). The titled border was dead
# that way once: `─+` quantified only a rule glyph's trailing byte, and a
# negated class holding `─` also excluded the spinner cell's leading byte.
pi_085_busy() {  # <fixture> [harness] [shape-scope]
  local visible utf8 c
  visible=$(pi_085_screen "$1" | fm_composer_strip_ansi | grep -v '^[[:space:]]*$' | tail -12)
  utf8=idle; c=idle
  printf '%s' "$visible" | fm_busy_lines_match "${2:-pi}" "${3-+pi-shapes}" && utf8=busy
  printf '%s' "$visible" | LC_ALL=C fm_busy_lines_match "${2:-pi}" "${3-+pi-shapes}" && c=busy
  [ "$utf8" = "$c" ] \
    || fail "pi 0.85 busy read for '$1' (harness='${2:-pi}' scope='${3-+pi-shapes}') disagrees across locales: $utf8 vs LC_ALL=C $c"
  printf '%s' "$utf8"
}

# pi_085_busy_row: the same two-locale reading for a single synthetic row, so
# the refusals are pinned in the C locale too.
pi_085_busy_row() {  # <row>
  local utf8=idle c=idle
  printf '%s\n' "$1" | fm_busy_lines_match pi +pi-shapes && utf8=busy
  printf '%s\n' "$1" | LC_ALL=C fm_busy_lines_match pi +pi-shapes && c=busy
  [ "$utf8" = "$c" ] \
    || fail "pi 0.85 busy read for row '$1' disagrees across locales: $utf8 vs LC_ALL=C $c"
  printf '%s' "$utf8"
}

test_pi_085_working_composer_is_never_unsubmitted_input() {
  local fixture plain
  # The headline capture-driven fact: while pi generates, its composer region
  # is EMPTY in both presentations. The RCA that scoped this fix assumed the
  # opposite (that the working indicator or the Calm boat sat inside the
  # separator pair and read `pending`); the captures disprove it, so a working
  # pi must never be reported as holding a half-typed message.
  for fixture in stock-working calm-working; do
    assert_screen "pi 0.85 $fixture is not unsubmitted input" unknown \
      "$CAPS_TMUX" "$(pi_085_screen "$fixture")" "$(pi_085_cursor "$fixture")" "pi"$'\t'"working"
    # Non-vacuousness, without relying on a verdict: the pair really was found
    # and valid, and its region really classifies as non-pending, so the
    # `unknown` above is a refusal to call a generating pane injectable rather
    # than an unreadable pane.
    plain=$(pi_085_screen "$fixture" | fm_composer_strip_ansi)
    _fm_composer_scan_screen "$plain" "$(pi_085_cursor "$fixture")"
    [ "$FM_COMPOSER_SCAN_PI_PAIR_VALID" = 1 ] \
      || fail "pi 0.85 $fixture: the composer pair was not found and valid, so the verdict proves nothing"
    [ "$(_fm_composer_classify_pi_rows "$(pi_085_screen "$fixture")" 1)" != pending ] \
      || fail "pi 0.85 $fixture: the composer region is not blank after all"
  done
  # The Calm capture's opener is a SOLID rule (Calm clears pi's indicator), so
  # its blankness is still observable through a verdict: read as an idle pi it
  # is `empty`. The stock capture's opener is titled, which is itself proof the
  # pane is generating, so it is refused below whatever status is handed in.
  # This `empty` for a GENERATING Calm pane is a KNOWN RECORDED GAP, not a
  # property worth having: see "Still reachable, and NOT introduced here" in
  # docs/verification/pi-composer-shapes.md. It predates this branch, and the
  # titled-opener refusal cannot reach it because Calm leaves no titled opener
  # to refuse. Asserted so the gap's exact shape is visible rather than latent.
  assert_screen "pi 0.85 calm-working region is blank" empty \
    "$CAPS_TMUX" "$(pi_085_screen calm-working)" "$(pi_085_cursor calm-working)" "pi"$'\t'"idle"
  pass "pi 0.85: a generating pi's composer is blank in both presentations and is never read as unsubmitted input"
}

test_pi_085_titled_opener_is_never_injectable_whatever_the_status() {
  # `empty` is the verdict that authorizes the away-mode injector to type into
  # a pane, so it must never be reachable for a pane that is mid-turn. The
  # agent_status handed to the classifier cannot be trusted to say so: on the
  # tmux plane it is derived from a busy read that does not carry pi's 0.85
  # shapes, so a generating pi arrives here as `pi<TAB>idle`, and before this
  # refusal the stock capture classified `empty` for it.
  # The titled opener is the structural proof instead: pi draws that border
  # titled only while a status indicator is set, so a pair opened by one
  # cannot belong to a settled pane, on any backend and with no shape
  # activation anywhere.
  local st verdict
  for st in idle 'done' working blocked; do
    verdict=$(fm_composer_classify_screen "$CAPS_TMUX" "$(pi_085_screen stock-working)" \
      "$(pi_085_cursor stock-working)" "pi"$'\t'"$st")
    [ "$verdict" != empty ] \
      || fail "a generating pi whose composer pair was opened by a titled border must never be injectable (agent_status=$st)"
    [ "$verdict" = unknown ] \
      || fail "a titled-opener pair should defer as unknown on agent_status=$st, got '$verdict'"
  done
  # And the refusal is keyed to the TITLED opener, not to pi in general: a
  # settled pi whose opener is a solid rule still reads empty, so the
  # away-mode injector is not blinded fleet-wide.
  assert_screen "pi 0.85 settled pi still injectable" empty \
    "$CAPS_TMUX" "$(pi_085_screen calm-idle)" "$(pi_085_cursor calm-idle)" "pi"$'\t'"idle"
  pass "pi 0.85: a pair opened by pi's titled working border is never injectable, while a settled pi still is"
}

test_pi_085_titled_border_is_what_makes_the_working_pair_readable() {
  # The counterfactual for the stock capture specifically: its opening rule is
  # titled (`── <spinner> Working ────`), so without titled-border recognition
  # the pair is not found AT ALL and the pane is unreadable rather than blank.
  # Drive the two presentations apart to prove the fix is load-bearing for
  # exactly the one that changed.
  local plain
  plain=$(pi_085_screen stock-working | fm_composer_strip_ansi)
  _fm_composer_scan_screen "$plain" "$(pi_085_cursor stock-working)"
  [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
    || fail "the captured stock working pane's titled top border was not recognized as a composer pair"
  [ "$FM_COMPOSER_SCAN_PI_PAIR_VALID" = 1 ] \
    || fail "the captured stock working pane's composer pair was found but not valid"
  # Calm's capture never needed it: Calm clears the indicator, so its opening
  # rule is solid and the pre-existing plain-rule scan already found the pair.
  plain=$(pi_085_screen calm-working | fm_composer_strip_ansi)
  _fm_composer_scan_screen "$plain" "$(pi_085_cursor calm-working)"
  [ "$FM_COMPOSER_SCAN_PI_PAIR_FOUND" = 1 ] \
    || fail "the captured Calm working pane's solid composer pair was not found"
  pass "pi 0.85: the titled top border is what makes a stock generating pi's composer readable at all"
}

test_pi_085_titled_border_predicate_rejects_other_harnesses() {
  # The predicate must recognize pi's indicator border by the vendor's own
  # composition, not by any titled rule: muse draws a WORD-titled rule and must
  # not be mistaken for a pi composer top border.
  _fm_composer_pi_titled_open_row '── ⠦ Working ────────────────────────' \
    || fail "pi's captured working border was rejected"
  _fm_composer_pi_titled_open_row '── ⠦ ────────────────────────' \
    || fail "pi's narrow spinner-only border fallback was rejected"
  ! _fm_composer_pi_titled_open_row '── Voice input (⌥ + v to start) ─────────────' \
    || fail "muse's word-titled rule was accepted as a pi composer border"
  ! _fm_composer_pi_titled_open_row '────────────────────────────────' \
    || fail "a solid rule was accepted as a TITLED border"
  ! _fm_composer_pi_titled_open_row '── ⠦ Working' \
    || fail "a border with no closing rule run was accepted"
  pass "pi 0.85: the titled-border predicate accepts pi's indicator border and rejects a word-titled rule"
}

test_pi_085_real_typed_text_stays_pending() {
  # The counterfactuals, both captured from a live pane with real keystrokes in
  # the composer. Neither may be converted into "delivered": a half-typed
  # message must keep earning its Enter retry and must never be typed over.
  assert_screen "pi 0.85 typed while idle" pending \
    "$CAPS_TMUX" "$(pi_085_screen calm-typed-idle)" "$(pi_085_cursor calm-typed-idle)" "pi"$'\t'"idle"
  assert_screen "pi 0.85 typed while working" pending \
    "$CAPS_TMUX" "$(pi_085_screen calm-typed-working)" "$(pi_085_cursor calm-typed-working)" "pi"$'\t'"working"
  pass "pi 0.85: real typed text in the composer stays pending whether pi is idle or generating"
}

test_pi_085_modal_in_front_of_the_composer_is_unknown() {
  # Captured live: with a modal open, typed text lands in the MODAL's own row,
  # the composer is not what owns the keyboard, and Enter selects in the modal
  # instead of submitting. The verdict must be `unknown` - never `empty` (which
  # would authorize typing into it) and never `pending` (which a caller could
  # convert into proof of a queued delivery).
  local st verdict
  for st in idle working blocked; do
    verdict=$(fm_composer_classify_screen "$CAPS_TMUX" "$(pi_085_screen modal-eats-enter)" \
      "$(pi_085_cursor modal-eats-enter)" "pi"$'\t'"$st")
    [ "$verdict" = unknown ] \
      || fail "a pi pane whose keyboard belongs to a modal must read unknown on agent_status=$st, got '$verdict'"
  done
  pass "pi 0.85: a modal in front of the composer reads unknown, never an injectable empty or a convertible pending"
}

test_pi_085_busy_shapes_from_the_captures() {
  local out
  # Both presentations of a genuinely generating pi must read busy: this is the
  # read that turns a landed steer into a confirmed one. Before the captures,
  # BOTH read idle - pi 0.85 dropped the `Working...` ellipsis the token
  # required and moved the indicator off the transcript entirely.
  out=$(pi_085_busy stock-working); [ "$out" = busy ] \
    || fail "the captured stock generating pi must read busy, got '$out'"
  out=$(pi_085_busy calm-working); [ "$out" = busy ] \
    || fail "the captured Calm generating pi must read busy, got '$out'"
  # The herdr submit core reads a pane with NO recorded harness, so the
  # harness-less union must honour the scope too or a confirmed submit still
  # cannot be proven there.
  out=$(pi_085_busy stock-working ''); [ "$out" = busy ] \
    || fail "the harness-less union must also read the captured stock generating pi busy, got '$out'"
  out=$(pi_085_busy calm-working ''); [ "$out" = busy ] \
    || fail "the harness-less union must also read the captured Calm generating pi busy, got '$out'"
  # And the inverse, from captures of the same pane: settled and typed-into
  # panes are idle, so busy is a transition signal rather than a constant.
  out=$(pi_085_busy calm-idle); [ "$out" = idle ] \
    || fail "the captured settled pi must read idle, got '$out'"
  out=$(pi_085_busy calm-typed-idle); [ "$out" = idle ] \
    || fail "the captured idle pi holding typed text must read idle, got '$out'"
  out=$(pi_085_busy modal-eats-enter); [ "$out" = idle ] \
    || fail "the captured modal-parked pi must read idle, got '$out'"
  pass "pi 0.85: both generating presentations read busy while settled, typed-into, and modal-parked panes read idle"
}

test_pi_085_busy_shapes_are_opt_in_per_reader() {
  # The captures were taken through the herdr adapter, and herdr's submit core
  # is the only one that pairs a busy reading with a pre-Enter composer
  # narrowing. A reader that does NOT ask for the shapes must therefore see a
  # generating pi exactly as it did before these captures existed - which is
  # what keeps the tmux submit core's baseline-gated conversion unreachable
  # for pi until tmux captures of its own authorize it. A busy reading tmux
  # cannot narrow is a busy reading that can convert an undelivered message
  # into a confirmed one.
  local out fixture
  for fixture in stock-working calm-working; do
    out=$(pi_085_busy "$fixture" pi ''); [ "$out" = idle ] \
      || fail "the pi regex must not carry the shapes without the opt-in scope ($fixture), got '$out'"
    out=$(pi_085_busy "$fixture" '' ''); [ "$out" = idle ] \
      || fail "the harness-less union must not carry the shapes without the opt-in scope ($fixture), got '$out'"
  done
  # And the scope is what production actually reads: every herdr call site
  # passes no harness, so the harness-less union plus `+pi-shapes` is the one
  # combination a live herdr pane is ever classified by. Pin that combination
  # rather than a harness argument no caller supplies - the shapes are scoped
  # to the herdr BACKEND, not to the pi HARNESS, so they are consulted for
  # every herdr pane whatever harness it runs.
  for fixture in stock-working calm-working; do
    out=$(pi_085_busy "$fixture" ''); [ "$out" = busy ] \
      || fail "the reading production takes (harness-less union, +pi-shapes) must read the captured generating pi busy ($fixture), got '$out'"
  done
  out=$(pi_085_busy calm-idle ''); [ "$out" = idle ] \
    || fail "the reading production takes must leave a settled pi idle, got '$out'"
  pass "pi 0.85: the captured busy shapes are opt-in per reader, and the reading production takes is the harness-less union"
}

test_pi_085_busy_shapes_reject_the_word_alone() {
  # The trap the reverted attempt fell into: matching pi's MESSAGE rather than
  # its border would make ordinary prose a busy signal, and a busy signal is
  # what converts a still-pending composer into "delivered". A `pending`
  # composer plus a false busy is a message reported delivered that never was.
  local text out
  while IFS= read -r text; do
    out=$(pi_085_busy_row "$text")
    [ "$out" = idle ] || fail "user text '$text' must not read busy"
  done <<'TEXT'
Working on the auth refactor
still Working
\__/
the boat is -~~~\__/-~~~ in prose
── Voice input (⌥ + v to start) ─────────────
────────────────────────────────
── ⠦ Working
TEXT
  # ... and the shapes the vendor really does emit still read busy, in both
  # locales, so the refusals above are a narrowing rather than a dead pattern.
  out=$(pi_085_busy_row '── ⠦ Working ────────────────────────')
  [ "$out" = busy ] || fail "pi's captured working border must read busy, got '$out'"
  out=$(pi_085_busy_row '── ⠦ ────────────────────────')
  [ "$out" = busy ] || fail "pi's narrow spinner-only border must read busy, got '$out'"
  # Rows whose STATUS MESSAGE carries non-ASCII bytes. None of the committed
  # captures does - every one spells pi's default ASCII `Working` - which is
  # why the two-locale helper alone could not catch a message segment that was
  # byte-fragile. Each of these read busy under UTF-8 and idle under LC_ALL=C
  # while the segment was a negated class holding the rule glyph, whose bytes
  # are also continuation bytes of these characters.
  local row
  for row in '── ⠦ Working… ──────────────────' \
    '── ⠦ Thinking → tool ────────────' \
    '── ⠦ retry in 3s • attempt 2 ────────' \
    '── ⣀ Working ────────────────'; do
    out=$(pi_085_busy_row "$row")
    [ "$out" = busy ] || fail "a working border whose message carries non-ASCII bytes must read busy, got '$out' for '$row'"
  done
  # Calm's hull at the RIGHT EDGE of its traverse: the renderer's track span is
  # `width - HULL_WIDTH`, so the hull ends at the last column with no water
  # after it. That frame read idle while the shape required trailing water -
  # one frame of every traverse misreading a generating Calm pi as settled.
  out=$(pi_085_busy_row '-~~~-~~~-~~~-~~~-~~~-~~~\__/')
  [ "$out" = busy ] || fail "Calm's right-edge hull frame must read busy, got '$out'"
  pass "pi 0.85: pi's working WORD, its Calm sprite glyphs, and another harness's word-titled rule are never busy signals"
}

test_pi_085_working_composer_is_never_unsubmitted_input
test_pi_085_titled_opener_is_never_injectable_whatever_the_status
test_pi_085_titled_border_is_what_makes_the_working_pair_readable
test_pi_085_titled_border_predicate_rejects_other_harnesses
test_pi_085_real_typed_text_stays_pending
test_pi_085_modal_in_front_of_the_composer_is_unknown
test_pi_085_busy_shapes_from_the_captures
test_pi_085_busy_shapes_are_opt_in_per_reader
test_pi_085_busy_shapes_reject_the_word_alone

test_pi_085_titled_row_pasted_into_an_open_composer_stays_pending() {
  # Regression: the titled-border predicate above recognizes pi's composer TOP
  # border, but the same shape can arrive as CONTENT - any pasted box art or
  # table whose last line is a `── <glyph> ... ────────` rule. Accepting it as
  # an opener while a pair is already open re-opens the pair below itself, and
  # the classifier then scans the blank remainder and reports `empty`.
  # `empty` is the verdict that authorizes the away-mode injector to type into
  # the pane, so it must never be reachable for a composer that still holds
  # the operator's unsent text: that text would be typed over, and the submit
  # that followed would be "confirmed" against a composer that never cleared.
  local screen
  screen=$(printf '%s\n' \
    'transcript' \
    '────────────────────────────────' \
    'real unsent text' \
    '── ⚑ Section ────────────────────' \
    '' \
    '────────────────────────────────')
  assert_screen "pi 0.85 titled rule pasted inside an open composer" pending \
    "$CAPS_TMUX" "$screen" 4 "pi"$'\t'"idle"
  pass "pi 0.85: a titled rule INSIDE an open composer pair is content, so real unsent text stays pending"
}

test_queued_enter_verdict_excludes_pi() {
  # pi is excluded from the pending+busy queued-Enter conversion. The
  # conversion's premise is opencode 1.18.4's: Enter mid-turn is accepted and
  # QUEUED while the typed text stays visible. No capture establishes that for
  # pi; pi 0.85.1 was observed to render a `Steering:` row and CLEAR its
  # composer on an accepted mid-turn submit instead, so text still sitting in
  # a generating pi's composer is evidence AGAINST delivery. Converting it
  # would report an undelivered message as delivered; `pending` keeps the
  # durable steering inbox re-ringing.
  local out harness
  for harness in pi pi-signed; do
    out=$(fm_composer_queued_enter_verdict pending busy "$harness")
    [ "$out" = pending ] \
      || fail "a busy $harness pane whose composer still holds text must stay pending, got '$out'"
  done
  # The exclusion is harness-scoped, not a removal of the policy: every other
  # harness (and a caller with no recorded harness) keeps the conversion.
  out=$(fm_composer_queued_enter_verdict pending busy opencode)
  [ "$out" = empty ] || fail "the queued-Enter conversion must survive for opencode, got '$out'"
  out=$(fm_composer_queued_enter_verdict pending busy)
  [ "$out" = empty ] || fail "the queued-Enter conversion must survive for a harness-less caller, got '$out'"
  # And the exclusion never manufactures a verdict of its own.
  out=$(fm_composer_queued_enter_verdict empty busy pi)
  [ "$out" = empty ] || fail "a cleared composer must stay empty for pi too, got '$out'"
  out=$(fm_composer_queued_enter_verdict unknown busy pi)
  [ "$out" = unknown ] || fail "an unreadable composer must stay unknown for pi too, got '$out'"
  pass "fm_composer_queued_enter_verdict: pi is excluded from the pending+busy conversion, every other harness keeps it"
}

test_pi_085_titled_row_pasted_into_an_open_composer_stays_pending
test_queued_enter_verdict_excludes_pi
