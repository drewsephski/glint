import Foundation
import GlintCore
import GlintRender

/// Agent-facing documentation, served as MCP resources and by `glint docs`.
public enum Docs {
    public struct Resource: Sendable { public let uri: String; public let name: String; public let description: String; public let body: @Sendable () -> String }

    public static let serverInstructions = """
    Glint records the screen and turns takes into polished product demos. Everything is non-destructive: media is never modified; \
    edits are typed operations applied as undoable transactions to a project's edit document. The user may be editing the same \
    project in the Glint app at the same time — pass expected_revision when applying edits.

    Typical loop: glint_project_info → glint_get_events / glint_get_transcript → plan (glint_plan_cuts, glint_plan_zooms, \
    glint_generate_captions create PROPOSALS) → review (glint_contact_sheet / glint_render_frame with proposal_id, \
    glint_quality_report with proposal_id) → glint_apply_proposal → glint_render (variants) → glint_inspect_render → iterate. \
    glint_autopilot does the whole pass in one call.

    Narrated demos (the Clueso-style path): glint_analyze_scenes (on-device: scenes from input, one frame + on-screen text each) → \
    look at the frames → glint_write_narration (Claude writes one timed line per scene; external) or glint_set_narration (write it \
    yourself) → glint_voiceover (ElevenLabs synthesizes word-timed clips, the picture is retimed to fit each line, captions come \
    from the voice; external). glint_autopilot narrate:true chains all of it.

    Times are source (recording) seconds unless an operation sets time_base:"output" (use output times when you reason about \
    rendered frames). Positions are normalized 0–1 on the recorded screen, origin top-left.

    Gated actions: starting a recording (capture), overwriting/deleting files (destructive) and anything leaving the Mac (external) \
    return status "approval_required" with an approval_id. Tell the user what you want to do and ask them to approve it in the \
    Glint app or with `glint approve <id>` in their terminal; then call the tool again with approval_id. You cannot approve requests yourself.
    """

    public static let resources: [Resource] = [
        Resource(uri: "glint://docs/workflow", name: "Workflow", description: "How to go from a raw recording to verified deliverables", body: { workflow }),
        Resource(uri: "glint://docs/operations", name: "Edit operations", description: "Every operation and its fields", body: { operations }),
        Resource(uri: "glint://docs/style", name: "Style reference", description: "All set_style paths with defaults", body: { style() }),
        Resource(uri: "glint://docs/quality", name: "Quality checks", description: "What each check measures and how to fix it", body: { quality }),
    ]

    public static let workflow = """
    # Glint workflow for agents

    1. **Capture** — `glint_list_sources`, then `glint_record_start` (needs approval) with `max_duration` or `glint_record_stop`.
       Drop `glint_record_mark` notes at key moments ("opened settings") — they show on the timeline.
    2. **Understand** — `glint_project_info`, `glint_get_events` (clicks with positions and accessibility labels, typing bursts,
       idle stretches, app switches), `glint_transcribe` + `glint_get_transcript`.
    3. **Plan** — `glint_plan_cuts` (pauses, fillers, idle/typing speed-ups, end trims), `glint_plan_zooms`, `glint_generate_captions`.
       Each returns a proposal. Hand-written edits go through `glint_propose_edits` (preferred) or `glint_apply_operations`.
    4. **Review** — `glint_contact_sheet` and `glint_render_frame` accept `proposal_id` so you can look before applying.
       `glint_quality_report` gives pass/warn/fail checks with fixes; aim for no `fail` and few `warn`.
    5. **Apply** — `glint_apply_proposal`. Everything is undoable (`glint_undo`, `glint_revert` for one transaction).
    6. **Deliver** — `glint_render` with variants (landscape, square, portrait, gif, landscape-4k). Each output is measured
       (duration vs edit, resolution, black/frozen frames, sharpness, loudness). Fix and re-render until checks pass.
    7. **Hand off** — `glint_export` copies a render where the user wants it (overwrites need approval).

    ## Narrated demos

    Recordings without a presenter become narrated product demos in three steps, each inspectable:

    1. `glint_analyze_scenes` — splits the take into scenes from what the user did (click clusters, typing, app switches,
       markers), saves a frame per scene and reads its on-screen text with on-device OCR. The storyboard
       (`glint_get_storyboard`) is the script's skeleton: ids, times, actions, text, speech.
    2. Script — `glint_write_narration` sends the frames and facts to Claude and gets one line per scene back, budgeted
       at ~2.5 words per second of scene; pass a `brief` (what the product is, who the viewer is). Or write the lines
       yourself with `glint_set_narration` after looking at the frames. Lines live in the storyboard, not the timeline.
    3. `glint_voiceover` — ElevenLabs synthesizes each line (`glint_list_voices` to choose), clips are anchored at each
       scene's start, the picture is retimed so each scene lasts as long as its line (idle stretches stretch or shrink
       first, then the whole scene), captions are rebuilt from the word timings and the recorded tracks duck under the
       voice. Review the proposal, then apply. After moving clips or changing cuts, `glint_fit_narration` re-times.

    Voiceover clips are timeline items (`add_voiceover`, `update_voiceover`, `remove_voiceover`): `start` is a source
    instant; the clip plays at 1× on the output timeline from there. `style.audio.voiceoverGain`, `duckUnderVoiceover`
    and `duckLevel` control the mix; `style.voice` remembers the voice.
    """

    public static var operations: String {
        """
        # Edit operations

        Send as `operations: [...]` to `glint_apply_operations` or `glint_propose_edits`. All times are source seconds unless
        `"time_base": "output"`. IDs are returned in `created`.

        | op | fields | notes |
        |---|---|---|
        | add_zoom | start, end, scale (1–6, default 2), focus ("cursor" or {x,y}), reason | camera eases in/out with a spring |
        | update_zoom | id, start?, end?, scale?, focus? | |
        | remove_zoom / clear_zooms | id / origin? | clear_zooms origin:"auto" keeps manual ones |
        | add_cut | start, end, reason | removes that range from the output |
        | update_cut / remove_cut / clear_cuts | id … / origin? | |
        | set_speed | start, end, rate (0.1–16) | overlapping speed ranges are replaced |
        | update_speed / remove_speed / clear_speeds | | |
        | set_trim | start?, end? | in/out points |
        | set_style | path, value | e.g. background.preset "ocean", cursor.scale 2, zoom.stiffness 250, canvas.aspect "1:1", facecam.position "top-left" |
        | set_captions | items: [{id,start,end,text,words}] | replace all captions |
        | update_caption | id, text?, hidden?, start?, end? | |
        | remove_caption / clear_captions | id / – | |
        | add_marker / remove_marker | time, text / id | |
        | add_voiceover | clip: {id, start, path, text, duration, words?, gain?, scene?} | path is inside the bundle (media/voiceover/…); usually made by glint_voiceover |
        | update_voiceover | id, start?, gain? (0–3), text? | move a clip or change its level |
        | remove_voiceover / clear_voiceover | id / origin? | |
        | rename | text | |

        Example:
        ```json
        [{"op":"add_zoom","start":4.2,"end":7.5,"scale":2.2,"focus":"cursor","reason":"show the Save button"},
         {"op":"set_speed","start":12,"end":19,"rate":3,"reason":"build is waiting"},
         {"op":"set_style","path":"background.preset","value":"midnight"}]
        ```
        Background presets: \(BackgroundPresets.names.joined(separator: ", ")).

        Facecam: when `glint_project_info` says `camera: true`, the take has a camera recording drawn as a bubble over
        the screen (it follows cuts and speed changes, and stays put while the screen zooms). Style it with `set_style`
        under `facecam`: `visible`, `shape` (circle | square | wide), `position` (top-left | top-right | bottom-left |
        bottom-right), `size` (fraction of the canvas' shorter side), `mirror`, `zoom` (crop in), `borderWidth`,
        `borderColor`, `shadowOpacity`, `scaleWhenZoomed` (size while the screen is zoomed in). Captions keep clear of it.
        """
    }

    public static func style() -> String {
        let json = JSONCoding.string(Style())
        return "# Style (defaults)\n\nAddress fields with dotted paths in `set_style`, e.g. `frame.padding`.\n\n```json\n\(json)\n```\n"
    }

    public static let quality = """
    # Quality checks

    - **zoom_coverage** ≤ 75% of the video zoomed — viewers need context.
    - **zoom_min_duration** zooms ≥ 1.2s — shorter feels like a glitch.
    - **zoom_pumping** no zoom-out-then-in within 0.7s — merge or butt zooms together.
    - **cursor_in_view** ≥ 90% of zoomed frames keep the cursor visible.
    - **camera_speed** peak ≤ 3 canvas widths/s — lower zoom.stiffness or scale jumps.
    - **dead_air** no output stretch ≥ 3s with no input and no speech.
    - **jump_fragments** no kept piece < 0.35s between cuts.
    - **caption_reading_speed** ≤ 20 chars/s; **caption_length** fits one line.
    - Render checks: duration matches the edit, resolution, black frames < 2%, frozen picture < 3s, sharpness, bitrate,
      loudness −16 LUFS ±4, no clipping.
    """

    public static func polishPrompt(project: String, target: String?) -> String {
        """
        Polish the Glint project "\(project)" into a product demo.
        1. Read glint_project_info and glint_get_events; transcribe if there is audio.
        2. Create proposals with glint_plan_cuts, glint_plan_zooms and (if there is speech) glint_generate_captions.
        3. For each proposal, look at glint_contact_sheet with its proposal_id and run glint_quality_report with it\(target.map { " (target_duration \($0))" } ?? "").
           Adjust with glint_propose_edits if checks fail; apply the good ones with glint_apply_proposal.
        4. Render landscape and portrait variants, inspect them, and fix anything that fails.
        5. Summarize what you changed (with transaction IDs so the user can revert) and where the files are.
        """
    }
}
