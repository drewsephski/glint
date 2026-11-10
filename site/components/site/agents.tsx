import Image from "next/image"
import { Check, Pencil, Send, X } from "lucide-react"

import { REPO } from "@/lib/site"
import { AnimatedList } from "@/components/ui/animated-list"
import { BlurFade } from "@/components/ui/blur-fade"
import { Marquee } from "@/components/ui/marquee"
import {
  AnimatedSpan,
  Terminal,
  TypingAnimation,
} from "@/components/ui/terminal"

import { AgentBeam } from "./agent-beam"
import { CopyButton } from "./copy-button"
import { SectionHeading } from "./section-heading"

const CONNECT = "/Applications/Glint.app/Contents/Helpers/glint connect"

const inApp = [
  "Record, or open the demo project to try Glint without any permissions.",
  "Click Auto Zoom, Tighten and Captions, or ask in the editor’s Chat tab: “tighten the pauses and add zooms”.",
  "Preview proposals from planners and agents, then apply or reject them.",
  "When an agent asks Glint to record or send something online, approve or deny it from the banner at the top. If your Glint policy already allows that kind of action, it goes ahead without asking.",
  "Export the formats you need.",
]

const viaAgent = [
  "Connect Claude Code, Codex or Claude Desktop with one click in Glint, or run glint connect.",
  "The agent reads the take: events, transcript, frames and contact sheets.",
  "It applies reversible edits directly, each labelled with the agent’s name and undoable, or proposes cuts, zooms and captions with a reason. It can render and score a proposal before anyone applies it.",
  "It renders each variant and reads the measurements back.",
  "Glint’s recording, delete and online tools return an approval request unless your Glint policy allows them, and agents can’t approve their own requests. This covers Glint’s tools only; the agent’s other tools follow its own permission settings.",
]

const notes = [
  {
    title: "Chat in the editor",
    body: "The Chat tab runs Claude Code or Codex with your existing sign-in, so Glint needs no API key for it. You see its tool calls as they happen. As with any use of those agents, your messages and what the agent reads from the project go to its provider.",
  },
  {
    title: "Recordings stay visible",
    body: "When an agent records, it happens in Glint.app. You see it and can stop it there, and macOS asks for Screen Recording once, for Glint.",
  },
  {
    title: "Agent walkthroughs",
    body: "An agent driving an app can report its clicks and typing, so automation that never moves the real pointer still gets zooms and a natural cursor.",
  },
  {
    title: "One set of tools for MCP and the CLI",
    body: "Recording, editing, narration, rendering and measurement. Source builds have more tools than the release.",
    link: { href: `${REPO}/blob/main/docs/AGENTS.md`, label: "docs/AGENTS.md" },
  },
]

const clients = [
  { name: "Claude Code", how: "One click" },
  { name: "Codex", how: "One click" },
  { name: "Claude Desktop", how: "One click" },
  { name: "Cursor", how: "Config snippet" },
  { name: "VS Code", how: "Config snippet" },
  { name: "Windsurf", how: "Config snippet" },
  { name: "Zed", how: "Config snippet" },
  { name: "Any stdio MCP client", how: "Config snippet" },
]

// The same entries the History panel shows in the screenshot below.
const history = [
  { title: "Marker", author: "Glint", rev: "r1" },
  { title: "Demo voiceover: 2 clips", author: "Glint", rev: "r2" },
  { title: "Fit picture to narration", author: "Glint", rev: "r3" },
  { title: "Captions from the voice", author: "Glint", rev: "r4" },
  { title: "Auto zoom: 1 zoom", author: "claude-code", rev: "proposal" },
]

function Steps({ title, items }: { title: string; items: string[] }) {
  return (
    <div>
      <h3 className="text-lg font-semibold">{title}</h3>
      <ol className="mt-5 space-y-4">
        {items.map((item, i) => (
          <li key={i} className="flex gap-4">
            <span className="text-primary mt-0.5 font-mono text-sm tabular-nums">
              {i + 1}
            </span>
            <span className="text-muted-foreground leading-relaxed text-pretty">
              {item}
            </span>
          </li>
        ))}
      </ol>
    </div>
  )
}

export function Agents() {
  return (
    <section id="agents" className="py-24 sm:py-32">
      <div className="mx-auto max-w-6xl px-6">
        <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-16">
          <SectionHeading title="You and your agent edit the same project">
            The app, the glint command line tool and Glint&rsquo;s MCP server all
            run on one engine. An agent&rsquo;s edit shows up live in the editor
            you have open, and you can undo it like any other.
          </SectionHeading>
          <BlurFade inView delay={0.1}>
            <AgentBeam />
          </BlurFade>
        </div>

        <div className="mt-16 grid grid-cols-1 gap-4 lg:grid-cols-5">
          <BlurFade inView className="min-w-0 lg:col-span-3">
            <div className="bg-card flex h-full min-w-0 flex-col rounded-2xl border p-6">
              <div className="flex items-center justify-between gap-4">
                <h3 className="font-semibold">Connect from the terminal</h3>
                <CopyButton text={CONNECT} />
              </div>
              <Terminal className="mt-5 max-h-none min-w-0 max-w-none flex-1 border-white/10 bg-[#0a0d11] text-[0.8rem] leading-relaxed">
                <TypingAnimation duration={22} className="text-foreground">
                  {`$ ${CONNECT}`}
                </TypingAnimation>
                <AnimatedSpan className="text-primary">
                  ✓ Connected Claude Code for every folder.
                </AnimatedSpan>
                <AnimatedSpan className="text-muted-foreground">
                  {"  New sessions load it. In a running session, type /mcp to reconnect."}
                </AnimatedSpan>
                <AnimatedSpan className="text-primary">
                  ✓ Connected Claude Desktop.
                </AnimatedSpan>
                <AnimatedSpan className="text-muted-foreground">
                  {"  Quit and reopen Claude to load Glint."}
                </AnimatedSpan>
                <AnimatedSpan className="text-muted-foreground whitespace-pre-wrap">
                  {"\nAgents record through Glint.app, so macOS asks once for Screen Recording permission for Glint."}
                </AnimatedSpan>
              </Terminal>
              <p className="text-muted-foreground mt-5 text-sm leading-relaxed text-pretty">
                Glint checks that its server answers before changing any config,
                edits only its own entry and keeps a backup. Cursor, VS Code,
                Windsurf and Zed get a snippet to paste: add{" "}
                <code className="text-foreground font-mono text-[0.85em]">
                  --print
                </code>{" "}
                to the same command. To type plain{" "}
                <code className="text-foreground font-mono text-[0.85em]">
                  glint
                </code>
                , run{" "}
                <code className="text-foreground font-mono text-[0.85em]">
                  glint install-cli
                </code>{" "}
                from the same folder once; it links the tool into{" "}
                <code className="text-foreground font-mono text-[0.85em]">
                  ~/.local/bin
                </code>
                , which needs to be on your PATH.
              </p>
            </div>
          </BlurFade>

          <BlurFade inView delay={0.1} className="min-w-0 lg:col-span-2">
            <div className="bg-card flex h-full flex-col rounded-2xl border p-6">
              <h3 className="font-semibold">Every edit has an author</h3>
              <p className="text-muted-foreground mt-2 text-sm leading-relaxed">
                Reversible edits apply directly. Anything that leaves your Mac
                waits for you.
              </p>

              <div className="mt-5 rounded-xl border border-white/10 bg-[#0a0d11] p-3">
                <div className="flex items-start gap-2.5">
                  <Send className="text-primary mt-0.5 size-4 shrink-0" />
                  <p className="text-sm leading-snug">
                    claude-code asks to: Send the 27-word script (2 scenes) to
                    ElevenLabs
                  </p>
                </div>
                <div className="mt-3 flex justify-end gap-2 text-xs font-medium">
                  <span className="inline-flex items-center gap-1 rounded-md border px-2 py-1">
                    <X className="size-3" /> Deny
                  </span>
                  <span className="bg-primary text-primary-foreground inline-flex items-center gap-1 rounded-md px-2 py-1">
                    <Check className="size-3" /> Approve
                  </span>
                </div>
              </div>

              <div className="relative mt-4 h-[17.5rem] overflow-hidden">
                <AnimatedList delay={1400} className="gap-2">
                  {history.map((h) => (
                    <div
                      key={h.title}
                      className="flex w-full items-center gap-3 rounded-lg border border-white/[0.07] px-3 py-2.5"
                    >
                      <Pencil className="text-muted-foreground size-3.5 shrink-0" />
                      <span className="min-w-0 flex-1 truncate text-sm">
                        {h.title}
                      </span>
                      <span
                        className={
                          h.author === "Glint"
                            ? "text-muted-foreground rounded-md bg-white/[0.06] px-1.5 py-0.5 font-mono text-xs"
                            : "bg-primary/12 text-primary rounded-md px-1.5 py-0.5 font-mono text-xs"
                        }
                      >
                        {h.author}
                      </span>
                      <span className="text-muted-foreground w-14 text-right font-mono text-xs">
                        {h.rev}
                      </span>
                    </div>
                  ))}
                </AnimatedList>
                <div className="from-card pointer-events-none absolute inset-x-0 bottom-0 h-10 bg-linear-to-t to-transparent" />
              </div>
            </div>
          </BlurFade>
        </div>

        <BlurFade inView>
          <figure className="mt-4">
            <div className="bg-card rounded-2xl border p-1.5 sm:p-2">
              <Image
                src="/img/agent.jpg"
                alt="The Glint editor with the Agent tab open: Claude Code has proposed an auto zoom with Preview, Reject and Apply buttons, and a banner at the top asks to approve sending a script to ElevenLabs"
                width={1600}
                height={874}
                sizes="(min-width: 1152px) 1100px, 100vw"
                className="rounded-[0.65rem]"
              />
            </div>
            <figcaption className="text-muted-foreground mt-4 text-center text-sm">
              Screenshot from a release build: Claude Code proposes a zoom and
              asks permission before sending a script to ElevenLabs.
            </figcaption>
          </figure>
        </BlurFade>

        <div className="mt-20 grid gap-12 md:grid-cols-2 md:gap-16">
          <BlurFade inView>
            <Steps title="Working in the app" items={inApp} />
          </BlurFade>
          <BlurFade inView delay={0.1}>
            <Steps title="Working through an agent" items={viaAgent} />
          </BlurFade>
        </div>

        <ul className="mt-20 grid gap-x-12 gap-y-10 border-t pt-12 sm:grid-cols-2">
          {notes.map((n) => (
            <li key={n.title}>
              <h3 className="font-semibold">{n.title}</h3>
              <p className="text-muted-foreground mt-2 leading-relaxed text-pretty">
                {n.body}{" "}
                {n.link && (
                  <>
                    <a
                      href={n.link.href}
                      className="text-foreground decoration-primary/60 underline underline-offset-4"
                    >
                      {n.link.label}
                    </a>{" "}
                    lists the current set.
                  </>
                )}
              </p>
            </li>
          ))}
        </ul>
      </div>

      <div className="relative mt-20">
        <p className="text-muted-foreground mx-auto max-w-6xl px-6 text-sm">
          Works with
        </p>
        <Marquee pauseOnHover className="mt-3 [--duration:36s] [--gap:0.75rem]">
          {clients.map((c) => (
            <span
              key={c.name}
              className="bg-card flex items-center gap-3 rounded-xl border px-4 py-2.5"
            >
              <span className="font-medium">{c.name}</span>
              <span className="text-muted-foreground font-mono text-xs">
                {c.how}
              </span>
            </span>
          ))}
        </Marquee>
        <div className="from-background pointer-events-none absolute inset-y-0 left-0 w-24 bg-linear-to-r to-transparent" />
        <div className="from-background pointer-events-none absolute inset-y-0 right-0 w-24 bg-linear-to-l to-transparent" />
      </div>
    </section>
  )
}
