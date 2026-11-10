import { Cloud, HardDrive } from "lucide-react"

import { ACCENT, DOWNLOAD, REPO, VERSION } from "@/lib/site"
import { BlurFade } from "@/components/ui/blur-fade"
import { Highlighter } from "@/components/ui/highlighter"

import { CopyButton } from "./copy-button"
import { FaqList, type FaqItem } from "./faq-list"
import { SectionHeading } from "./section-heading"

const link =
  "text-foreground decoration-primary/60 underline underline-offset-4 hover:decoration-primary"
const code = "text-foreground font-mono text-[0.85em]"

/* ---------------------------------------------------------------- Privacy */

const local = [
  "Screen, camera and audio recording",
  "Input tracking: when you type, never which keys",
  "Transcription and captions",
  "Editing, rendering and quality checks",
]

const online = [
  ["Narration script", "Anthropic or OpenAI, with your sign-in"],
  ["Narration voice", "ElevenLabs, with your key"],
  ["Agent chat and connected agents", "That agent’s provider"],
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
        />

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
                Goes online, only if you use it
              </h3>
              <dl className="mt-6 divide-y divide-white/[0.07]">
                {online.map(([what, where]) => (
                  <div
                    key={what}
                    className="flex flex-wrap justify-between gap-x-6 gap-y-1 py-3 first:pt-0"
                  >
                    <dt>{what}</dt>
                    <dd className="text-muted-foreground">{where}</dd>
                  </div>
                ))}
              </dl>
              <p className="text-muted-foreground mt-4 text-sm leading-relaxed">
                API keys live in your macOS Keychain. Agents can&rsquo;t read them.
                Script writing uses your Claude or ChatGPT sign-in, sending scenes
                to Anthropic or OpenAI respectively. An Anthropic API key is also
                supported.
              </p>
            </div>
          </BlurFade>
        </div>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------ Get started */

const requirements = [
  ["Mac", "Apple Silicon"],
  ["macOS", "26 or later"],
  ["Permissions", "Screen Recording"],
  ["Narration script", "Claude or ChatGPT sign-in, or an Anthropic key"],
  ["Narration voice", "Optional, an ElevenLabs key"],
  ["Agent chat", "Optional, Claude Code or Codex"],
]

export function GetStarted() {
  const steps = [
    {
      title: "Install",
      body: (
        <>
          <a href={DOWNLOAD} className={link}>
            Download the DMG
          </a>{" "}
          and drag Glint to Applications.
        </>
      ),
    },
    {
      title: "Record",
      body: "Press ⇧⌘R, or open the demo project to look around first.",
    },
    {
      title: "Polish",
      body: "Click Auto Zoom, Tighten and Captions.",
    },
    {
      title: "Sign in",
      body: "Open Settings › Account for Claude or ChatGPT. Glint can install the tool and guide you through sign-in.",
    },
  ]

  return (
    <section id="start" className="mx-auto max-w-6xl px-6 py-24 sm:py-32">
      <SectionHeading title="Get started" />

      <div className="mt-14 grid gap-12 lg:grid-cols-[1.4fr_1fr] lg:gap-16">
        <ol className="relative space-y-9 before:absolute before:top-2 before:bottom-2 before:left-[0.95rem] before:w-px before:bg-white/10">
          {steps.map((s, i) => (
            <li key={s.title} className="relative flex gap-6">
              <span className="bg-background text-primary relative z-10 flex size-8 shrink-0 items-center justify-center rounded-full border font-mono text-sm">
                {i + 1}
              </span>
              <BlurFade inView delay={0.06 * i}>
                <h3 className="text-lg font-semibold">{s.title}</h3>
                <p className="text-muted-foreground mt-1 leading-relaxed">
                  {s.body}
                </p>
              </BlurFade>
            </li>
          ))}
        </ol>

        <BlurFade inView delay={0.1}>
          <div className="bg-card rounded-2xl border p-7">
            <h3 className="font-semibold">Requirements</h3>
            <dl className="mt-4 divide-y divide-white/[0.07]">
              {requirements.map(([k, v]) => (
                <div key={k} className="grid grid-cols-[7rem_1fr] gap-4 py-3">
                  <dt className="text-muted-foreground text-sm">{k}</dt>
                  <dd className="text-sm">{v}</dd>
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

const included = [
  "Claude and ChatGPT sign-in",
  "Guided CLI installation",
  "Several shots per project",
  "Music and sound effects",
  "Transitions",
  "Callouts",
  "Privacy masks",
  "SRT and WebVTT captions",
  "Transcript editing",
  "Pause and resume",
  "Crash recovery",
  "Demo recipes",
  "Scene refresh",
  "Render jobs",
]

const BUILD = `git clone https://github.com/drewsephski/glint.git
cd glint
scripts/build-app.sh
open build/Glint.app`

export function SourceBuilds() {
  return (
    <section
      id="source-builds"
      className="border-y bg-[#0b0f13] py-24 sm:py-32"
    >
      <div className="mx-auto grid max-w-6xl grid-cols-1 gap-12 px-6 lg:grid-cols-2 lg:gap-16">
        <div>
          <SectionHeading
            note={`Included in ${VERSION}`}
            title="More ways to shape your video"
          >
            Available in the download. You can also build Glint from source.
          </SectionHeading>
          <BlurFade inView delay={0.1}>
            <ul className="mt-8 flex flex-wrap gap-2">
              {included.map((item) => (
                <li
                  key={item}
                  className="bg-background rounded-lg border px-3 py-1.5 text-sm"
                >
                  {item}
                </li>
              ))}
            </ul>
          </BlurFade>
        </div>

        <BlurFade inView delay={0.15} className="min-w-0 self-end">
          <div className="relative rounded-xl border border-white/10 bg-[#0a0d11]">
            <CopyButton text={BUILD} className="absolute top-3 right-3" />
            <pre className="overflow-x-auto p-5 pt-12 font-mono text-[0.8rem] leading-relaxed">
              <code>{BUILD}</code>
            </pre>
          </div>
          <p className="text-muted-foreground mt-4 text-sm leading-relaxed">
            Needs macOS 26 and Xcode 26. Details in the{" "}
            <a href={`${REPO}#quick-start-from-source`} className={link}>
              README
            </a>
            .
          </p>
        </BlurFade>
      </div>
    </section>
  )
}

/* -------------------------------------------------------------------- FAQ */

const faqs: FaqItem[] = [
  {
    q: "Do I need an API key?",
    a: "Not for recording, editing, captions or export. Chat and script writing use your Claude or ChatGPT sign-in, and Glint can install either tool for you. An Anthropic API key is an alternative for script writing. Voice generation needs an ElevenLabs key.",
  },
  {
    q: "Can an agent record my screen without me knowing?",
    a: (
      <>
        Recording, deleting files and sending anything online return an
        approval request, unless your Glint policy already allows that action.
        Only you can approve it, and agent recordings run in Glint.app where
        you can see and stop them. Approvals cover Glint&rsquo;s tools only;
        they are not a security boundary against other software on your Mac.
      </>
    ),
  },
  {
    q: "Which agents work with Glint?",
    a: "Claude Code, Codex and Claude Desktop connect in one click. Cursor, VS Code, Windsurf, Zed and any stdio MCP client use a config snippet.",
  },
  {
    q: "Does it run on Intel Macs or older macOS?",
    a: "No. Glint needs Apple Silicon and macOS 26 or later.",
  },
  {
    q: "Is every feature on GitHub in the download?",
    a: (
      <>
        The download includes the features listed here for {VERSION}. The main
        branch may contain newer changes; see the{" "}
        <a href={`${REPO}/releases`} className={link}>
          release notes
        </a>{" "}
        for what each download includes.
      </>
    ),
  },
  {
    q: "What isn’t there yet?",
    a: (
      <>
        Automatic updates, crossfades, picture-in-picture, device frames and
        automatic detection of sensitive content. The full list is in{" "}
        <a href={`${REPO}/blob/main/docs/GAPS.md`} className={link}>
          docs/GAPS.md
        </a>
        .
      </>
    ),
  },
  {
    q: "Where are my projects stored?",
    a: (
      <>
        In <code className={code}>~/Movies/Glint</code>. Each project is a
        folder of JSON and standard media files.
      </>
    ),
  },
]

export function Faq() {
  return (
    <section id="faq" className="mx-auto max-w-6xl px-6 py-24 sm:py-32">
      <div className="grid gap-12 lg:grid-cols-[1fr_1.8fr] lg:gap-16">
        <SectionHeading title="Questions" />
        <FaqList items={faqs} />
      </div>
    </section>
  )
}
