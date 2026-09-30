# Rendered macOS reference captures

These are current macOS app-client captures for the Windows port to be compared
against. They are **one side of a comparison, not a parity result**. Nothing here
claims that Windows matches macOS, and pixel-identical rendering across
platforms is neither expected nor the goal. The ledger rows they are meant to
serve are *Dark visual language, Font rendering quality, Line/shape
anti-aliasing, Color palette fidelity, Edge presentation, Node creation sheet,*
and *Canvas context menu* in
[`investigation/ui-parity-matrix.md`](../../ui-parity-matrix.md). Their status
columns are not changed by this directory.

The Windows counterpart and the standard this directory follows is
[`../rendered-windows/README.md`](../rendered-windows/README.md). That standard
is: app client area only, lossless PNG, originals byte-identical (no crop,
rescale, re-encoding or retouching), and no colour tolerance.

## Before you compare: scale and colour space

- **Backing scale factor is 1.0 for every capture.** They were taken on an
  external 1920 x 1080 display running at 1x, so one PNG pixel is one point.
  No capture was rescaled. The Windows captures are 96 DPI at 1x. No 2x (Retina)
  set was taken; see [Not done](#not-done).
- **Every PNG is tagged sRGB**: an `sRGB` chunk with rendering intent 0
  (perceptual) and no `iCCP`, `gAMA` or `cHRM` chunk. None is tagged Display P3.
  During capture, the display's ColorSync profile was temporarily set to the
  system `sRGB IEC61966-2.1` profile. ScreenCaptureKit was also asked for an
  sRGB output (`colorSpaceName = kCGColorSpaceSRGB`). The factory display
  profile was restored afterwards.
- `replay.py` reads the stored 8-bit samples exactly as written, with **no
  colour management**. Every value below is that raw sRGB-tagged triple.
- Every PNG is RGBA. The rounded window corners are transparent (alpha 0), and
  every sample rectangle lies in the opaque client.

## Build identity

| Item | Value |
| --- | --- |
| Source commit | `b0af051fe28a890bc9ebf3c6bd97fffaba51cc3b` (clean worktree) |
| Source tree | `9d556f40680a8dba4fade33c4ca787f66ac716d2` |
| Submodules | ghostty `30e1f3bb8c3d2949e9ae4aefc1c2b76142569cfb`, zmx `929263d83d12432da497d7370ebb30b579754428` |
| Host | macOS 26.7 (25G229), Xcode 26.5 (17F42), SDK macosx26.5 |
| Configuration | Debug, scheme `graphcode`, `platform=macOS` |
| Bundle | `local.graphcode.macref.app`, "GraphCode (macref)", 0.1.77 (301) |
| App executable SHA-256 | `2901ec06728922a3d18931d347f539d1dc6a063d348f89ecbd526180811c291c` (`Contents/MacOS/graphcode`, 58,720 bytes) |
| Debug dylib SHA-256 | `704fec5793dfa34359417bfcbc4987f9e99b8084af0b54dae2a352dac1b86eec` (`graphcode.debug.dylib`, 58,295,248 bytes) |
| Bundle manifest SHA-256 | `950d3509a24dba7a59eef3b1b9a47b46bf488c2a307e7fd5d898f34ba4f89c80` |

The bundle manifest hash is taken over the sorted `shasum -a 256` lines for the
22 files in `graphcode.app`, excluding `_CodeSignature`. The other binaries
(GraphcodeKit, MailroomKit, `graphcoded`, the CLI, `__preview.dylib`) are
hashed in [`evidence.json`](evidence.json).

The bundle identity came from the Makefile's `dev-*` override variables
(`TUIST_BUNDLE_ID_PREFIX` and `TUIST_APP_DISPLAY_NAME`). They let the capture run
beside an installed GraphCode without touching it or its daemon. **No source
file was changed.** The debug build is a Tuist `Debug` product: the frameworks
load from the build products directory and are not embedded, which is why the
executable is small and the debug dylib carries the code.

## Captures

The capture API was ScreenCaptureKit (`SCScreenshotManager.captureImage`),
using [`tools/gcr.swift`](tools/gcr.swift) `sckapp`:

- **Filter:** a display capture limited to the app's own on-screen windows, so
  context-menu and sheet windows are included and the desktop and every other
  app are not.
- **Region:** `sourceRect` is the window frame, and output size is points × 1.
- **Settings:** captured with `topInset` 32 and `solo`, so its 32-point title
  bar (separator at row 31) is excluded.
- **Main window:** it uses a hidden title bar, so the traffic lights and
  toolbar are inside its client. Nothing sits outside it.
- **Output:** written straight out with `CGImageDestination`. No
  post-processing.

| File | Pixels | Bytes | SHA-256 |
| --- | --- | --- | --- |
| [macos-canvas-sidebar.png](macos-canvas-sidebar.png) | 1264 x 761 | 136,277 | `20146d973d56e6b06a451077a7e59f97781b229ddcb17de43adaf005b8bcf8ee` |
| [macos-context-menu-canvas-background.png](macos-context-menu-canvas-background.png) | 1264 x 761 | 149,464 | `05be8c073bb1ac15c7c049bb73f2febfde7b0a393b6874d9a49bc4f3281c3286` |
| [macos-context-menu-node.png](macos-context-menu-node.png) | 1264 x 761 | 154,975 | `c0113b591d5b32bbf3c1d2578867d6f0c07892cf3a618aa3c708d6cd30363f85` |
| [macos-context-menu-edge.png](macos-context-menu-edge.png) | 1264 x 761 | 140,597 | `6dcfdda68954ffc383bd236d92dbca4b1fe9be058f14049fab4af6613eb4c590` |
| [macos-node-creation-sheet-main.png](macos-node-creation-sheet-main.png) | 1264 x 761 | 159,110 | `d2d81934dcff5a231e9782bba4625e47239acfd9e3f1e070b7c5c38d8f73fc01` |
| [macos-node-creation-sheet-goal-top.png](macos-node-creation-sheet-goal-top.png) | 1264 x 761 | 162,327 | `303d8873e0a1417f3f5f5932600233263ee2ce67e0dd3484b8539e85f6ac989d` |
| [macos-node-creation-sheet-goal-scrolled.png](macos-node-creation-sheet-goal-scrolled.png) | 1264 x 761 | 161,732 | `ccbbb1dd0dab29a1e6d53ce0e9ed8a95557d749ab09af21a3024d508d77b9106` |
| [macos-workspace-single-pane-disconnected.png](macos-workspace-single-pane-disconnected.png) | 1264 x 761 | 285,288 | `6017de38c6f99319267e7f1836683d3defb1024de21d36a0f22d32dffd835aed` |
| [macos-workspace-focus-terminal.png](macos-workspace-focus-terminal.png) | 1264 x 761 | 302,738 | `07981c553dfd6c55c515322c14e79fffa4441b16b1af638340cfaf948e6a841f` |
| [macos-settings-1.png](macos-settings-1.png) | 900 x 998 | 144,033 | `6627c33aecf5f93a47909a2a3b331e87893787295a00ed816f86baa1a7ba65fe` |
| [macos-settings-2.png](macos-settings-2.png) | 900 x 998 | 183,306 | `d5b7a2691f40ca232cc1aea4189de37d431446406ad586eb4bd3ccfe3f1b89a5` |
| [macos-settings-3.png](macos-settings-3.png) | 900 x 998 | 149,031 | `8d8778340c6b9473a94e8cf4aeb365f371951bbf3642a4a89857e537e1561237` |
| [rejected-settings-light-appearance.png](rejected-settings-light-appearance.png) | 900 x 450 | 50,455 | `eab962d6eb4f54426549db5a79b97f4bff43d72cf425e74c36ddd74e221695b7` |

The last file is **rejected and is not a reference**. It is kept as the failing
observation described under [Appearance](#appearance). The twelve reference
PNGs total 2,128,878 bytes.

What each capture shows:

1. **Canvas and sidebar.** The `ReferenceProject` graph at zoom 100% with three
   loops:
   - A (Goal), B (Composite) and C (Goal).
   - A straight A→B handoff edge.
   - A curved, guarded C→A back-edge labelled `retry ×1`.

   The sidebar shows the project row selected, and each loop row shows its type
   stripe, title, elapsed value and state indicator.
2. **Context menus**, each opened by right-click:
   - **Empty canvas:** `Worktrees…`, `Project Settings…`, `Open in Finder`,
     `Export All Loops…`, `Import Loops…`.
   - **Node A:** `Open Terminal`, `Rename…`, `Save as Template…`,
     `Export Loop…`, `Import Loops Here…`, `Delete Loop…`. The node's connector
     `+` hover affordance is also visible.
   - **A→B edge:** a disabled `Handoff · Always` heading and `Delete Edge`.
3. **Node creation sheet** (New Node), in three states:
   - **`main`:** the default Main kind, with its full wording and the enabled
     blue `Start` button.
   - **`goal-top`:** Goal selected and a done condition typed. It shows the
     validation reason `Say what done looks like to continue` beside a disabled
     `Create loop`.
   - **`goal-scrolled`:** the same state scrolled to the recap.

   The sheet window is 520 x 721 points at client (372, 52). Its bottom 12
   points fall outside the main window's client, so they are not in the capture.
4. **Workspace.**
   - **`single-pane-disconnected`:** node A's agent pane after the daemon wait
     timed out.
   - **`focus-terminal`:** the same workspace split with a plain shell pane,
     which is focused and holds the terminal glyph test text.
5. **Product Settings.** This is the macOS app's `Settings` scene (window title
   "GraphCode (macref) Settings", opened with ⌘,). It is the macOS counterpart
   of Windows *Product Settings*. The window was resized to 900 x 1030 points
   and captured at its top, middle and bottom scroll positions.

## Capture state

### Display and colour

- **Display:** an external 1920 x 1080 display at backing scale 1.0.
  The laptop's built-in 2x display was not used.
- **Colour profile:** the display's ColorSync custom profile was set to
  `/System/Library/ColorSync/Profiles/sRGB Profile.icc` for the captures, then
  restored to the factory profile.
  - Before the change, ScreenCaptureKit and `screencapture` output were tagged
    with the monitor's own ICC profile, and their pixels differed. For example,
    the canvas background read `(12,15,14)` instead of `(10,12,11)`.
  - After the change, display-native, ScreenCaptureKit-sRGB and
    `screencapture -l` output were RGB-identical in a session check. That is
    consistent with no colour conversion being applied between the app's
    composited pixels and the PNG. The check images are not bundled.

### Appearance

- **System appearance was Dark for every reference capture.** The host was in
  Light appearance. It was switched to Dark only for the capture and switched
  back afterwards.
- **Why the system had to change:** the app was launched with the
  `-AppleInterfaceStyle Dark` argument-domain override. That was not enough.
  - The main window forces Dark itself (`.preferredColorScheme(.dark)` in
    `AppView.swift`).
  - The `Settings` scene does not, so it rendered Light under a Light system
    even with the override.
  - The measured result is `rejected-settings-light-appearance.png`: rect
    `[0,40,90,400]` has 35,985 of 36,000 pixels opaque `RGB(255,255,255)`.
  - Under the system Dark switch, the same Settings background rect
    `[0,10,90,390]` on all three reference pages measures 35,100 of 35,100
    pixels `RGB(35,41,43)`.
- **Accent and highlight:** `controlAccentColor` resolved to sRGB
  `(0.0, 0.4784, 1.0)`. `AppleAccentColor` and `AppleHighlightColor` are unset,
  which is the system default.
- **Wallpaper tinting:** `AppleReduceDesktopTinting` is unset, so wallpaper
  tinting in windows is **on** (the default). The Settings window's
  `RGB(35,41,43)` background is observed to carry a cool tint. It was not
  measured against another wallpaper.
- **Accessibility display options:** Increase contrast, Reduce transparency,
  Reduce motion, Differentiate without colour and Invert colours were all
  **off**.
- **Font smoothing:** `AppleFontSmoothing` is unset in both the global and
  current-host domains, which is the system default.

### Terminal

- **Font size:** 11.7 pt, which is 11.7 px at 1x. That is Ghostty's default
  13 pt multiplied by GraphCode's default terminal scale of 0.9
  (`TerminalFontZoom`), with no zoom stored.
- **Font family:** Ghostty's default embedded JetBrains Mono.
- **Configuration:** the user Ghostty config file was empty.

Both the size and the family are **derived from source and configuration,
not measured** from glyph metrics.

The focused shell pane printed this text with `printf` after the prompt was
reduced to `$ `:

```text
The quick brown fox jumps over the lazy dog.
THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 0123456789
{}[]()<>=+-*/\|~`!@#$%^&_;:,.?"'
Il1| O0o rn m ww WW @@ ##
→ ← ✓ ✗ · … × ─│┌┐└┘
Bold Italic red green yellow blue magenta cyan
```

In the last line, `Bold` is SGR 1, `Italic` is SGR 3, and each colour name is
printed in its ANSI 31–36 foreground colour.

The left (agent) pane shows the host shell's `Last login` line, two oh-my-zsh
update lines, and the prompt-reset command. They are left exactly as captured.

### Fixture and daemon

- **Scratch state:** the app ran with `GRAPHCODE_SUPPORT_DIR` pointed at a
  scratch directory.
- **Graph setup:** the graph was created against a temporary foreground
  `graphcoded` from the same build, using that same directory.
- **Disconnect:** the daemon was stopped before any capture, and no
  `graphcoded` was running while the captures were taken. The app kept showing
  its last graph.
- **Missing CLIs:** the `pi` and `claude` CLIs are not installed on the capture
  host, so loops show `pi is not on your PATH` and `Stopped` / `Idle`.

## How this differs from the Windows capture state

The Windows set used a two-card synthetic graph at zoom 1, a deliberately
disconnected daemon, and a live zmx-attached workspace. The macOS state
matches it where macOS allows and differs here:

- **Graph:** three loops instead of two cards. The third loop exists to give a
  curved, labelled edge for anti-aliasing and edge presentation.
- **Disconnect method:**
  - Windows forced the disconnect with an automation hook.
  - macOS has no equivalent hook, so the daemon process was simply not running.
  - The macOS canvas shows **no visible disconnected indicator**, so nothing in
    the canvas pixels proves the disconnect. It is a statement about process
    state.
- **Workspace terminal:**
  - Windows had a live zmx attach.
  - On macOS the agent pane's `open` dial waited for the daemon, then printed
    that the session `never became ready to attach` and `Process exited`.
  - The glyph text is therefore in a local shell split pane, not in an agent
    session.
- **Focus treatment is structurally different.** macOS draws no 2-pixel focus
  strip. Its focus treatment is a 5-point dot, a tinted pane header and a
  1-point focus ring. The Windows region `[500,130,64,2]` therefore has no
  macOS equivalent, and the values measured there are recorded only so that the
  comparison is explicit.
- **Context menus and sheet:**
  - The context menus are native translucent menu windows, so their body pixels
    are a blurred material, not a flat token colour.
  - The node creation sheet is a separate window and is clipped at the client
    bottom.
- **Settings:** Settings is a separate window with its own title bar. It was
  captured client-only and at a different size (900 x 998) from the main window.

## Measured

Everything in this section is recomputed by `replay.py` from the committed PNG
bytes: [`evidence.json`](evidence.json) holds 67 sample rectangles across the
13 files. A rectangle is client-relative `[x, y, width, height]` in PNG pixels,
which at scale 1.0 are also points. `n/total` counts pixels exactly equal to
the opaque colour. There is no tolerance.

### Workspace focus: the counterpart to Windows `[500,130,64,2]`

These are measured in `macos-workspace-focus-terminal.png`, where the right-hand
shell pane is focused.

| Rect | What | Result |
| --- | --- | --- |
| `[500,130,64,2]` | the Windows focus-strip rectangle, applied unchanged | **0/128** `RGB(10,132,255)`. The pixels are the tab bar: 66 `RGB(31,31,32)`, 24 `RGB(31,32,32)`, 8 distinct colours. |
| `[766,145,3,3]` | focus dot core | **9/9 `RGB(10,132,255)`** |
| `[764,143,7,7]` | focus dot with its anti-aliased edge | 9/49 `RGB(10,132,255)`, 12 distinct colours |
| `[900,136,300,19]` | focused pane header tint | 4348/5700 `RGB(32,46,59)`, 7 distinct |
| `[320,136,300,19]` | unfocused pane header | 4437/5700 `RGB(42,43,44)`, 4 distinct |
| `[800,156,400,1]` | focused header bottom row | 317/400 `RGB(29,58,86)` |
| `[756,300,1,400]` | pane divider column | 400/400 `RGB(62,80,98)` |
| `[757,300,1,400]` | focus ring, left edge | 400/400 `RGB(14,33,50)` |
| `[1263,300,1,400]` | focus ring, right edge | 400/400 `RGB(14,33,50)` |
| `[800,760,400,1]` | focus ring, bottom edge | 399/400 `RGB(14,33,50)`; 1 `RGB(13,33,50)` |

The macOS focus colour closest to the Windows sample is the dot core above:
`RGB(10,132,255)`, the same numeric triple as `Theme.paneFocusTint` `#0A84FF`,
in a 3 x 3 rectangle.

In the single-pane capture, the dot core `[257,145,3,3]` is **0/9**
`RGB(10,132,255)`. It reads 3 each of `(10,124,238)`, `(10,124,239)` and
`(10,125,240)`. So the dot does not render as the token value in every state.
This is measured but not explained.

### Canvas, sidebar and edges

These are measured in `macos-canvas-sidebar.png`.

| Rect | What | Result |
| --- | --- | --- |
| `[292,117,47,47]` | open canvas grid cell | 2209/2209 `RGB(10,12,11)` |
| `[291,117,1,47]` | vertical grid line | 47/47 `RGB(21,24,22)` |
| `[292,116,47,1]` | horizontal grid line | 47/47 `RGB(21,24,22)` |
| `[580,453,47,47]` | open cell inside the project container | 2209/2209 `RGB(15,17,16)` |
| `[20,300,200,400]` | sidebar panel | 80000/80000 `RGB(19,21,20)` |
| `[170,162,60,22]` | selected project row | 1320/1320 `RGB(0,89,209)` |
| `[38,194,8,24]` | sidebar type stripe, loop A (Goal) | 34 `RGB(25,158,112)`, 6 distinct colours |
| `[54,226,8,24]` | sidebar type stripe, loop B (Composite) | 34 `RGB(144,133,233)`, 6 distinct colours |
| `[546,360,12,1]` | card A type stripe row | 2 `RGB(25,158,112)`, 9 distinct colours |
| `[560,322,118,16]` | card A title glyphs `ReferenceLoopA` | 298 `RGB(244,244,244)`, **341 distinct**, max channel spread 6 |
| `[48,198,100,16]` | sidebar title glyphs `ReferenceLoopA` | **187 distinct**, max channel spread 2 |
| `[720,340,70,8]` | card A body | 20 distinct; the top colour is `RGB(41,41,45)` (145 pixels) |
| `[815,356,1,11]` | straight A→B edge, one column | **2** `RGB(93,96,95)` (rows 360–361) over 8 `RGB(16,20,18)` |
| `[803,356,34,11]` | straight A→B edge band | 121 distinct |
| `[810,442,28,36]` | curved C→A edge segment | **140 distinct**, max channel spread 130 |
| `[793,422,46,22]` | edge label `retry ×1`, which the curve crosses | **232 distinct** |
| `[1156,727,34,14]` | zoom label `100%` | 111 distinct |

The distinct-colour counts are **observations, not quality thresholds**, just as
on the Windows side: extra colours can come from fills, decoration or dithering,
not only from anti-aliasing.

### Terminal glyphs

These are measured in `macos-workspace-focus-terminal.png`. Text rows are
15 pixels apart.

| Rect | What | Result |
| --- | --- | --- |
| `[900,400,300,300]` | focused terminal background | 77902 `RGB(15,17,16)` + 11583 `RGB(15,17,17)` + 1 other |
| `[300,400,300,300]` | unfocused terminal background | 79766 `RGB(20,22,21)` + 10234 `RGB(20,22,22)` |
| `[759,158,310,15]` | lowercase pangram | 251 distinct, **max channel spread 3** |
| `[759,173,380,15]` | uppercase pangram and digits | 273 distinct, max channel spread 3 |
| `[759,188,225,15]` | ASCII symbols | 251 distinct, max channel spread 3 |
| `[759,203,180,15]` | confusables `Il1| O0o rn m ww WW @@ ##` | 221 distinct, max channel spread 3 |
| `[759,218,140,15]` | arrows, marks and box drawing | 108 distinct, max channel spread 3 |
| `[759,233,325,15]` | bold, italic and ANSI colours | 704 distinct, max channel spread 124 (coloured text) |

- **Two-value backgrounds:** each terminal background is two adjacent values,
  not one flat colour.
- **Grey glyph edges:** in the five white-on-dark lines, no pixel's R, G and B
  differ by more than 3. So the glyph edges sampled here are grey (greyscale
  anti-aliasing) with no chromatic subpixel fringes. This says nothing about
  glyph shape, hinting or metrics.

### Node creation sheet, menus and Settings

| Capture | Rect | What | Result |
| --- | --- | --- | --- |
| sheet `main` | `[420,630,400,80]` | sheet background | 32000/32000 `RGB(42,42,46)` |
| sheet `main` | `[797,723,73,32]` | `Start` button | 1953/2336 `RGB(10,132,255)` |
| sheet `goal-top` | `[756,724,114,30]` | disabled `Create loop` | 2832/3420 `RGB(37,55,75)` |
| sheet `goal-top` | `[560,236,60,8]` | selected Goal option body | 480/480 `RGB(40,56,54)` |
| all sheets | `[20,300,200,400]` | sidebar dimmed behind the sheet | 80000/80000 `RGB(21,22,22)` |
| all sheets | `[1150,200,80,80]` | canvas dimmed behind the sheet | 6084 `RGB(17,18,19)` + 316 `RGB(22,23,23)` |
| empty-canvas menu | `[304,127,136,134]` | menu body | 487 distinct; the top colour is `RGB(22,23,23)` (4805 pixels) |
| node menu | `[604,378,152,168]` | menu body | 840 distinct; the top colour is `RGB(22,24,23)` (4770 pixels) |
| edge menu | `[834,358,128,52]` | menu body | 433 distinct; the top colour is `RGB(39,39,41)` (1978 pixels) |
| each menu | `[292,117,47,47]` or `[580,117,47,47]` | open canvas cell outside the menu | 2209/2209 `RGB(10,12,11)` |
| Settings 1, 2 and 3 | `[0,10,90,390]` | Settings background | 35100/35100 `RGB(35,41,43)` |
| Settings 1 | `[300,52,300,34]` | empty part of a settings card | 10200/10200 `RGB(42,47,49)` |

## Observed, not measured

These were seen, but either no pixel rule checks them or they were checked only
during the session.

- **Wording in the menus and sheet** was read visually: the item lists above,
  the sheet's kind descriptions, `Say what done looks like to continue`,
  `Templates ⌘T`, and the other sheet text. The text is legible at 1x, but no
  OCR or accessibility tree was recorded.
- **Glyph appearance** in the terminal (for example, `<>` appears to render as
  a ligature) and on cards and sidebar rows.
- **Edge geometry:**
  - the curve's path, its connection dots `(820,361)` and `(820,421)`;
  - that the straight edge is drawn 2 pixels thick at 1x from a 1.5-point
    source line width (`CanvasEdgeViews.swift`);
  - the warm label colour.
- **Backdrop independence** (session check; the comparison images are not
  bundled). Recapturing the canvas, workspace and Settings over a solid black
  window placed behind the app changed only live elapsed-time glyphs:
  - 416 pixels on the canvas and 405 on the workspace;
  - 0 on Settings.

  So what sits behind the window does not show through the sampled regions.
- **An earlier pass under system Light** captured the menus, the sheet and the
  workspace before the system appearance was switched. It was discarded
  because Settings rendered Light. Only the rejected Settings image from that
  pass is bundled.

## Findings

These are reported here only; none were fixed in this change.

1. **Settings ignores the app-scoped Dark override.**
   - The main window forces Dark.
   - The `Settings` window follows the system appearance instead, and
     `-AppleInterfaceStyle Dark` in the argument domain did not change that.
   - A user in Light mode therefore gets a light Settings window beside a dark
     main window. The evidence is `rejected-settings-light-appearance.png`.
2. **The dial log ignores `GRAPHCODE_SUPPORT_DIR`.**
   - The workspace's `open` dial appends to `$HOME/.graphcode/dials.log`
     regardless of `GRAPHCODE_SUPPORT_DIR`; the path is hard-coded in
     `GraphcodeKit/Sources/Domain/DialLog.swift`.
   - An otherwise isolated scratch instance therefore wrote dial lines into the
     host user's real log. Other writes outside the scratch directory were not
     audited.
3. **With the daemon down, a workspace agent pane waits and then exits.**
   - It runs the `await-daemon` dial for about 60 seconds.
   - It then prints that the session `never became ready to attach`, followed
     by `Process exited. Press any key to close the terminal.`
   - Split shell panes still work without the daemon.
4. **The canvas has no disconnected indicator.** No indicator of the lost
   daemon was visible on the canvas or in the sidebar in any capture. A
   before-and-after comparison was not made.
5. **The split layout was not restored.** A split made in the workspace was not
   restored after navigating to the graph and back: the workspace reopened as a
   single pane. This was observed once and not investigated.
6. **The canvas re-centred once** by about 50 points after an earlier,
   discarded workspace visit. It did not move between the bundled captures.
   Comparing the graph area of the canvas capture with the two menu captures
   finds differences only inside the open menu and in the elapsed-time text.
7. **Nested Rename was not exercised.** This fixture has no loop nested inside a
   composite, so the earlier nested `Rename…` no-dialog finding
   (`investigation/macos-parity-evidence/`) was neither reproduced nor
   disproved. Only the root node's `Rename…` item was seen in a menu, and it
   was not invoked.

## Not done

- **No 2x (Retina) capture.** All captures are 1x. A 2x set would need its own
  scale record and must not be downsampled to compare.
- **No Display P3 capture.** Everything is sRGB.
- **No capture under system Light** for reference, and no capture with another
  accent colour or wallpaper.
- **No composite child**, so there are no nested-scope surfaces.
- **No live agent session**, so no live terminal output.
- **The sheet's bottom 12 points** are clipped by the main window client.
- **Accessibility-tree and font-metric evidence** were not collected.

## Replay

From the repository root, using only the Python standard library:

```sh
python3 investigation/visual-baseline/rendered-macos/replay.py
```

It checks each PNG's SHA-256, size, dimensions, bit depth, colour type and
ancillary chunk order (`IHDR sRGB eXIf IEND`, sRGB intent 0, no `iCCP`). It then
decodes the stored samples without colour management and recomputes every
rectangle: pixel count, distinct colours, top five colours with counts, maximum
channel spread, and exact opaque counts of the listed colours. It prints
`13 captures, 67 samples: all match` and exits 0, or lists each mismatch and
exits 1.

The decoder was cross-checked against Pillow on all 67 samples with no
mismatch. As a sensitivity check, lowering one blue value by 1 in a scratch
copy of `macos-workspace-focus-terminal.png` made the replay fail on both focus
dot samples. Pillow's re-encode also changed the file's hash, size and chunks,
which the replay reported too. `--record` rewrites only the measured fields; the
rectangles are chosen by hand.

[`tools/`](tools) holds the capture and input helper (`gcr.swift`) and the
ColorSync profile switcher (`colorsync-profile.swift`) used for these
captures. Neither is part of the app or built by the Makefile.
