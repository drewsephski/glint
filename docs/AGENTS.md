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
| `glint_analyze_scenes` | reversible | Split the recording into scenes from what the user did (click clusters, typing, app switches, markers), save one representative frame per scene and read its on-screen text (on-device OCR). Returns the storyboard and the frames as images — look at them before writing narration. Nothing leaves the Mac. |
| `glint_get_storyboard` | read | Scenes (times, actions, on-screen text, narration) from the last analysis, with frames as images when include_frames. |
| `glint_set_narration` | reversible | Write or edit the narration line of scenes yourself (after looking at glint_analyze_scenes frames). Pass lines as {scene_id: text}; empty text clears a line. Aim for ~2.5 words per second of scene; the fit step retimes the picture to the voice. |
| `glint_write_narration` | external | Have Claude write the script: every scene's frame, on-screen text, actions and presenter speech go to the Anthropic API and one timed narration line per scene comes back into the storyboard. Sends content off the Mac → approval unless policy allows external. A product brief makes a big difference. |
| `glint_list_voices` | read | ElevenLabs voices available to the user's account (ID, name, labels such as accent/gender/use case). |
| `glint_voiceover` | external | Synthesize the storyboard's narration with ElevenLabs (word-timed), add the clips to the timeline anchored at each scene, retime the picture so every scene lasts as long as its line (fit), and write exact captions from the word timings. Creates a proposal unless apply=true. Sends the script off the Mac → approval unless policy allows external. |
| `glint_fit_narration` | reversible | Retime scenes so each lasts as long as its voiceover clip (idle stretches are slowed/sped up first), and refresh captions. Use after moving clips or changing cuts. Proposal unless apply=true. |
| `glint_autopilot` | reversible | One call: transcribe (if there's a voice track), plan cuts, plan zooms, add captions, check quality, and (optionally) render variants. With narrate=true it also analyzes scenes, writes the script with Claude and adds an ElevenLabs voiceover fitted to the picture (external → approval). Edits are applied as separate undoable transactions labelled by step, or left as proposals with propose_only. |

Generated with `glint tools --markdown`.
