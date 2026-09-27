# ABScreenshots - pixel A/B test for Eau

Compares how the theme renders at a reference revision (A) and in this
working tree (B), pixel for pixel, at any GSScaleFactor.

    ./ab-compare.sh                      # A = origin/dev, scales 1 and 1.4
    ./ab-compare.sh -r main -s "1 1.4 2" -o /tmp/ab
    ./ab-compare.sh -d wm -s 1.25        # only the desktop's decoration mode

It builds A in a temporary git worktree, builds B and the harness, then runs
`abharness` under Xvfb (1600x1200, 96 dpi) once per side, scale, decoration
mode and capture mode, serially. Each run loads that side's `Eau.theme` and,
when the revision has one, its `Behaviors/GershwinBehaviors.bundle`. The
report is `<out>/RESULTS.md`, with an A | B | diff image in `<out>/diff/` for
every deviation. The exit status is the number of images that differ.

## Decoration modes (`-d`, default both)

- `eau` - `-GSBackHandlesWindowDecorations NO`: Eau draws the titlebars, and
  libs-gui loads the behaviors bundle through `GSAppKitUserBundles`.
- `wm` - the Gershwin desktop's setup: `-GSBackHandlesWindowDecorations YES`
  (the window manager decorates; Xvfb has none, so windows are captured
  without titlebars) and no `GSAppKitUserBundles`, so Eau loads the bundle
  itself from `Library/Bundles` of the run's private HOME, later in start-up
  than libs-gui would. Window frames, content sizes at fractional scales and
  the start-up order all differ from `eau`, so a mode can deviate alone.

Needs: the GNUstep stack at `/System`, `xvfb-run`, ImageMagick (`import`,
`compare`, `convert`, `montage`), `libX11` and `libXtst` at run time.

## What is captured

About 40 screenshots per run (whole screen plus per-window crops): the
classic EauTest window and Tab focus, the menu bar, a dropdown, a submenu, a
90-item overflow menu before and after scrolling, all showcase sections, the
drawer, NSAlert (modal and as a sheet), a save panel as a sheet,
NSRunAlertPanel, NSOpenPanel and NSSavePanel. The `quick` mode skips every
mouse action so the Tab focus ring stays visible on the panels and sheets.

## Determinism

The harness, identically for both sides, quantizes
`+[NSDate timeIntervalSinceReferenceDate]` to 3 s steps (freezing the default
button pulse and progress animations), stops the caret blink, resets
spinners, fixes the date picker's date and fully redraws and syncs every
window before each capture. A is run twice: A vs A must be 0 everywhere, or
the A vs B numbers mean nothing.

## Expected differences

Against a reference without window-modal sheets (anything before the
GershwinBehaviors split), the sheet captures (`22*`, `23*`) differ by design:
the sheet is attached under its parent's titlebar and has no titlebar of its
own. Compare only the sheet interiors there.

## Files

- `abmain.m` - the scripted capture run, wrapped around the EauTest fixture
  (`../EauTest_main.m` and friends)
- `abinput.c` - pointer, click and key input for the harness (XWarpPointer,
  because XTest motion is a no-op on Xvfb)
- `ab-compare.sh` - build, run and compare
