import {
  AudioLines,
  Captions,
  MousePointer2,
  Scissors,
  ZoomIn,
} from "lucide-react"

import { cn } from "@/lib/utils"
import { ACCENT } from "@/lib/site"
import { BentoGrid } from "@/components/ui/bento-grid"
import { BlurFade } from "@/components/ui/blur-fade"
import { MagicCard } from "@/components/ui/magic-card"

import { AutoZoom } from "./auto-zoom"
import { CaptionDemo } from "./caption-demo"
import { CursorPad } from "./cursor-pad"
import { SectionHeading } from "./section-heading"

function Lane({
  icon,
  lane,
  title,
  badge,
  children,
  visual,
  className,
  delay,
}: {
  icon: React.ReactNode
  lane: string
  title: string
  badge?: string
  children: React.ReactNode
  visual?: React.ReactNode
  className?: string
  delay: number
}) {
  return (
    <BlurFade inView delay={delay} className={cn("rounded-2xl", className)}>
      <MagicCard
        className="h-full rounded-2xl"
        gradientFrom={ACCENT}
        gradientTo="#ffffff"
        gradientColor="#1b2530"
        gradientSize={260}
      >
        <div className="flex h-full flex-col p-6">
          <div className="text-muted-foreground flex items-center gap-2 font-mono text-xs">
            <span className="text-primary">{icon}</span>
            {lane} lane
          </div>
          <h3 className="mt-4 flex items-center gap-2 text-xl font-semibold tracking-tight">
            {title}
            {badge && (
              <span className="text-muted-foreground rounded-md border px-1.5 py-0.5 text-xs font-normal">
                {badge}
              </span>
            )}
          </h3>
          <p className="text-muted-foreground mt-2 leading-relaxed text-pretty">
            {children}
          </p>
          {visual && <div className="mt-auto pt-6">{visual}</div>}
        </div>
      </MagicCard>
    </BlurFade>
  )
}

/** A take before and after Tighten: the same clips with the gaps closed. */
function TightenVisual() {
  const before = [22, 9, 16, 12, 20]
  return (
    <div className="space-y-2.5 font-mono text-[0.7rem]" aria-hidden>
      {(["Raw take", "Tightened"] as const).map((label, row) => (
        <div key={label} className="flex items-center gap-3">
          <span className="text-muted-foreground w-16 shrink-0">{label}</span>
          <div
            className={cn(
              "flex h-6 items-stretch",
              row === 0 ? "w-full gap-[6%]" : "w-[78%] gap-[1.5%]"
            )}
          >
            {before.map((w, i) => (
              <span
                key={i}
                style={{ flexGrow: w }}
                className={cn(
                  "rounded-[3px]",
                  row === 0 ? "bg-white/15" : "bg-primary/70"
                )}
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  )
}

/** The scene list from the editor: one narration line per scene. */
function VoiceVisual() {
  const scenes = [
    {
      name: "“Save”",
      time: "0:00 – 0:02",
      line: "This is the quarterly dashboard. Saving the report takes one click.",
      bars: [5, 9, 14, 8, 17, 11, 6, 13, 18, 9, 5, 12],
    },
    {
      name: "Search",
      time: "0:02 – 0:09",
      line: "Search narrows the view to enterprise customers in Europe.",
      bars: [7, 12, 6, 15, 10, 18, 8, 13, 5, 16, 11, 7, 14, 9, 17, 6, 12, 8],
    },
  ]
  return (
    <ul className="space-y-2">
      {scenes.map((s) => (
        <li
          key={s.name}
          className="rounded-xl border border-white/10 bg-[#0a0d11] p-3.5"
        >
          <div className="flex items-center justify-between font-mono text-xs">
            <span className="text-foreground">{s.name}</span>
            <span className="text-muted-foreground">{s.time}</span>
          </div>
          <p className="mt-2 text-sm leading-relaxed">{s.line}</p>
          <div className="mt-3 flex h-5 items-center gap-[3px]" aria-hidden>
            {s.bars.map((h, i) => (
              <span
                key={i}
                style={{ height: h }}
                className="w-[3px] rounded-full bg-[#9b7be0]"
              />
            ))}
          </div>
        </li>
      ))}
    </ul>
  )
}

export function Lanes() {
  return (
    <section id="how" className="mx-auto max-w-6xl px-6 py-24 sm:py-32">
      <SectionHeading title="What Glint adds to a raw take">
        Glint logs your pointer, clicks and typing as you record, then builds
        the edit from that log.
      </SectionHeading>

      <BentoGrid className="mt-14 auto-rows-auto grid-cols-1 gap-4 md:grid-cols-6">
        <BlurFade inView className="min-w-0 rounded-2xl md:col-span-4 md:row-span-2">
          <MagicCard
            className="h-full rounded-2xl"
            gradientFrom={ACCENT}
            gradientTo="#ffffff"
            gradientColor="#1b2530"
            gradientSize={320}
          >
            <div className="flex h-full flex-col p-6">
              <div className="text-muted-foreground flex items-center gap-2 font-mono text-xs">
                <ZoomIn className="text-primary size-4" />
                Zoom lane
              </div>
              <h3 className="mt-4 text-xl font-semibold tracking-tight">
                Auto zoom
              </h3>
              <p className="text-muted-foreground mt-2 leading-relaxed">
                Eases in before each action, holds, and pans between nearby
                ones.
              </p>
              <div className="mt-auto pt-6">
                <AutoZoom />
              </div>
            </div>
          </MagicCard>
        </BlurFade>

        <Lane
          className="md:col-span-2"
          delay={0.08}
          icon={<Scissors className="size-4" />}
          lane="Video"
          title="Tighten"
          visual={<TightenVisual />}
        >
          Shorter pauses, no filler words.
        </Lane>

        <Lane
          className="md:col-span-2"
          delay={0.16}
          icon={<MousePointer2 className="size-4" />}
          lane="Cursor"
          title="Smooth cursor"
          visual={<CursorPad />}
        >
          Redrawn to glide, and still land exactly on each click.
        </Lane>

        <Lane
          className="md:col-span-3"
          delay={0.08}
          icon={<Captions className="size-4" />}
          lane="Captions"
          title="Captions"
          visual={<CaptionDemo />}
        >
          Transcribed on your Mac, with the spoken word highlighted.
        </Lane>

        <Lane
          className="md:col-span-3"
          delay={0.16}
          icon={<AudioLines className="size-4" />}
          lane="Voice"
          title="Narration"
          badge="Optional"
          visual={<VoiceVisual />}
        >
          Claude writes a line per scene and an ElevenLabs voice reads it. Uses
          your own keys.
        </Lane>
      </BentoGrid>
    </section>
  )
}
