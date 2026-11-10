import { ChevronDown, Cloud, HardDrive } from "lucide-react"

import { DOWNLOAD, RELEASE_PAGE, RELEASES, REPO, VERSION, ACCENT } from "@/lib/site"
import { BlurFade } from "@/components/ui/blur-fade"
import { Highlighter } from "@/components/ui/highlighter"

import { CopyButton } from "./copy-button"
import { SectionHeading } from "./section-heading"

const link =
  "text-foreground decoration-primary/60 underline underline-offset-4 hover:decoration-primary"
const code = "text-foreground font-mono text-[0.85em]"

/* ---------------------------------------------------------------- Privacy */

const local = [
  "Screen, camera and audio recording",
  "Pointer and click tracking, and keystroke timing (never the keys)",
  "Transcription and captions",
  "Scene detection and on-screen text reading for narration",
  "Editing, rendering and quality checks",
]

const online = [
  {
    to: "Narration script, to Anthropic",
    body: "A frame from each scene, its on-screen text, the actions you took, any recorded speech and your brief, so Claude can write the lines. Uses your Anthropic key.",
  },
  {
    to: "Narration voice, to ElevenLabs",
    body: "Only the script, so a voice can read it. Uses your ElevenLabs key.",
  },
  {
    to: "Agent chat and connected agents, to that agent’s provider",
    body: "When you use the Chat tab or connect Claude Code, Codex or another agent, your messages, the project context it reads, the results of the Glint tools it calls and any frames it asks for go to the provider behind that agent, under your account with them.",
  },
]

export function Privacy() {
  return (
    <section id="privacy" className="border-y bg-[#0b0f13] py-24 sm:py-32">
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading
          title={
            <>
              Runs on your Mac. Online{" "}
              <Highlighter
                action="underline"
                color={ACCENT}
                strokeWidth={2}
                animationDuration={900}
                iterations={1}
                padding={3}
                isView
              >
                only when you choose.
              </Highlighter>
            </>
          }
        >
          Recording, zooms, cuts, captions and export all run locally. Two
          optional features send data off your Mac: narration, through your own
          Anthropic and ElevenLabs accounts, and working with an AI agent,
          through the agent&rsquo;s own provider.
        </SectionHeading>

        <div className="mt-14 grid gap-4 md:grid-cols-2">
          <BlurFade inView>
            <div className="bg-background h-full rounded-2xl border p-7">
              <h3 className="flex items-center gap-2.5 text-lg font-semibold">
                <HardDrive className="text-primary size-5" strokeWidth={1.75} />
                Stays on your Mac
              </h3>
              <ul className="mt-6 space-y-3.5">
                {local.map((item) => (
                  <li key={item} className="flex gap-3 leading-relaxed">
                    <span className="bg-primary mt-[0.6rem] size-1.5 shrink-0 rounded-full" />
                    {item}
                  </li>
                ))}
              </ul>
            </div>
          </BlurFade>
          <BlurFade inView delay={0.1}>
            <div className="bg-background h-full rounded-2xl border p-7">
              <h3 className="flex items-center gap-2.5 text-lg font-semibold">
                <Cloud
                  className="text-muted-foreground size-5"
                  strokeWidth={1.75}
                />
                Leaves your Mac only when you use these
              </h3>
              <ul className="mt-6 space-y-5">
                {online.map((item) => (
                  <li key={item.to}>
                    <p className="font-medium">{item.to}</p>
                    <p className="text-muted-foreground mt-1 text-[0.95rem] leading-relaxed text-pretty">
                      {item.body}
                    </p>
                  </li>
                ))}
              </ul>
            </div>
          </BlurFade>
        </div>

        <p className="text-muted-foreground mt-8 max-w-3xl leading-relaxed text-pretty">
          You add narration keys in Glint › Settings › Narration. They are
          stored in your macOS Keychain, are not part of the app, and agents
          can&rsquo;t read or set them. When an agent asks Glint to call
          Anthropic or ElevenLabs, Glint asks you first unless your Glint policy
          already allows online calls. Glint can&rsquo;t limit what an agent
          sends through its own tools or to its own provider; that is set in the
          agent&rsquo;s settings.
        </p>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------ Get started */

const requirements = [
  ["Mac", "Apple Silicon (M1 or later)"],
  ["macOS", "macOS 26 or later"],
  ["Permissions", "Screen Recording. Camera and microphone are optional."],
  ["Narration", "Optional. Your own Anthropic and ElevenLabs API keys."],
  ["Agent chat", "Optional. Claude Code or Codex installed and signed in."],
]

export function GetStarted() {
  const steps = [
    {
      title: "Download and install",
      body: (
        <>
          <a href={DOWNLOAD} className={link}>
            Download Glint-{VERSION}.dmg
          </a>
          , open it and drag Glint to Applications. A ZIP and SHA-256 checksums
          are on the{" "}
          <a href={RELEASE_PAGE} className={link}>
            release page
          </a>
          .
        </>
      ),
    },
    {
      title: "Open Glint",
      body: "A short setup runs the first time. macOS asks for Screen Recording permission when you first record, and for camera or microphone access only if you turn them on.",
    },
    {
      title: "Make your first demo",
      body: "Press ⇧⌘R to record, or click Demo project to explore a sample. Then try Auto Zoom, Tighten and Captions.",
    },
    {
      title: "Connect your agents",
      body: "Home › Agents has a Connect button for Claude Code, Codex and Claude Desktop.",
    },
  ]

  return (
    <section id="start" className="mx-auto max-w-6xl px-6 py-24 sm:py-32">
      <SectionHeading title="Get started" />

      <div className="mt-14 grid gap-12 lg:grid-cols-[1.4fr_1fr] lg:gap-16">
        <ol className="relative space-y-10 before:absolute before:top-2 before:bottom-2 before:left-[0.95rem] before:w-px before:bg-white/10">
          {steps.map((s, i) => (
            <li key={s.title} className="relative flex gap-6">
              <span className="bg-background text-primary relative z-10 flex size-8 shrink-0 items-center justify-center rounded-full border font-mono text-sm">
                {i + 1}
              </span>
              <BlurFade inView delay={0.06 * i}>
                <h3 className="text-lg font-semibold">{s.title}</h3>
                <p className="text-muted-foreground mt-1.5 leading-relaxed text-pretty">
                  {s.body}
                </p>
              </BlurFade>
            </li>
          ))}
        </ol>

        <BlurFade inView delay={0.1}>
          <div className="bg-card rounded-2xl border p-7">
            <h3 className="font-semibold">System requirements</h3>
            <dl className="mt-5 divide-y divide-white/[0.07]">
              {requirements.map(([k, v]) => (
                <div key={k} className="grid grid-cols-[7rem_1fr] gap-4 py-3">
                  <dt className="text-muted-foreground text-sm">{k}</dt>
                  <dd className="text-sm leading-relaxed">{v}</dd>
                </div>
              ))}
            </dl>
          </div>
        </BlurFade>
      </div>
    </section>
  )
}

/* ---------------------------------------------------------- Source builds */

const sourceGroups = [
  {
    title: "Editing",
    items: [
      "Several shots in one project: import movies, then append, insert, split, reorder, trim or remove them. Edits stay on their content when shots move, and shots of another shape are letterboxed.",
      "A music bed that loops, fades and lowers itself under narration, your own recorded voiceover, and sound effects.",
      "Dip-to-black or dip-to-white transitions, including fade in and fade out.",
      "Callouts: text labels, arrows, boxes and spotlight highlights that zoom with the screen, drawn and adjusted right on the preview.",
      "Privacy masks (pixelate, blur or solid) for a time range, placed by you or an agent and drawn into the preview, stills, GIFs and every export.",
      "Captions export to SRT and WebVTT timed to the edited video, and can be imported. Choose font, weight, size, colours and position.",
      "Cut words straight from the transcript, or every occurrence of a phrase.",
      "Reusable style presets, timeline trim handles, snapping, and a keyboard shortcut sheet (⌘/).",
    ],
  },
  {
    title: "Recording",
    items: [
      "Pause and resume a take. Screen, audio, camera and input stay in sync with no gap.",
      "Crash recovery: takes are written in 2-second fragments, so an interrupted take can be rebuilt from Home or with glint recover. Up to about the last 2 seconds can be lost.",
      "A preflight check before each take covers permission, source, microphone and camera, folder and disk space, with a fix for each problem.",
      "Window recordings follow a window that is moved during the take.",
    ],
  },
  {
    title: "Agents",
    items: [
      "Demo recipes: versioned scenes with stable IDs, steps and expected outcomes. Your agent drives the app; Glint records and checks.",
      "Evidence for each outcome: verified, failed or needs review. A click never counts as proof. Glint checks on-screen text itself with on-device OCR; other outcomes need a check from the agent or a person.",
      "Scene refresh: after a product change, re-record one scene and swap it in. Your manual edits outside that scene are kept.",
      "Render and production jobs with progress, cancel and retry. A job runs inside the app, CLI or MCP server that started it and saves a checkpoint after each stage. If that process quits or crashes, retrying the job continues after the last completed stage.",
      "A production job only succeeds when every check passes. Otherwise it lists what needs review.",
    ],
  },
]

const BUILD = `git clone https://github.com/drewsephski/glint.git
cd glint
scripts/build-app.sh
open build/Glint.app
build/Glint.app/Contents/Helpers/glint install-cli
build/Glint.app/Contents/Helpers/glint connect`

export function SourceBuilds() {
  return (
    <section
      id="source-builds"
      className="border-y bg-[#0b0f13] py-24 sm:py-32"
    >
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading
          note={`Source builds only · not in the ${VERSION} download`}
          title="Available in source builds"
        >
          These features are on Glint&rsquo;s main branch and are coming in the
          next release. The Glint {VERSION} download doesn&rsquo;t include them.
          To use them now, build Glint from source with the steps below. The
          screenshots on this page come from release builds and don&rsquo;t show
          these features.
        </SectionHeading>

        <div className="mt-14 grid grid-cols-1 gap-4 lg:grid-cols-3">
          {sourceGroups.map((g, i) => (
            <BlurFade key={g.title} inView delay={0.08 * i}>
              <div className="bg-background h-full rounded-2xl border p-7">
                <h3 className="text-lg font-semibold">{g.title}</h3>
                <ul className="mt-5 space-y-3.5">
                  {g.items.map((item) => (
                    <li
                      key={item}
                      className="text-muted-foreground flex gap-3 text-[0.95rem] leading-relaxed text-pretty"
                    >
                      <span className="mt-[0.6rem] size-1 shrink-0 rounded-full bg-white/30" />
                      {item}
                    </li>
                  ))}
                </ul>
              </div>
            </BlurFade>
          ))}
        </div>

        <BlurFade inView>
          <div className="bg-background mt-4 grid grid-cols-1 gap-8 rounded-2xl border p-7 lg:grid-cols-2 lg:gap-12">
            <div>
              <h3 className="text-lg font-semibold">Build from source</h3>
              <p className="text-muted-foreground mt-3 leading-relaxed">
                Needs an Apple Silicon Mac with macOS 26 and Xcode 26 (Swift 6.2
                or later).
              </p>
              <p className="text-muted-foreground mt-4 text-[0.95rem] leading-relaxed text-pretty">
                <code className={code}>install-cli</code> links{" "}
                <code className={code}>glint</code> into{" "}
                <code className={code}>~/.local/bin</code> (add it to your PATH
                if it isn&rsquo;t already), and{" "}
                <code className={code}>connect</code> points Claude Code, Codex
                and Claude Desktop at this build. A source build is signed ad
                hoc rather than notarized, so macOS may ask for Screen Recording
                permission again after a rebuild. See the{" "}
                <a href={`${REPO}#quick-start-from-source`} className={link}>
                  README
                </a>{" "}
                for the full quick start and the new commands.
              </p>
            </div>
            <div className="relative min-w-0 rounded-xl border border-white/10 bg-[#0a0d11]">
              <CopyButton text={BUILD} className="absolute top-3 right-3" />
              <pre className="overflow-x-auto p-5 pt-12 font-mono text-[0.8rem] leading-relaxed sm:pt-5">
                <code>{BUILD}</code>
              </pre>
            </div>
          </div>
        </BlurFade>
      </div>
    </section>
  )
}

/* -------------------------------------------------------------------- FAQ */

export function Faq() {
  const faqs: { q: string; a: React.ReactNode }[] = [
    {
      q: "Do I need an API key?",
      a: "Not for recording, editing, captions or export. Narration needs your own Anthropic key to write the script and an ElevenLabs key for the voice. You can also write the narration lines yourself. The editor’s Chat tab uses your existing Claude Code or Codex sign-in instead of a key, and what you send there goes to that agent’s provider.",
    },
    {
      q: "Can an agent record my screen without me knowing?",
      a: (
        <>
          When an agent uses Glint&rsquo;s tools to start a recording, delete or
          overwrite files, or send something online, Glint returns an approval
          request, unless your Glint policy already allows that kind of action.
          You approve it in the Glint app, or with{" "}
          <code className={code}>glint approve</code> in an interactive
          terminal; agents can&rsquo;t approve their own requests. Agent
          recordings normally run in Glint.app, where you can see and stop them.
          Reversible edits don&rsquo;t need approval: they&rsquo;re labelled
          with the agent&rsquo;s name and you can undo them. Approvals only
          cover Glint&rsquo;s tools, not anything an agent does with its own
          tools. They stop well-behaved agents from acting alone and are not a
          security boundary against other software running as your user.
        </>
      ),
    },
    {
      q: "Which agents work with Glint?",
      a: "Claude Code, Codex (CLI, IDE extension and app) and Claude Desktop connect with one click. Cursor, VS Code, Windsurf and Zed work through a config snippet Glint gives you. Any MCP client that runs a stdio server can use it.",
    },
    {
      q: "Does it work on Intel Macs or older macOS versions?",
      a: "No. Glint needs an Apple Silicon Mac running macOS 26 or later. It relies on the speech recognition and SwiftUI features in macOS 26.",
    },
    {
      q: "Is every feature on GitHub in the download?",
      a: (
        <>
          No. The download is the latest tagged release, currently {VERSION}.
          The main branch already has newer features, such as several shots per
          project, music, callouts, privacy masks, SRT and WebVTT captions,
          pause and resume, crash recovery, recipes and jobs. They&rsquo;re
          listed under{" "}
          <a href="#source-builds" className={link}>
            Available in source builds
          </a>{" "}
          and are only in apps you build from source until the next release.
          The{" "}
          <a href={RELEASES} className={link}>
            release notes
          </a>{" "}
          say what each version includes.
        </>
      ),
    },
    {
      q: "What isn’t there yet?",
      a: (
        <>
          The {VERSION} download doesn&rsquo;t have callouts, masks,
          transitions, several shots per project, music, SRT or WebVTT export,
          pause and resume, or crash recovery; those are in{" "}
          <a href="#source-builds" className={link}>
            source builds
          </a>
          . Neither the release nor source builds have automatic updates,
          crossfades, picture-in-picture, device frames, transcription of
          imported clips, or automatic detection of sensitive content (masks are
          placed by a person or agent). Glint doesn&rsquo;t explore or drive
          apps by itself. For the facecam, dragging the bubble and full-screen
          or side-by-side layouts aren&rsquo;t done yet. The full list for the
          current source is in{" "}
          <a href={`${REPO}/blob/main/docs/GAPS.md`} className={link}>
            docs/GAPS.md
          </a>
          .
        </>
      ),
    },
    {
      q: "Do render jobs keep running if Glint quits?",
      a: "Jobs are only in source builds. A job runs inside the app, CLI or MCP server that started it; there’s no separate background service. If that process quits or crashes, the job shows as interrupted. It saves a checkpoint after each stage, so retrying it continues after the last completed stage instead of starting over.",
    },
    {
      q: "Where are my projects stored?",
      a: (
        <>
          New recordings go to <code className={code}>~/Movies/Glint</code>.
          Each project is a folder of JSON files and standard media you can open
          in other tools.
        </>
      ),
    },
  ]

  return (
    <section id="faq" className="mx-auto max-w-6xl px-6 py-24 sm:py-32">
      <div className="grid gap-12 lg:grid-cols-[1fr_1.8fr] lg:gap-16">
        <SectionHeading title="Questions" />
        <div className="divide-y divide-white/[0.08] border-y border-white/[0.08]">
          {faqs.map((f) => (
            <details key={f.q} className="group">
              <summary className="hover:text-primary flex cursor-pointer list-none items-center justify-between gap-6 py-5 text-lg font-medium transition-colors outline-none focus-visible:text-primary [&::-webkit-details-marker]:hidden">
                {f.q}
                <ChevronDown className="text-muted-foreground size-5 shrink-0 transition-transform duration-200 group-open:rotate-180" />
              </summary>
              <p className="text-muted-foreground max-w-2xl pb-6 leading-relaxed text-pretty">
                {f.a}
              </p>
            </details>
          ))}
        </div>
      </div>
    </section>
  )
}
