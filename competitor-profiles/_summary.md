# Glint: competitive research and agent-native product direction
Research date: November 10, 2026.

## Recommendation

Build Glint for developers who need accurate, polished demos of local or private software, then need to update those demos as the software changes.

Proposed promise: **“Your coding agent records the workflow, checks what it shows, and keeps the demo current.”**

This is a positioning hypothesis. We have not validated demand, willingness to pay, or superiority through customer interviews or comparative trials.

## What the research changes

- **Screen Studio sets a visual baseline and is pursuing MCP.** Its [roadmap](https://screen.studio/roadmap) lists that integration as in progress. An agent connector is a temporary feature advantage.
- **ScreenKite already serves local agent editing.** Its [guide](https://www.screenkite.com/en/guide/agentic-video-editing) documents shared editing tools, undo and plan/apply. Glint cannot credibly own “Screen Studio with MCP.”
- **Tella already markets automated capture and PR demos.** Its [Auto Capture page](https://www.tella.com/auto-capture) describes remote browser recording, but explicitly excludes localhost, intranet hosts and desktop/mobile applications. Beta claims were not tested.
- **Clueso already markets agent-led content production and bulk updates.** Its [MCP page](https://www.clueso.io/mcp) makes brand consistency and release workflows explicit.
- **Agent Screenplay already executes local scenarios.** The [maintainer README](https://github.com/gmpetrov/agent-screenplay/blob/main/README.md) covers semantic targets, rehearsal, recording and re-rendering. Local scripted capture is a competitive requirement, not a defensible position by itself.

The possible opening is the combination of local capture, inspectable outcome evidence, preservation of human edits, and predictable maintenance of an existing demo. Selective, evidence-checked re-recording was **not established in the reviewed sources**; this is not proof that competitors cannot do it.

Profiles: [Screen Studio](screen-studio.md), [ScreenKite](screenkite.md), [Tella](tella.md), [Clueso](clueso.md), [Agent Screenplay](agent-screenplay.md). Each includes dated source links and qualifications.

## Glint's actual starting point

Reviewed the current working tree, not just the README. Existing unrelated changes are present, including camera/onboarding work; they were not modified or validated.

| Foundation | Evidence in this repository | Product implication |
|---|---|---|
| Shared app/CLI/MCP engine, transactions and proposals | [Architecture](../docs/ARCHITECTURE.md), [Engine](../Sources/GlintCore/Engine.swift) | Keep human review and agent edits on one project |
| Recorded actions and labels | [Events](../Sources/GlintCore/Events.swift) | Useful inputs, but a reported click does not prove the application changed |
| Scene analysis and narration | [SceneAnalyzer](../Sources/GlintAnalysis/SceneAnalyzer.swift), [scene model](../Sources/GlintCore/Voiceover.swift) | Extend current scenes rather than inventing a separate editor |
| Edit/render checks | [Quality](../Sources/GlintCore/Quality.swift), [render service](../Sources/GlintAgent/Service.swift) | Good foundation for a repair loop; currently measures technical properties, not demonstrated product truth |
| One-call editing pipeline | [Autopilot](../Sources/GlintAgent/Tools.swift) | Existing orchestration can be hardened; do not rebuild it just to add a new agent abstraction |

Specific limitations matter:
- SceneAnalyzer uses one representative frame plus OCR; previous scene narration is matched approximately by start/end timing. This does not provide stable identity across a new recording.
- Autopilot runs planners and reports quality, then can render. It does not implement a bounded, quality-driven repair loop or a semantic release gate. Transcription failure is recorded as skipped; required deliverables need explicit failure states.
- Current recording writers finalize one file per track. Crash recovery remains a production priority.
- The documented timeline is single-source; replacing a scene from a new take requires source/shot composition work.
- The documented jobs are synchronous. Durable job IDs, cancellation and checkpointed recovery remain necessary for unattended runs.
- GAPS.md is useful but can lag in-flight changes. In particular, webcam status is not treated as a confirmed current gap.

This is source inspection, not proof that every documented capability works on a physical device.

## The user experience to aim for

First request:

> “Make a 45-second demo of inviting a teammate in my local app. Use the demo account, show that the invitation appears, and explain it for a first-time admin.”

Glint produces a short storyboard, executes the approved workflow, captures the result, narrates the visible steps, and returns an editable draft with a review view.

Follow-up after a product change:

> “The invite flow moved into Settings. Update that section. Keep my intro, voice and timing choices.”

Glint identifies the affected scene, re-establishes its prerequisites, records the changed workflow, checks the new outcome, and presents the old/new scene and any downstream consequences. It never claims a successful invitation just because the pointer clicked Send.

The default user view should be a storyboard, progress, draft preview and concrete review items. Keep raw operation lists and diagnostic data in the inspector.

## Prioritized product capabilities

### 1. A reusable demo recipe

Persist audience, intent, ordered scenes, semantic targets, preconditions, expected outcomes, narration intent and output presets. Use stable scene IDs independent of timestamps. Bind recipes to an application/build and reference fixture data without embedding credentials.

Let an existing coding agent plan and drive the app. Glint owns capture, editing and evidence. Start with one local-browser adapter; native desktop adapters follow after reliability is demonstrated.

A coordinate-only fallback should be visibly lower-confidence. A locator “repair” that finds a different button must not silently redefine the intended action.

### 2. Evidence for what the video actually demonstrates

For each important step, keep the intended action, observed application state, and before/after frames. Where available, combine semantic element state with an observable postcondition.

Use three statuses: verified, failed, and needs review. A vision model's confidence is not equivalent to a deterministic assertion. An “invitation sent” toast may establish visible UI behavior, but not email delivery; only claim the latter if independently checked.

Generate narration from these observations and approved product facts. Flag unsupported promises, missing results and mismatched captions.

### 3. Refresh a changed scene while preserving editorial work

Introduce a small source/shot abstraction sufficient to replace a scene from another take. Keep presentation choices attached to stable scene IDs: narration intent, zoom intent, callouts, style and manual overrides.

Re-run prerequisites for dependent scenes. Changing a scene's duration invalidates downstream timing, captions and perhaps narration; recompute those dependencies. Reuse unaffected media and voice assets where inputs are unchanged.

For a first implementation, a whole scenario may need to run again while only changed shots enter the final edit. Do not promise arbitrary mid-workflow replay before state restoration exists.

### 4. A bounded quality-and-repair loop

Build on existing checks: render a draft, inspect key moments and transitions, propose targeted changes, re-check, and stop after a small configured attempt/cost budget. Unresolved failures become review items.

Separate:
- Technical checks: decode success, intended duration, audio clipping, accidental black frames.
- Presentation checks: important text readable at final output size, target visible, captions unobstructed, camera settles before important results.
- Semantic checks: required action/result appears and narration matches it.

Static product screens can be intentionally still. Do not turn every frozen-frame warning into an automatic cut.

### 5. Reliable jobs and scoped execution

Persist job stages, artifact hashes, revision, provider costs and idempotency keys. Support reconnect, cancellation and retry from the last completed stage without duplicating paid TTS or destructive app actions.

Preflight capture permissions, disk space and source availability. Segment recordings for recovery. Use a seeded demo workspace and explicit action scope for rehearsals, which can mutate application state.

Add manual redaction masks and scan the final rendered frames before sending them externally. Automatic detection helps triage; it is not a guarantee that all sensitive content is removed.

## First build milestone

**One repeatable local-web demo, 30–60 seconds, one workflow, one theme, one voice and a landscape output.**

Order:
1. Add a versioned recipe and stable scene IDs around the existing storyboard.
2. Drive one local browser workflow with deterministic fixture setup and observable postconditions.
3. Persist capture/edit/render checkpoints and return a reviewable draft with evidence.
4. Add bounded repair using existing quality reports.
5. Change one UI step, record again, and replace its shot while retaining a manual edit elsewhere.

Multi-take shot composition is a real prerequisite for step 5. Until it exists, regenerate the full video and label that limitation honestly.

Defer general-purpose B-roll editing, elaborate effects, an agent marketplace, broad social publishing, and Windows parity. Existing capture/preview quality remains a release requirement.

## Validation before expanding

Use three workflows: navigation/search, a form with a visible result, and a multi-step settings change. Run each ten times, including controlled selector changes, slow loading and an interrupted render.

Proposed go/no-go targets, not measured results:
- At least 27 of 30 runs reach a reviewable draft without manual timeline work; also publish failures per workflow.
- Every successful draft has evidence for every required step; unknown evidence never passes silently.
- At least 9 of 10 controlled refreshes preserve unaffected manual edits.
- Median human correction time is under two minutes for a 45-second demo.
- At least four of five target users choose the Glint output for clarity/polish in a blinded comparison with a matched baseline. Treat this as an early signal, not statistical proof.

Compare with Screen Studio for output quality, ScreenKite for agent editing, and Agent Screenplay for repeatable local capture. Test Tella where beta access permits. Record human intervention, total elapsed time, compute/API cost and refresh correctness. Never compare unmatched resolutions or hardware.

Recruit five developers who already ship demos regularly. Ask them to refresh a real demo after a real UI change, then measure whether they use it again on the next release. If refreshes are rare or no faster than re-recording, reconsider the maintenance-first positioning.

## Commercial direction

Use the existing local app and agent connection to acquire users. Test paid demand for maintained demo libraries, team review, scheduled runs and managed rendering after the local workflow proves useful. Meter costly hosted work transparently.

Do not charge a premium solely for MCP access, BYO agent support or generic AI editing. Those are already widely advertised. Keep any proposed pricing separate from demonstrated willingness to pay.

The potential durable advantage is a reliable body of reusable workflows, revision history, editorial intent and benchmarked recovery behavior. It is not an exclusive model, a proprietary protocol, or a claim that nobody else can add the same feature.

## Method and limits

Primary-source research plus bounded repository inspection. No competitor apps were operated, no new binary reverse engineering was performed, no external accounts were changed and no product implementation was modified.

Pricing reflects vendor pages checked on the research date, not checkout. ScreenKite contains expired promotion copy; Tella has older pages with inconsistent credit counts. These conflicts are recorded in profiles rather than silently reconciled.

No traffic estimates, TAM, review consensus or customer demand were inferred. Lint/type checks/application tests are not evidence for this research-only change and were not run; generated document links and patch whitespace were checked.

