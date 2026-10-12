#!/usr/bin/env bash
#
# run-unit-tests.sh — run rafay_nvcm_poc's OFFLINE gates (test/run-tests.sh) one phase/group at a time, on the
# GitHub runner. No lab, no SSH, no cloud: these gates need only python + the POC checkout.
#
#   run-unit-tests.sh groups    <phase> [selection]          # JSON array of the phase's groups (matrix input)
#   run-unit-tests.sh list      <phase> [group]              # the gate paths, in run order
#   run-unit-tests.sh coverage  <poc_dir>                    # manifest == the POC's run-tests.sh, or fail
#   run-unit-tests.sh run       <phase> <group> <poc_dir> <out_dir>
#   run-unit-tests.sh summarize <phase> <dir>                # merge every results.tsv under <dir> → summary.md
#
# The manifest is config/unit-tests.sh (phase:group:path). <selection> is "all" or a comma list of groups.
# `run` mirrors run-tests.sh's verdicts exactly — exit 0 passed, exit 77 SKIPPED, anything else failed — and its
# suite env (DC_NO_PUBLISH=1, DC_BLUEPRINT=stc/blueprint_stc.yaml). DC_REQUIRE_ALL_GATES defaults to 1 here, as
# in CI: a skipped gate proved nothing, so it fails the group. Every gate runs even after a failure; one row per
# gate goes to <out_dir>/results.tsv, its output to <out_dir>/logs/. Exit non-zero iff a gate failed.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=config/unit-tests.sh
. "$ROOT/config/unit-tests.sh"
log(){ echo "[unit] $*" >&2; }
die(){ log "$*"; exit 2; }

selected(){ [ "$1" = all ] || [[ ",$1," == *",$2,"* ]]; }

known_phase(){
  local p
  for p in "${LAUNCHPAD_UNIT_PHASES[@]}"; do [ "$p" = "$1" ] && return 0; done
  die "unknown phase '$1' (known: ${LAUNCHPAD_UNIT_PHASES[*]})"
}

# the phase's groups, in manifest order, one per line
phase_groups(){
  local e ph grp seen=" "
  for e in "${LAUNCHPAD_UNIT_TESTS[@]}"; do
    IFS=: read -r ph grp _ <<< "$e"
    [ "$ph" = "$1" ] || continue
    [[ "$seen" == *" $grp "* ]] && continue
    seen+="$grp "; echo "$grp"
  done
}

cmd_groups(){
  local phase="$1" sel="${2:-all}" g want known out=""
  known_phase "$phase"
  known=" $(phase_groups "$phase" | tr '\n' ' ')"
  if [ "$sel" != all ]; then
    IFS=, read -ra want <<< "$sel"
    for g in "${want[@]}"; do
      [[ "$known" == *" $g "* ]] || die "phase '$phase' has no group '$g' (known:$known)"
    done
  fi
  for g in $known; do selected "$sel" "$g" && out+="\"$g\","; done
  [ -n "$out" ] || die "selection '$sel' picks no group of phase '$phase'"
  echo "[${out%,}]"
}

cmd_list(){
  local phase="$1" group="${2:-}" e ph grp path
  known_phase "$phase"
  for e in "${LAUNCHPAD_UNIT_TESTS[@]}"; do
    IFS=: read -r ph grp path <<< "$e"
    [ "$ph" = "$phase" ] && { [ -z "$group" ] || [ "$grp" = "$group" ]; } && echo "$path"
  done
  return 0
}

cmd_coverage(){
  local poc="$1" e ph grp path fail=0 suite mine
  [ -f "$poc/test/run-tests.sh" ] || die "no test/run-tests.sh under '$poc' — is that a rafay_nvcm_poc checkout?"
  suite="$(mktemp)"; mine="$(mktemp)"
  # the gate files run-tests.sh runs: every `run "<desc>" <file>` line (the file is its last word)
  grep -E '^run "' "$poc/test/run-tests.sh" | awk '{print $NF}' | sort > "$suite"
  for e in "${LAUNCHPAD_UNIT_TESTS[@]}"; do
    IFS=: read -r ph grp path <<< "$e"
    [ "$path" = @preflight ] && continue
    echo "$path"
  done | sort > "$mine"

  local dup; dup="$(uniq -d "$mine")"
  [ -z "$dup" ] || { echo "::error title=Unit manifest::gate(s) mapped more than once: $(echo "$dup" | paste -sd' ' -)"; fail=1; }
  while read -r path; do
    echo "::error title=Unmapped POC gate::$path is in rafay_nvcm_poc test/run-tests.sh but not in config/unit-tests.sh — add it under its phase (see the file's header)"
    fail=1
  done < <(comm -23 "$suite" <(uniq "$mine"))
  while read -r path; do
    echo "::error title=Stale unit-manifest entry::$path is in config/unit-tests.sh but rafay_nvcm_poc test/run-tests.sh no longer runs it — remove it"
    fail=1
  done < <(comm -13 "$suite" <(uniq "$mine"))
  if printf '%s\n' "${LAUNCHPAD_UNIT_TESTS[@]}" | grep -q ':@preflight$' \
     && ! grep -q 'verify_blueprint.sh --blueprint stc/blueprint_stc.yaml' "$poc/test/run-tests.sh"; then
    echo "::error title=Stale unit-manifest entry::@preflight mirrors run-tests.sh's verify_blueprint.sh block, which is gone — update both"
    fail=1
  fi
  log "coverage: $(wc -l < "$suite" | tr -d ' ') gates in run-tests.sh, $(wc -l < "$mine" | tr -d ' ') mapped"
  rm -f "$suite" "$mine"
  [ "$fail" -eq 0 ] || exit 1
  log "coverage: OK — every POC gate is mapped exactly once"
}

# the inline preflight block of run-tests.sh, verbatim in effect: needs pyyaml, else it is a skip (77)
run_preflight(){
  "$PY" -c "import yaml" 2>/dev/null || { echo "SKIPPED: verify_blueprint.sh needs pyyaml"; return 77; }
  PYTHON="$PY" bash deploy_scripts/verify_blueprint.sh --blueprint stc/blueprint_stc.yaml --tenants "3-100"
}

cmd_run(){
  local phase="$1" group="$2" poc="$3" out="$4"
  known_phase "$phase"
  [ -f "$poc/test/run-tests.sh" ] || die "no test/run-tests.sh under '$poc' — is that a rafay_nvcm_poc checkout?"
  mkdir -p "$out/logs"; out="$(cd "$out" && pwd)"
  local gates=() g
  while IFS= read -r g; do gates+=("$g"); done < <(cmd_list "$phase" "$group")
  [ "${#gates[@]}" -gt 0 ] || die "phase '$phase' has no group '$group'"

  cd "$poc"
  # interpreter: explicit PYTHON=, then the checkout's .venv, then python3 — the same order as run-tests.sh
  if [ -n "${PYTHON:-}" ]; then PY="$PYTHON"
  elif [ -x "$PWD/.venv/bin/python3" ]; then PY="$PWD/.venv/bin/python3"
  else PY=python3; fi
  export DC_NO_PUBLISH=1                                          # NO GATE MAY PUBLISH (run-tests.sh's first line)
  export DC_BLUEPRINT="${DC_BLUEPRINT:-$PWD/stc/blueprint_stc.yaml}"  # the fail-closed tenant policy needs one named
  local require_all="${DC_REQUIRE_ALL_GATES:-1}"

  log "phase $phase / group $group: ${#gates[@]} gate(s) with $("$PY" --version 2>&1), DC_REQUIRE_ALL_GATES=$require_all"
  : > "$out/results.tsv"
  local n=0 passed=0 failed=0 skipped=0 rc secs t0 status name lf
  for g in "${gates[@]}"; do
    n=$((n+1))
    name="$(basename "$g" .py)"; [ "$g" = @preflight ] && name=preflight
    lf="$out/logs/$(printf '%03d' "$n")-$name.log"
    echo "::group::[$n/${#gates[@]}] $g"
    t0=$SECONDS; rc=0
    if [ "$g" = @preflight ]; then run_preflight > "$lf" 2>&1 || rc=$?
    else "$PY" "$g" > "$lf" 2>&1 || rc=$?; fi
    secs=$((SECONDS - t0))
    cat "$lf"
    echo "::endgroup::"
    if [ "$rc" -eq 0 ]; then status=passed; passed=$((passed+1)); echo "  ✓ $g (${secs}s)"
    elif [ "$rc" -eq 77 ]; then
      status=skipped; skipped=$((skipped+1))
      if [ "$require_all" = 1 ]; then
        echo "::error title=Gate skipped: $name::$g SKIPPED (proved nothing) and DC_REQUIRE_ALL_GATES=1 — its own SKIPPED line in the log says why"
      else echo "  ⊘ SKIPPED (proved nothing): $g"; fi
    else
      status=failed; failed=$((failed+1))
      echo "::error title=Gate failed: $name::$g rc=$rc — last lines:%0A$(tail -n 15 "$lf" | sed 's/%/%25/g' | awk '{printf "%s%%0A",$0}')"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$g" "$status" "$rc" "$secs" >> "$out/results.tsv"
  done

  log "phase $phase / group $group: $passed passed, $failed failed, $skipped skipped (of $n)"
  [ "$failed" -eq 0 ] && { [ "$skipped" -eq 0 ] || [ "$require_all" != 1 ]; }
}

cmd_summarize(){
  local phase="$1" dir="$2" f grp gate status rc secs icon
  local tot=0 p=0 fl=0 sk=0 files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -name results.tsv | sort)
  {
    echo "## Unit tests · $phase"
    echo
    if [ "${#files[@]}" -eq 0 ]; then echo "_No results — every group failed before running a gate._"; exit 0; fi
    echo "| Group | Gate | Result | Seconds |"
    echo "|---|---|---|---:|"
    for f in "${files[@]}"; do
      while IFS=$'\t' read -r grp gate status rc secs; do
        tot=$((tot+1))
        case "$status" in
          passed)  icon="✅ passed"; p=$((p+1)) ;;
          skipped) icon="⊘ skipped"; sk=$((sk+1)) ;;
          *)       icon="❌ failed (rc=$rc)"; fl=$((fl+1)) ;;
        esac
        echo "| $grp | \`$gate\` | $icon | $secs |"
      done < "$f"
    done
    echo
    echo "**$tot gates: $p passed, $fl failed, $sk skipped.**"
  } | tee "$dir/summary.md"
}

sub="${1:-}"; shift || true
case "$sub" in
  groups)    [ $# -ge 1 ] || die "usage: groups <phase> [selection]";            cmd_groups "$@" ;;
  list)      [ $# -ge 1 ] || die "usage: list <phase> [group]";                  cmd_list "$@" ;;
  coverage)  [ $# -eq 1 ] || die "usage: coverage <poc_dir>";                    cmd_coverage "$@" ;;
  run)       [ $# -eq 4 ] || die "usage: run <phase> <group> <poc_dir> <out_dir>"; cmd_run "$@" ;;
  summarize) [ $# -eq 2 ] || die "usage: summarize <phase> <dir>";               cmd_summarize "$@" ;;
  *) awk 'NR>2{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit 2 ;;
esac
