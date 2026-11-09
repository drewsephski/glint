# Research

| Document | What it covers |
|---|---|
| [foundations.md](foundations.md) | macOS frameworks chosen (with evidence), the open-source evaluation (reelbird, Openscreen, Cap) and the clean-build decision |
| [screen-studio.md](screen-studio.md) | REA study of Screen Studio 4.1.0 (Electron + Swift helper): capture, cursor, zoom, springs, timeline, rendering, export |
| [screenkite.md](screenkite.md) | REA study of ScreenKite 2.3.2 (native Swift): capture, project format, input tracking, zoom, editor, Metal compositor, AI, MCP/CLI |

## Method and boundaries

- **Scope:** only locally installed, user-owned app bundles were inspected, with the REA toolkit plus standard tools (`otool`, `nm`, `strings`, `codesign`, plist parsing), and asar extraction for Screen Studio.
- **No execution:** neither app was launched, modified, or used to record anything.
- **No bypassing:** no licensing or protection mechanism was circumvented.
- **No copying:** reports describe behaviour, formats and parameters in our own words. No proprietary code or assets were copied into Glint.
- **Evidence labels:** each report marks findings as CONFIRMED (cites Evidence IDs, files or symbols), INFERRED, or UNKNOWN, and ends with an evidence ledger.
- **Known limits:**
  - ScreenKite has no pseudocode: Hopper was blocked by an Automation permission, and the 239 MB binary timed out in the overview. Its schema comes from Swift field metadata, imports and strings.
  - Screen Studio's main process ships as V8 bytecode, and renderer names are obfuscated behind string tables, which the agent decoded without running app code.

## How the findings shaped Glint

| Finding (confirmed) | Glint design |
|---|---|
| Both apps capture with `SCStream` and write with their own `AVAssetWriter` | Same. Events go on the host clock to align with frame PTS. |
| Both redraw the cursor from recorded metadata and fingerprinted `NSCursor` images | Same, plus zero-lag offline Gaussian smoothing pinned exactly at clicks. |
| Screen Studio: spring camera; presets roughly *Focused* 250/40/2.25 and *Smooth* 170/50/3 (stiffness/damping/mass) | Our own spring defaults: 180/48/3 (ζ≈1.03, ω≈7.7 rad/s). The app exposes Smooth / Focused / Snappy. |
| Screen Studio: a click opens a window from −0.3 s to +2.5 s; windows < 2.5 s apart merge; 2× default; no zooms in the last 1 s | Planner: lead-in 0.7 s (it anticipates the spring), hold 2.2 s, merges within 2 s when the actions fit one view (otherwise neighbouring zooms butt end-to-start so the camera pans), skips the final second, 2× default. Typing also zooms (as in ScreenKite). |
| ScreenKite: user-edited zooms survive regeneration | Re-planning replaces only `origin: auto` items. Manual and agent items are kept. |
| Motion blur: Screen Studio uses 16 export / 6 preview samples | Glint: 12 for export and stills, 4 for live preview, tent-weighted. |
| Screen Studio's undo is patch-based | Glint's history stores forward/inverse JSON patches, derived automatically and shared across processes. |
| ScreenKite has an MCP server (89 tools) and CLI; Screen Studio has none | Glint: 34 MCP tools sharing one registry with the CLI, plus proposals, risk classes and human approvals (not found in either reference during a bounded static search). |
| Export bits-per-pixel presets (Screen Studio: Web 0.0175, Social 0.05, Studio 0.3) | Glint default 0.09 bpp for H.264 (HEVC × 0.7). |
