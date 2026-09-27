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
# usage: ab-compare.sh [-r REF] [-s "1 1.4 2"] [-d "eau wm"] [-o OUTDIR] [-k] [-S]
#   -r REF     reference revision (default origin/dev)
#   -s SCALES  GSScaleFactor values (default "1 1.4")
#   -d DECOS   window decorations: eau (Eau draws the titlebars) and/or wm
#              (the window manager does, as on the Gershwin desktop)
#              (default "eau wm")
#   -o OUTDIR  where screenshots and the report go (default ./ab-out)
#   -k         keep the reference worktree afterwards
#   -S         leave GBAutoSheets on (by default both sides run with it off,
#              so modal alerts stay comparable with pre-sheet references)
# Exit status: number of images that differ between A and B.

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
REF=origin/dev
SCALES="1 1.4"
DECOS="eau wm"
OUT="$PWD/ab-out"
KEEP=0
AUTOSHEETS=NO
while getopts r:s:d:o:kS opt; do
  case $opt in
    r) REF=$OPTARG ;;
    s) SCALES=$OPTARG ;;
    d) DECOS=$OPTARG ;;
    o) OUT=$OPTARG ;;
    k) KEEP=1 ;;
    S) AUTOSHEETS=YES ;;
    *) sed -n '11,21p' "$0"; exit 64 ;;
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
# deco eau: Eau draws the titlebars and libs-gui loads the bundle through
# GSAppKitUserBundles.  deco wm: the Gershwin desktop's setup - the window
# manager decorates (GSBackHandlesWindowDecorations YES, as in its
# NSGlobalDomain) and, with no GSAppKitUserBundles, the theme loads the
# bundle itself from a Library/Bundles directory (here the private HOME's),
# later than libs-gui would.
run()
{
  name=$1 tree=$2 scale=$3 quick=$4 deco=$5
  dir="$OUT/runs/$name"
  mkdir -p "$dir/home"
  if [ $deco = wm ]; then decorations=YES; else decorations=NO; fi
  set -- -GSTheme "$tree/Eau.theme" -GSBackHandlesWindowDecorations $decorations \
    -GSScaleFactor "$scale" -GBAutoSheets "$AUTOSHEETS"
  if [ -d "$tree/Behaviors/GershwinBehaviors.bundle" ]; then
    if [ $deco = wm ]; then
      mkdir -p "$dir/home/Library/Bundles"
      ln -s "$tree/Behaviors/GershwinBehaviors.bundle" "$dir/home/Library/Bundles/"
    else
      set -- "$@" -GSAppKitUserBundles "(\"$tree/Behaviors/GershwinBehaviors.bundle\")"
    fi
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
  for deco in $DECOS; do
    for mode in full quick; do
      q=0; [ $mode = quick ] && q=1
      run "A_${deco}_${mode}_s$s" "$WORK/A" "$s" $q $deco
      run "A2_${deco}_${mode}_s$s" "$WORK/A" "$s" $q $deco
      run "B_${deco}_${mode}_s$s" "$REPO" "$s" $q $deco
    done
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
  echo "A = \`$REF\` ($(git -C "$WORK/A" rev-parse --short HEAD)), B = working tree ($(git -C "$REPO" rev-parse --short HEAD)$(git -C "$REPO" diff --quiet || echo ', modified')). Scales: $SCALES. Decorations: $DECOS."
  echo
  echo "| deco | mode | scale | image | A vs A (noise) | A vs B |"
  echo "|---|---|---|---|---|---|"
} > "$REPORT"

deviations=0
noisy=0
for s in $SCALES; do
  for deco in $DECOS; do
    for mode in full quick; do
      r="${deco}_${mode}_s$s"
      A="$OUT/runs/A_$r" A2="$OUT/runs/A2_$r" B="$OUT/runs/B_$r"
      for f in "$A"/*.png; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .png)
        d="$OUT/diff/${r}_$n"
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
        echo "| $deco | $mode | $s | $n | $noise | $diff |" >> "$REPORT"
      done
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
