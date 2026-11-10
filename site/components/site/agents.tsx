import Image from "next/image"
import { Check, Pencil, Send, X } from "lucide-react"

import { ACCENT } from "@/lib/site"
import { AnimatedList } from "@/components/ui/animated-list"
import { BorderBeam } from "@/components/ui/border-beam"
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

export function Agents() {
  return (
    <section id="agents" className="py-24 sm:py-32">
      <div className="mx-auto max-w-6xl px-6">
        <div className="grid items-center gap-12 lg:grid-cols-2 lg:gap-16">
          <SectionHeading title="You and your agent edit the same project">
            The app, the CLI and the MCP server run on one engine. Agent edits
            show up live in your editor, and you can undo them.
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
              <p className="text-muted-foreground mt-5 text-sm leading-relaxed">
                Edits only its own config entry and keeps a backup. For other
                MCP clients, add{" "}
                <code className="text-foreground font-mono text-[0.85em]">
                  --print
                </code>
                .
              </p>
            </div>
          </BlurFade>

          <BlurFade inView delay={0.1} className="min-w-0 lg:col-span-2">
            <div className="bg-card relative flex h-full flex-col rounded-2xl border p-6">
              <BorderBeam size={140} duration={9} colorFrom={ACCENT} colorTo="#ffffff" />
              <h3 className="font-semibold">Every edit has an author</h3>
              <p className="text-muted-foreground mt-2 text-sm leading-relaxed">
                Edits can be undone. Going online waits for your approval.
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

        <BlurFade inView className="mix-blend-lighten">
          <Image
            src="/img/gen/agent.jpg"
            alt="Close-up of the Glint editor: a banner where Claude Code asks to send a script to ElevenLabs with Deny and Approve buttons, and the Agent panel with an auto zoom proposal and the edit history"
            width={1586}
            height={992}
            sizes="(min-width: 1152px) 1100px, 100vw"
            className="mt-4 w-full rounded-2xl [mask-image:radial-gradient(ellipse_80%_80%_at_50%_45%,black_70%,transparent)]"
          />
        </BlurFade>
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
