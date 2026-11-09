# Glint for AI agents

Glint exposes everything it can do as tools: over **MCP** (`glint mcp`, stdio) and the **CLI** (`glint call <tool> '<json>'`, or the friendly subcommands). Both call the same handlers as the macOS app, so an agent and a person can work on one project at the same time. Every edit is attributed, undoable and revision-checked.

## Connect

```bash
scripts/build-app.sh                                   # builds build/Glint.app (includes the CLI)
claude mcp add glint -- "$PWD/build/Glint.app/Contents/Helpers/glint" mcp
# any MCP client: command = <path>/glint, args = ["mcp"]
```

Screen capture needs the Screen Recording permission for the process that hosts the server (your terminal or agent app).

## The loop

1. `glint_project_info` → `glint_get_events` / `glint_transcribe` + `glint_get_transcript`
2. `glint_plan_cuts`, `glint_plan_zooms`, `glint_generate_captions` → **proposals** (nothing changes yet)
3. `glint_contact_sheet` / `glint_render_frame` with `proposal_id` (you get images), `glint_quality_report` with `proposal_id`
4. `glint_apply_proposal` (or `glint_propose_edits` / `glint_apply_operations` with `expected_revision`)
5. `glint_render` with variants → each output is measured (duration vs edit, resolution, black/frozen frames, sharpness, loudness)
6. Fix what fails and iterate. `glint_undo` / `glint_revert` reverse anything.

`glint_autopilot` runs steps 1–5 in one call. Resources `glint://docs/workflow`, `…/operations`, `…/style` and `…/quality` document the details.

## Recording a walkthrough as an agent

`glint_record_start` (approval needed unless the user's policy allows capture) → drive the app → report each action with `glint_record_action` (`kind` click/type/scroll/move, normalized `x`,`y` or `global_x`,`global_y`, `label`) and key moments with `glint_record_mark` → `glint_record_stop`.

Use `pointer: "agent"` when your automation doesn't move the real cursor (e.g. CDP-driven browsers). Glint then draws a smooth cursor along your reported actions. See `scripts/e2e/agent_walkthrough.py` for a complete, working example.

## Approvals

Tools marked `capture`, `destructive` or `external` may return `{"status":"approval_required","approval_id":…}`. Tell the user what you want to do; they approve in the Glint app (banner) or with `glint approve <id>` in an interactive terminal. Then repeat the identical call with `approval_id`. Approvals are single-use, expire, and are bound to the exact parameters. Agents can't approve.

## Tools

| Tool | Risk | Description |
|---|---|---|
| `glint_list_sources` | read | Displays and windows that can be recorded, with IDs and sizes. |
| `glint_list_projects` | read | Recent Glint projects (newest first) with duration and revision. |
| `glint_project_info` | read | Revision, durations, media, item counts, pending proposals, undo state. Start here. |
| `glint_get_timeline` | read | Full edit document (timeline + style) and the source→output time map. Use the revision as expected_revision when editing. |
| `glint_get_events` | read | What the user did while recording: clicks (with positions/targets), typing bursts, scrolls, idle stretches, app switches, markers. Source time. |
| `glint_get_transcript` | read | Word-timed transcript (source time), if transcribed. |
| `glint_history` | read | Transactions with author (user/agent), label and changed paths; plus undo/redo stacks. |
| `glint_quality_report` | read | Measurable checks on the edit without rendering: zoom coverage/pumping/duration, cursor-in-view while zoomed, camera speed, dead air, jump fragments, caption reading speed, duration vs target. Each failing check includes a fix. |
| `glint_render_frame` | reversible | Render the edited output at an output time to PNG and return it as an image — see exactly what viewers will see (optionally with a proposal applied or as a variant). |
| `glint_contact_sheet` | reversible | Grid of N evenly spaced (or given) output frames as one image with timestamps — review pacing and framing at a glance. |
| `glint_inspect_render` | read | Measure an output: duration, resolution, fps, codec, bitrate, black/frozen frames, sharpness, motion, loudness (LUFS), clipping — with pass/warn/fail verdicts. |
| `glint_list_renders` | read | Previous renders of a project with their measured reports. |
| `glint_list_proposals` | read | Edit proposals and their status (pending/applied/rejected). |
| `glint_plan_zooms` | reversible | Derive zooms from clicks/typing (anticipating actions, merging nearby ones, avoiding out-in pumping). Creates a proposal unless apply=true. Manual and agent zooms are kept; previous auto zooms are replaced. |
| `glint_plan_cuts` | reversible | Shorten pauses (silence on the mic), drop filler words, speed up silent typing / idle waiting, trim dead ends. Creates a proposal unless apply=true. |
| `glint_transcribe` | reversible | On-device speech-to-text with word timings (Apple SpeechTranscriber; whisper CLI fallback). Saves transcript.json. |
| `glint_generate_captions` | reversible | Turn the transcript into readable caption lines (≤ max chars, sentence/pause breaks). Creates a proposal unless apply=true. |
| `glint_propose_edits` | reversible | Create a reviewable proposal from operations (validated now, applied only when accepted). Preferred for non-trivial changes: the user sees title + rationale in the app. |
| `glint_apply_proposal` | reversible | Apply a pending proposal as one undoable transaction. |
| `glint_reject_proposal` | reversible | Mark a pending proposal rejected. |
| `glint_apply_operations` | reversible | Apply operations now as one undoable transaction. Pass expected_revision (from get_timeline/project_info) to avoid overwriting concurrent edits. |
| `glint_undo` | reversible | Undo the latest transaction (any author). |
| `glint_redo` | reversible | Redo the last undone transaction. |
| `glint_revert` | reversible | Selectively undo one earlier transaction if what it touched hasn't changed since (reports a conflict otherwise). |
| `glint_render` | reversible | Export one or more deliverables into the project's renders/ folder and measure each (duration, black/frozen frames, sharpness, loudness…). Optional proposal preview. |
| `glint_export` | destructive | Copy a rendered file to a destination outside the project. Overwriting an existing file requires user approval. |
| `glint_delete_project` | destructive | Move a project to the Trash. Always requires user approval. |
| `glint_record_start` | capture | Record a display or window (screen + input events, optional mic/system audio) into a new project. Agents need user approval unless the user's policy allows capture. |
| `glint_record_status` | read | Active recording: elapsed seconds and frames. |
| `glint_record_mark` | reversible | Drop a labelled marker into the active recording (e.g. 'opened settings') — planners and reviewers use it. |
| `glint_record_action` | reversible | Tell Glint what you just did in the recorded app (click/type/scroll/move) so it can zoom on it and draw the cursor — essential when you drive an app through automation (CDP, accessibility) that doesn't move the real pointer. Positions: normalized x/y in the recorded source, or global_x/global_y in screen points. |
| `glint_record_stop` | reversible | Stop and finalize the recording; returns the new project. |
| `glint_approval_status` | read | Check whether the user approved a pending request (agents cannot approve). |
| `glint_autopilot` | reversible | One call: transcribe (if there's a voice track), plan cuts, plan zooms, add captions, check quality, and (optionally) render variants. Edits are applied as separate undoable transactions labelled by step, or left as proposals with propose_only. |

Generated with `glint tools --markdown`.
