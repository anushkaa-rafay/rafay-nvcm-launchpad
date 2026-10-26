#!/usr/bin/env bash
#
# run-unit-tests.sh — run rafay_nvcm_poc's OFFLINE gates (test/run-tests.sh) one phase/group at a time, on the
# GitHub runner. No lab, no SSH, no cloud: these gates need only python + the POC checkout.
#
#   run-unit-tests.sh groups    <phase> [selection]          # JSON array of the phase's groups
#   run-unit-tests.sh matrix    <phase|all> [selection]      # JSON [{phase,group}] — unit-tests.yml's matrix input
#   run-unit-tests.sh list      <phase> [group]              # the gate paths, in run order
#   run-unit-tests.sh coverage  <poc_dir>                    # manifest == the POC's run-tests.sh, or fail
#   run-unit-tests.sh run       <phase> <group> <poc_dir> <out_dir>
#   run-unit-tests.sh summarize <phase|all> <dir> [selection] # every <dir>/unit-<phase>-<group>/ → summary.md
#   run-unit-tests.sh combine   <phase|all> <dir> [selection] # the same → ONE log, phase/group/gate headers
#
# The manifest is config/unit-tests.sh (phase:group:path). <selection> is "all" or a comma list of groups; with
# phase "all" it must be "all" (a group selection only makes sense inside one phase). summarize/combine read the
# run's artifacts as downloaded — <dir>/unit-<phase>-<group>/{results.tsv,logs/} — and flag every planned group
# (phase + selection) that has none: its job died before its first gate, and it must not vanish from the report.
# `run` mirrors run-tests.sh's verdicts exactly — exit 0 passed, exit 77 SKIPPED, anything else failed — and its
# suite env (DC_NO_PUBLISH=1, DC_BLUEPRINT=stc/blueprint_stc.yaml). DC_REQUIRE_ALL_GATES defaults to 1 here, as
# in CI: a skipped gate proved nothing, so it fails the group. Every gate runs even after a failure; one row per
# gate goes to <out_dir>/results.tsv (phase, group, gate, status, rc, secs, log), its output to <out_dir>/logs/.
# Exit non-zero iff a gate failed.
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

# the planned "phase group" pairs, one per line in manifest order — the matrix, and what summarize/combine expect
planned(){
  local sel="${2:-all}" ph g gs
  local phases=("$1")
  if [ "$1" = all ]; then
    [ "$sel" = all ] || die "groups '$sel' needs one phase — with phase 'all' every group runs"
    phases=("${LAUNCHPAD_UNIT_PHASES[@]}")
  fi
  for ph in "${phases[@]}"; do
    gs="$(cmd_groups "$ph" "$sel")" || exit         # set -e doesn't reach into $(…): an unknown group must fail
    for g in $(echo "$gs" | tr -d '[]"' | tr , ' '); do echo "$ph $g"; done
  done
}

cmd_matrix(){
  local pl ph g out=""
  pl="$(planned "$@")" || exit
  while read -r ph g; do out+="{\"phase\":\"$ph\",\"group\":\"$g\"},"; done <<< "$pl"
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
    echo "::group::[$phase/$group $n/${#gates[@]}] $g"
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$phase" "$group" "$g" "$status" "$rc" "$secs" "$(basename "$lf")" >> "$out/results.tsv"
  done

  log "phase $phase / group $group: $passed passed, $failed failed, $skipped skipped (of $n)"
  [ "$failed" -eq 0 ] && { [ "$skipped" -eq 0 ] || [ "$require_all" != 1 ]; }
}

# Summary tab: one table per phase (group · gate · result · time), a total, then a collapsible log tail for every
# gate that didn't pass. Log lines are capped (TAIL_LINES × MAX_LINE) so the step summary stays under GitHub's 1 MiB.
TAIL_LINES=100; MAX_LINE=400
cmd_summarize(){
  local want="$1" dir="$2" sel="${3:-all}" f ph grp gate status rc secs lf icon
  local phases=("$1") bad=() plan tot=0 p=0 fl=0 sk=0 nr=0
  [ "$want" = all ] && phases=("${LAUNCHPAD_UNIT_PHASES[@]}") || known_phase "$want"
  plan="$(planned "$want" "$sel")" || exit
  {
    echo "## Unit tests · $want"
    echo
    for ph in "${phases[@]}"; do
      local rows="" pt=0 pp=0 pf=0 ps=0 pn=0
      while read -r _ph grp; do
        [ "$_ph" = "$ph" ] || continue
        f="$dir/unit-$ph-$grp/results.tsv"
        if [ ! -s "$f" ]; then
          pn=$((pn+1)); rows+="| $grp | — | ❌ no results — the job died before its first gate (see its job log) | |"$'\n'
          continue
        fi
        while IFS=$'\t' read -r _ grp gate status rc secs lf; do
          pt=$((pt+1))
          case "$status" in
            passed)  icon="✅ passed"; pp=$((pp+1)) ;;
            skipped) icon="⊘ skipped"; ps=$((ps+1)); bad+=("$f"$'\t'"$ph"$'\t'"$grp"$'\t'"$gate"$'\t'"$status"$'\t'"$rc"$'\t'"$lf") ;;
            *)       icon="❌ failed (rc=$rc)"; pf=$((pf+1)); bad+=("$f"$'\t'"$ph"$'\t'"$grp"$'\t'"$gate"$'\t'"$status"$'\t'"$rc"$'\t'"$lf") ;;
          esac
          rows+="| $grp | \`$gate\` | $icon | $secs |"$'\n'
        done < "$f"
      done <<< "$plan"
      [ -n "$rows" ] || continue           # phase not selected
      [ "$pf" -eq 0 ] && [ "$ps" -eq 0 ] && [ "$pn" -eq 0 ] && icon="✅" || icon="❌"
      echo "### $icon $ph — $pt gates: $pp passed, $pf failed, $ps skipped$([ "$pn" -eq 0 ] || echo ", $pn group(s) with no results")"
      echo
      echo "| Group | Gate | Result | Seconds |"
      echo "|---|---|---|---:|"
      printf '%s' "$rows"
      echo
      tot=$((tot+pt)); p=$((p+pp)); fl=$((fl+pf)); sk=$((sk+ps)); nr=$((nr+pn))
    done
    echo "**$tot gates: $p passed, $fl failed, $sk skipped$([ "$nr" -eq 0 ] || echo "; $nr group(s) with no results").**"
    echo
    if [ "${#bad[@]}" -gt 0 ]; then
      echo "### Logs"
      echo
      local b n shown
      for b in "${bad[@]}"; do
        IFS=$'\t' read -r f ph grp gate status rc lf <<< "$b"
        lf="$(dirname "$f")/logs/$lf"
        n=0; [ -f "$lf" ] && n="$(wc -l < "$lf" | tr -d ' ')"
        [ "$n" -gt "$TAIL_LINES" ] && shown="last $TAIL_LINES of $n lines" || shown="$n lines"
        echo "<details><summary>$([ "$status" = skipped ] && echo ⊘ || echo ❌) <b>$ph / $grp</b> · <code>$gate</code> ($status, rc $rc) — $shown</summary>"
        echo
        echo "~~~~~~text"
        if [ "$n" -gt 0 ]; then tail -n "$TAIL_LINES" "$lf" | awk -v m="$MAX_LINE" '{ print (length($0) > m ? substr($0, 1, m) " …" : $0) }'
        else echo "(no output captured)"; fi
        echo "~~~~~~"
        echo
        echo "</details>"
        echo
      done
    fi
    echo "Full logs: **unit-tests.log** in the \`log-unit-tests\` artifact below — every gate's whole output, under"
    echo "phase / group headers; and one artifact per group (\`unit-<phase>-<group>\`), a file per gate under \`logs/\`."
  } | tee "$dir/summary.md"
}

# ONE log for the whole run: every planned phase › group › gate in manifest order, each gate's whole output under
# its own header, a status line per group and phase, the totals last. Written to <dir>/unit-tests.log.
cmd_combine(){
  local want="$1" dir="$2" sel="${3:-all}" ph grp gate status rc secs lf f line
  local phases=("$1") plan tot=0 p=0 fl=0 sk=0 nr=0
  [ "$want" = all ] && phases=("${LAUNCHPAD_UNIT_PHASES[@]}") || known_phase "$want"
  plan="$(planned "$want" "$sel")" || exit
  line="$(printf '%.0s=' {1..100})"
  {
    echo "unit-tests · phase $want · groups $sel${POC_SHA:+ · rafay_nvcm_poc @ $POC_SHA}"
    for ph in "${phases[@]}"; do
      grep -q "^$ph " <<< "$plan" || continue
      local pt=0 pp=0 pf=0 ps=0 pn=0
      printf '\n%s\n#### PHASE %s\n%s\n' "$line" "$ph" "$line"
      while read -r _ph grp; do
        [ "$_ph" = "$ph" ] || continue
        f="$dir/unit-$ph-$grp/results.tsv"
        printf '\n======== %s / %s ========\n' "$ph" "$grp"
        if [ ! -s "$f" ]; then
          pn=$((pn+1)); echo "NO RESULTS — the job died before its first gate (see the '$ph · $grp' job log)"
          continue
        fi
        local n=0 m gp=0 gf=0 gs=0
        m="$(wc -l < "$f" | tr -d ' ')"
        while IFS=$'\t' read -r _ _ gate status rc secs lf; do
          n=$((n+1))
          case "$status" in passed) gp=$((gp+1)) ;; skipped) gs=$((gs+1)) ;; *) gf=$((gf+1)) ;; esac
          printf '\n-------- [%s/%s %d/%d] %s — %s (rc %s, %ss) --------\n' "$ph" "$grp" "$n" "$m" "$gate" "$status" "$rc" "$secs"
          if [ -f "$dir/unit-$ph-$grp/logs/$lf" ]; then cat "$dir/unit-$ph-$grp/logs/$lf"; else echo "(no output captured)"; fi
        done < "$f"
        printf '\n======== %s / %s: %d gates — %d passed, %d failed, %d skipped ========\n' "$ph" "$grp" "$m" "$gp" "$gf" "$gs"
        pt=$((pt+m)); pp=$((pp+gp)); pf=$((pf+gf)); ps=$((ps+gs))
      done <<< "$plan"
      printf '\n#### PHASE %s: %d gates — %d passed, %d failed, %d skipped%s\n' "$ph" "$pt" "$pp" "$pf" "$ps" \
        "$([ "$pn" -eq 0 ] || echo ", $pn group(s) with no results")"
      tot=$((tot+pt)); p=$((p+pp)); fl=$((fl+pf)); sk=$((sk+ps)); nr=$((nr+pn))
    done
    printf '\n%s\nTOTAL: %d gates — %d passed, %d failed, %d skipped%s\n' "$line" "$tot" "$p" "$fl" "$sk" \
      "$([ "$nr" -eq 0 ] || echo ", $nr group(s) with no results")"
  } > "$dir/unit-tests.log"
  log "combine: $dir/unit-tests.log — $tot gates: $p passed, $fl failed, $sk skipped, $nr group(s) with no results"
}

sub="${1:-}"; shift || true
case "$sub" in
  groups)    [ $# -ge 1 ] || die "usage: groups <phase> [selection]";            cmd_groups "$@" ;;
  matrix)    [ $# -ge 1 ] || die "usage: matrix <phase|all> [selection]";        cmd_matrix "$@" ;;
  list)      [ $# -ge 1 ] || die "usage: list <phase> [group]";                  cmd_list "$@" ;;
  coverage)  [ $# -eq 1 ] || die "usage: coverage <poc_dir>";                    cmd_coverage "$@" ;;
  run)       [ $# -eq 4 ] || die "usage: run <phase> <group> <poc_dir> <out_dir>"; cmd_run "$@" ;;
  summarize) [ $# -ge 2 ] || die "usage: summarize <phase|all> <dir> [selection]"; cmd_summarize "$@" ;;
  combine)   [ $# -ge 2 ] || die "usage: combine <phase|all> <dir> [selection]";   cmd_combine "$@" ;;
  *) awk 'NR>2{ if(/^#/){sub(/^# ?/,"");print} else exit }' "$0"; exit 2 ;;
esac
