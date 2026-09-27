#!/bin/sh
# ab-compare.sh - pixel A/B test of Eau against a reference revision
#
# SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
#
# A = a git ref (default origin/dev) built in a temporary worktree,
# B = this working tree.  Both are driven by the same abharness binary under
# Xvfb at every requested GSScaleFactor, twice for A so harness noise shows
# up as A-vs-A differences.  See README.md.
#
# usage: ab-compare.sh [-r REF] [-s "1 1.4 2"] [-o OUTDIR] [-k] [-S]
#   -r REF     reference revision (default origin/dev)
#   -s SCALES  GSScaleFactor values (default "1 1.4")
#   -o OUTDIR  where screenshots and the report go (default ./ab-out)
#   -k         keep the reference worktree afterwards
#   -S         leave GBAutoSheets on (by default both sides run with it off,
#              so modal alerts stay comparable with pre-sheet references)
# Exit status: number of images that differ between A and B.

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
REF=origin/dev
SCALES="1 1.4"
OUT="$PWD/ab-out"
KEEP=0
AUTOSHEETS=NO
while getopts r:s:o:kS opt; do
  case $opt in
    r) REF=$OPTARG ;;
    s) SCALES=$OPTARG ;;
    o) OUT=$OPTARG ;;
    k) KEEP=1 ;;
    S) AUTOSHEETS=YES ;;
    *) sed -n '11,18p' "$0"; exit 64 ;;
  esac
done
case $OUT in /*) ;; *) OUT="$PWD/$OUT" ;; esac

for tool in xvfb-run import compare convert montage git gmake; do
  command -v $tool >/dev/null 2>&1 || { echo "ab-compare: $tool is required" >&2; exit 69; }
done
# shellcheck disable=SC1091
. /System/Library/Makefiles/GNUstep.sh
export LD_LIBRARY_PATH="/System/Library/Libraries${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
# Only now: GNUstep.sh reads unset variables.
set -u

rm -rf "$OUT"
mkdir -p "$OUT/runs" "$OUT/diff" "$OUT/cache"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ab-compare.XXXXXX")
cleanup()
{
  if [ $KEEP -eq 0 ]; then
    git -C "$REPO" worktree remove --force "$WORK/A" 2>/dev/null
    rm -rf "$WORK"
  else
    echo "reference worktree kept at $WORK/A"
  fi
}
trap cleanup EXIT

build()
{
  echo "building $1"
  (cd "$1" && gmake > "$OUT/build-$2.log" 2>&1) || { echo "build of $2 failed, see $OUT/build-$2.log" >&2; exit 70; }
}

git -C "$REPO" worktree add --detach "$WORK/A" "$REF" > /dev/null 2>&1 \
  || { echo "cannot check out $REF" >&2; exit 65; }
build "$WORK/A" A
build "$REPO" B
build "$HERE" harness

# One run: theme and behaviors bundle (if the revision has one) of tree $2.
run()
{
  name=$1 tree=$2 scale=$3 quick=$4
  dir="$OUT/runs/$name"
  mkdir -p "$dir/home"
  set -- -GSTheme "$tree/Eau.theme" -GSBackHandlesWindowDecorations NO -GSScaleFactor "$scale" \
    -GBAutoSheets "$AUTOSHEETS"
  if [ -d "$tree/Behaviors/GershwinBehaviors.bundle" ]; then
    set -- "$@" -GSAppKitUserBundles "(\"$tree/Behaviors/GershwinBehaviors.bundle\")"
  fi
  # A private HOME keeps the user's defaults out; C locale and UTC keep text
  # and dates identical between runs.
  if [ "$quick" = 1 ]; then export AB_QUICK=1; else unset AB_QUICK; fi
  AB_OUT="$dir" HOME="$dir/home" XDG_CACHE_HOME="$OUT/cache" LANG=C LC_ALL=C TZ=UTC \
    timeout -s KILL 400 xvfb-run -a -s "-screen 0 1600x1200x24 -dpi 96" \
    "$HERE/abharness.app/abharness" "$@" > "$dir/log.txt" 2>&1
  echo "  $name: $(ls "$dir"/*.png 2>/dev/null | wc -l) screenshots"
}

# Runs are serial: two GNUstep apps on separate Xvfb displays stall each other.
for s in $SCALES; do
  for mode in full quick; do
    q=0; [ $mode = quick ] && q=1
    run "A_${mode}_s$s" "$WORK/A" "$s" $q
    run "A2_${mode}_s$s" "$WORK/A" "$s" $q
    run "B_${mode}_s$s" "$REPO" "$s" $q
  done
done

# Differing pixels between two screenshots, or "missing".
ae()
{
  [ -f "$1" ] && [ -f "$2" ] || { echo missing; return; }
  compare -metric AE "$1" "$2" "$3" 2>&1 >/dev/null
}

REPORT="$OUT/RESULTS.md"
{
  echo "# Eau A/B pixel test"
  echo
  echo "A = \`$REF\` ($(git -C "$WORK/A" rev-parse --short HEAD)), B = working tree ($(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet || echo ', modified')). Scales: $SCALES."
  echo
  echo "| mode | scale | image | A vs A (noise) | A vs B |"
  echo "|---|---|---|---|---|"
} > "$REPORT"

deviations=0
noisy=0
for s in $SCALES; do
  for mode in full quick; do
    A="$OUT/runs/A_${mode}_s$s" A2="$OUT/runs/A2_${mode}_s$s" B="$OUT/runs/B_${mode}_s$s"
    for f in "$A"/*.png; do
      [ -f "$f" ] || continue
      n=$(basename "$f" .png)
      d="$OUT/diff/${mode}_s${s}_$n"
      noise=$(ae "$f" "$A2/$n.png" /dev/null)
      diff=$(ae "$f" "$B/$n.png" "$d-diff.png")
      if [ "$diff" = 0 ]; then
        rm -f "$d-diff.png"
      else
        deviations=$((deviations + 1))
        [ -f "$B/$n.png" ] && montage -label A "$f" -label B "$B/$n.png" -label diff "$d-diff.png" \
          -tile 3x1 -geometry +4+4 "$d-AB.png" 2>/dev/null && rm -f "$d-diff.png"
      fi
      [ "$noise" = 0 ] || noisy=$((noisy + 1))
      echo "| $mode | $s | $n | $noise | $diff |" >> "$REPORT"
    done
  done
done
{
  echo
  echo "$deviations image(s) differ between A and B; $noisy image(s) differ between two runs of A (harness noise)."
  echo "Side-by-side A | B | diff images for every deviation are in \`diff/\`."
} >> "$REPORT"

echo
tail -2 "$REPORT" | head -1
echo "report: $REPORT"
[ $noisy -eq 0 ] || echo "warning: A differs from itself - results are not trustworthy until that is 0" >&2
exit $deviations
