# Glint for AI agents

Glint exposes everything it can do as tools: over **MCP** (`glint mcp`, stdio) and the **CLI** (`glint call <tool> '<json>'`, or the friendly subcommands). Both call the same handlers as the macOS app, so an agent and a person can work on one project at the same time. Every edit is attributed, undoable and revision-checked.

## Connect

In the app: **Home › Agents › Connect** (or Settings › Agents). From a terminal:

```bash
glint connect                      # Claude Code (user scope), Codex (~/.codex/config.toml), Claude Desktop
glint connect codex                # one client
glint connect --status             # what's connected, and to which copy of Glint
glint connect --dry-run            # show the changes without making them
glint connect --remove             # disconnect
glint connect --print              # manual setup, plus snippets for Cursor, VS Code, Windsurf and Zed
glint install-cli                  # link `glint` into ~/.local/bin
```

`glint connect` checks that the server starts and answers (`tools/list`) before it changes any config. Any other MCP client: command `/Applications/Glint.app/Contents/Helpers/glint`, args `["mcp"]`, stdio. Give long-running tools (render, autopilot, voiceover) a generous timeout; Codex's default is 60 s, so Glint sets `tool_timeout_sec = 900` for it.

### Chat inside Glint

The editor's Chat tab runs Claude Code (`claude -p --output-format stream-json --strict-mcp-config --mcp-config <glint> --allowedTools mcp__glint --tools ""`) or Codex (`codex exec --json -c mcp_servers.glint…`, read-only sandbox) headless in the project's folder, with this app's `glint mcp` attached and a short system context naming the project. Follow-ups resume the agent's session (`--resume` / `codex exec resume`). The transcript and session IDs are saved in the project as `agent-chat.json`. The agent goes through the same tools, attribution and approvals as any MCP client (Claude Code reports itself as `claude-code`, Codex as `codex-mcp-client`). `GLINT_LIVE_CHAT=1 GLINT_LIVE_HELPER=<glint> swift test --filter LiveChatTests` exercises both CLIs for real.

### Where recording happens

`glint_list_sources` and the `glint_record_*` tools run inside Glint.app. `glint mcp` forwards them over a user-only Unix socket in Glint's support folder, opening the app in the background when it isn't running. macOS therefore asks for Screen Recording once, for Glint, instead of for each terminal or agent app, and the person sees the agent's recording in Glint (banner, menu bar, Stop). Every other tool runs in the `glint mcp` process. If the app can't be reached (or with `GLINT_CAPTURE=local`) capture runs in the MCP process as before, and needs the host app's permission. If the agent disconnects mid-recording, the take is finalized. If the person stops an agent's recording from Glint, the agent's next `glint_record_stop` returns the saved project with `already_stopped: true`, and `glint_record_status` reports it as `last_finished`.

## The loop

1. `glint_project_info` → `glint_get_events` / `glint_transcribe` + `glint_get_transcript`
2. `glint_plan_cuts`, `glint_plan_zooms`, `glint_generate_captions` → **proposals** (nothing changes yet)
3. `glint_contact_sheet` / `glint_render_frame` with `proposal_id` (you get images), `glint_quality_report` with `proposal_id`
4. `glint_apply_proposal` (or `glint_propose_edits` / `glint_apply_operations` with `expected_revision`)
5. `glint_render` with variants → each output is measured (duration vs edit, resolution, black/frozen frames, sharpness, loudness)
6. Fix what fails and iterate. `glint_undo` / `glint_revert` reverse anything.

`glint_autopilot` runs steps 1–5 in one call. Resources `glint://docs/workflow`, `…/operations`, `…/style` and `…/quality` document the details.

## Narrated demos (scenes → script → voice)

A take without a presenter becomes a narrated product demo in three inspectable steps:

1. `glint_analyze_scenes`: Glint splits the take into scenes from what the user did (click clusters, typing, app switches, markers), saves one frame per scene and reads its on-screen text with on-device OCR. You get the storyboard and the frames as images. Nothing leaves the Mac.
2. Script: `glint_write_narration` sends the frames, on-screen text, actions and any presenter speech to Claude and gets one line per scene back, budgeted to the scene's length (`brief` is the most useful input). Or look at the frames and write the lines yourself with `glint_set_narration`. Lines live in the storyboard, not on the timeline.
3. `glint_voiceover`: ElevenLabs synthesizes each line with word timings (`glint_list_voices` to choose), clips are anchored at each scene's start, the picture is retimed so each scene lasts as long as its line (idle stretches first, then the whole scene), captions are rebuilt from the word timings and the recorded tracks duck under the voice. It's a proposal unless `apply`. After moving clips or cutting, `glint_fit_narration` re-times.

Both cloud steps are `external`: an agent gets `approval_required` unless the user's policy allows external calls. API keys come from the user's Settings or `glint keys set`; agents can't read or set them. `glint_autopilot` with `narrate: true` chains all three.

## Recording a walkthrough as an agent

`glint_record_start` (approval needed unless the user's policy allows capture) → drive the app → report each action with `glint_record_action` (`kind` click/type/scroll/move, normalized `x`,`y` or `global_x`,`global_y`, `label`) and key moments with `glint_record_mark` → `glint_record_stop`.

Use `pointer: "agent"` when your automation doesn't move the real cursor (e.g. CDP-driven browsers). Glint then draws a smooth cursor along your reported actions. See `scripts/e2e/agent_walkthrough.py` for a complete, working example.

## Approvals

Tools marked `capture`, `destructive` or `external` may return `{"status":"approval_required","approval_id":…}`. Tell the user what you want to do; they approve in the Glint app (banner) or with `glint approve <id>` in an interactive terminal. Then repeat the identical call with `approval_id`. Approvals are single-use, expire, and are bound to the exact parameters. Agents can't approve.

## Shots, callouts, masks, audio and captions

- `glint_import_clip` copies a movie into the project and inserts it as a shot (at the end or a program time; `start`/`end` use part of the file). `glint_list_clips` shows the order with program times. Clip operations (`split_clip`, `move_clip`, `update_clip`, `remove_clip`, `replace_clip`) carry every timeline item along with its content. With several shots, "source time" means the program timeline of all shots end to end.
- Callouts (`add_annotation`: text, arrow, box, highlight) and privacy masks (`add_redaction`: pixelate, blur, solid) use geometry normalized to the recorded screen and are drawn into every rendered frame. Use `solid` for secrets. Check with `glint_render_frame`.
- `glint_import_audio`: `music` (loops, fades, ducks under narration), `voice` (your own voiceover) or `effect`.
- `glint_export_subtitles` / `glint_import_subtitles` (SRT, WebVTT, timed to the edited output); `glint_edit_transcript` cuts words by index range or phrase.
- `glint_list_presets`, `glint_apply_preset`, `glint_save_preset` reuse a look.

## Repeatable demos: recipes and evidence

Glint does not explore or drive apps itself. You drive the app; Glint records, keeps the evidence and keeps human edits when a scene is redone.

1. `glint_recipe_save`: scenes with stable ids, steps, preconditions, expected outcomes (`visible_text`, `state`, `manual`; `required`). Changing content bumps `version`.
2. Record (`glint_record_start`), and at each scene start call `glint_record_mark` with note `scene:<id>`.
3. `glint_recipe_build` splits the recording into one shot per scene.
4. `glint_recipe_evidence` for what you checked. `verified` needs `source` `assertion`, `ocr` or `human` plus the `observed` value. A reported click (`action`) or a model's opinion (`vision`) is stored as `needs_review`. A current `failed` wins over `verified`.
5. `glint_recipe_verify` OCRs the end of each scene for `visible_text` outcomes and reports `verified` / `failed` / `needs_review` per outcome and overall. Unknown never passes.
6. After a product change, record the scene again as a new take with its marker and evidence, then `glint_recipe_refresh_scene` (`take`). Edits elsewhere stay on their content; manual items inside the scene are placed proportionally and reported; auto items are dropped; evidence from the old take stops counting.

Example (CLI):

```bash
glint recipe save invite.recipe.json
# record over MCP while you drive the app: glint_record_start, then glint_record_mark {"note":"scene:invite"} at each scene
glint recipe build
glint recipe evidence invite sent --status verified --source assertion --detail "GET /api/invites" --observed "1 pending"
glint recipe verify                               # exit 1 if a required outcome failed
glint recipe refresh invite --take "Recording 2026-11-12"
```

## Durable jobs

`glint_job_start` with `kind: render` (variants) or `production` (quality, up to `max_attempts` deterministic repairs as undoable transactions, draft render, file inspection, recipe evidence). Jobs persist in `jobs/` with per-stage artifacts and SHA-256 hashes and render from a snapshot of the document. `idempotency_key` returns the same job; reusing it for different work is refused. `wait: false` returns at once and keeps running in the MCP server; poll `glint_job_status`. `glint_job_cancel` stops at the next frame and removes the partial file; `glint_job_retry` resumes after the last completed stage. A job whose process died reads `interrupted`. A production job ends `succeeded` only when every check passes, otherwise `needs_review` with the items. `glint_autopilot` reports `ready`, `needs_review`, `draft` or `failed` in the same spirit.

## Capture reliability

`glint_record_preflight` checks permissions, the source, folder access and disk space before a take (`glint_record_start` runs it and refuses on failures). `glint_record_pause` / `glint_record_resume` pause all tracks and input together, with no gap in the files. `glint_recover_recordings` lists and rebuilds takes interrupted by a crash (media is written in 2 s fragments; up to about 2 s can be lost).

| Tool | Risk | Description |
|---|---|---|
| `glint_list_sources` | read | Displays and windows that can be recorded, with IDs and sizes. Pass cameras:true for the cameras (for glint_record_start camera_id) instead. |
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
| `glint_record_start` | capture | Record a display or window (screen + input events, optional mic/system audio, optional camera for a facecam bubble) into a new project. Runs glint_record_preflight first and refuses with a plain fix when a check fails (no Screen Recording permission, missing source or camera, microphone not allowed, not enough disk). Pause with glint_record_pause. Agents need user approval unless the user's policy allows capture. |
| `glint_record_status` | read | Active recording: elapsed seconds (paused time excluded), frames, whether it is paused, its pauses, and warnings (camera disconnected, an audio track stopped). After a take ended on its own, last_finished says why (time_limit, capture_error) with the error and warnings. |
| `glint_record_mark` | reversible | Drop a labelled marker into the active recording (e.g. 'opened settings') — planners and reviewers use it. |
| `glint_record_action` | reversible | Tell Glint what you just did in the recorded app (click/type/scroll/move) so it can zoom on it and draw the cursor — essential when you drive an app through automation (CDP, accessibility) that doesn't move the real pointer. Positions: normalized x/y in the recorded source, or global_x/global_y in screen points. |
| `glint_record_stop` | reversible | Stop and finalize the recording; returns the new project. |
| `glint_approval_status` | read | Check whether the user approved a pending request (agents cannot approve). |
| `glint_analyze_scenes` | reversible | Split the recording into scenes from what the user did (click clusters, typing, app switches, markers), save one representative frame per scene and read its on-screen text (on-device OCR). Returns the storyboard and the frames as images — look at them before writing narration. Nothing leaves the Mac. |
| `glint_get_storyboard` | read | Scenes (times, actions, on-screen text, narration) from the last analysis, with frames as images when include_frames. |
| `glint_set_narration` | reversible | Write or edit the narration line of scenes yourself (after looking at glint_analyze_scenes frames). Pass lines as {scene_id: text}; empty text clears a line. Aim for ~2.5 words per second of scene; the fit step retimes the picture to the voice. |
| `glint_write_narration` | external | Have Claude write the script: every scene's frame, on-screen text, actions and presenter speech go to the Anthropic API and one timed narration line per scene comes back into the storyboard. Sends content off the Mac → approval unless policy allows external. A product brief makes a big difference. |
| `glint_list_voices` | read | ElevenLabs voices available to the user's account (ID, name, labels such as accent/gender/use case). |
| `glint_voiceover` | external | Synthesize the storyboard's narration with ElevenLabs (word-timed), add the clips to the timeline anchored at each scene, retime the picture so every scene lasts as long as its line (fit), and write exact captions from the word timings. Creates a proposal unless apply=true. Sends the script off the Mac → approval unless policy allows external. |
| `glint_fit_narration` | reversible | Retime scenes so each lasts as long as its voiceover clip (idle stretches are slowed/sped up first), and refresh captions. Use after moving clips or changing cuts. Proposal unless apply=true. |
| `glint_autopilot` | reversible | One call: transcribe (if there's a voice track), plan cuts, plan zooms, add captions, check quality, and (optionally) render variants. With narrate=true it also analyzes scenes, writes the script with Claude and adds an ElevenLabs voiceover fitted to the picture (external → approval). Edits are applied as separate undoable transactions labelled by step, or left as proposals with propose_only. Returns status: failed (a required step failed — asked-for captions, narration or renders), needs_review (quality failures, unverified recipe outcomes, or no recipe), draft (propose_only) or ready (every check passed); each step reports ok/skipped/failed. |
| `glint_record_pause` | reversible | Pause the active take: screen, audio, camera and input stop recording until glint_record_resume. The finished take has no gap (the pause becomes a cut); pauses are listed in the events. Paused time doesn't count towards max_duration. |
| `glint_record_resume` | reversible | Resume a paused take. Recording continues in the same files, right after the moment it was paused. |
| `glint_record_preflight` | read | Check a take can start, without recording: Screen Recording permission, the display/window exists, microphone and camera access (when asked for), free disk space for the take (estimated from the bitrate × max_duration, or per minute), and write access to the projects folder. Each check is pass/warn/fail with a plain-language fix. glint_record_start runs the same checks and refuses on a fail. |
| `glint_recover_recordings` | reversible | Find and rebuild takes that never finished (Glint or the recording process crashed, was force-quit or lost power, or finalizing failed). action list (default): the interrupted takes. action recover: rebuild one (project) or all of them into normal projects from the media saved every 2 s and the last input-events checkpoint; returns what was recovered and what was lost. action discard: move one to the Trash (destructive: needs the user's approval). |
| `glint_list_clips` | read | The program's shots in order with their program start/end (source seconds), file ranges, recipe scenes and takes. A project that is one recording has one shot. |
| `glint_import_clip` | reversible | Add a movie file as a shot: copied into the project (the original is untouched) and inserted at a program time (default: the end). Existing edits keep their content. Use start/end to use part of the file. Applied as an undoable transaction unless apply=false. |
| `glint_import_audio` | reversible | Add a music bed (loops, fades, ducks under narration by default), a recorded voiceover (ducks the recording like generated narration) or a sound effect at a program time. The file is copied into the project. |
| `glint_export_subtitles` | reversible | Write the captions as SRT or WebVTT timed to the EDITED output (cuts and speed changes applied), into renders/subtitles/. Copy it out with glint_export. |
| `glint_import_subtitles` | reversible | Replace the captions with an SRT or WebVTT file. Times are read as the edited output timeline (what an exported file uses) unless time_base is "source". |
| `glint_edit_transcript` | reversible | Remove spoken words from the video by editing the transcript: pass word index ranges (from glint_get_transcript words:true) and/or a phrase to delete everywhere it occurs. Creates cuts that don't eat neighbouring words. Proposal unless apply=true. |
| `glint_list_presets` | read | Built-in and saved looks (background, frame, cursor, zoom, captions, canvas, facecam) that can be applied to any project. |
| `glint_apply_preset` | reversible | Apply a saved or built-in look to a project as one undoable change. |
| `glint_save_preset` | reversible | Save this project's look as a reusable preset (Application Support/Glint/presets). Voice and audio levels are left out unless listed in sections. |
| `glint_recipe_save` | reversible | Save the reusable recipe for this demo: audience, intent, ordered scenes with STABLE ids, steps, preconditions, expected outcomes (visible_text \| state \| manual) and narration intent. Versioned: changing content bumps version. Never put credentials in fixtures. |
| `glint_recipe_get` | read | The project's recipe, and the current evidence report: per scene and expectation verified / failed / needs_review, from evidence for the takes in the edit. |
| `glint_recipe_build` | reversible | Split a recording into one shot per recipe scene, from the scene:<id> markers dropped while recording (glint_record_mark note "scene:<id>"). Shots carry the scene ID so a scene can later be refreshed from a new take. Applied unless apply=false. |
| `glint_recipe_evidence` | reversible | Record what you observed for an expected outcome. status verified needs source assertion\|ocr\|human and the observed value; a reported action (a click) or a vision model's opinion is stored as needs_review — a click doesn't prove a result. failed overrides verified. |
| `glint_recipe_verify` | reversible | Check visible_text expectations on the last frame of each scene with on-device OCR (found → verified, not found → needs_review), then report the demo's status. Only `verified` means every required outcome has current evidence. |
| `glint_recipe_refresh_scene` | reversible | Replace one recipe scene's shot with the same scene from another recording (record it with scene:<id> markers, or pass start/end). Manual edits elsewhere stay on their content; manual items inside the scene are placed proportionally; automatic ones are dropped. The take's evidence comes along; evidence from the old take stops counting. |
| `glint_job_start` | reversible | Start a render job (variants) or a production job (quality check → bounded automatic repair → draft render → inspection → recipe evidence). Jobs persist in the project with per-stage checkpoints; the same idempotency_key returns the same job. wait:false returns at once and keeps running in this server; poll glint_job_status. A production job ends succeeded only if every check passes, otherwise needs_review with the items. |
| `glint_job_status` | read | A job's status, progress, stages (with artifacts and hashes), result and review items. A job whose process died shows interrupted. |
| `glint_job_list` | read | Jobs of a project, newest first. |
| `glint_job_cancel` | reversible | Ask a running job to stop (it stops at the next frame and removes the partial file). Completed stages are kept for a retry. |
| `glint_job_retry` | reversible | Resume a failed, cancelled, interrupted or needs-review job after its last completed stage (completed renders whose files still hash the same are not redone). |
