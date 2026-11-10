import Image from "next/image"
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
import { Lens } from "@/components/ui/lens"
import { MagicCard } from "@/components/ui/magic-card"

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

function CursorVisual() {
  return (
    <svg
      viewBox="0 0 320 84"
      className="w-full"
      fill="none"
      aria-hidden
    >
      <path
        d="M8 62 L52 30 L70 58 L118 22 L150 50 L204 26 L236 44 L296 16"
        stroke="rgba(255,255,255,0.18)"
        strokeWidth="1.5"
        strokeDasharray="3 5"
      />
      <path
        d="M8 62 C70 20 110 60 160 40 S250 30 296 16"
        stroke={ACCENT}
        strokeWidth="2"
        strokeLinecap="round"
      />
      <circle cx="296" cy="16" r="9" stroke={ACCENT} strokeOpacity="0.35" />
      <circle cx="296" cy="16" r="3.5" fill={ACCENT} />
    </svg>
  )
}

function CaptionVisual() {
  return (
    <div className="flex justify-center" aria-hidden>
      <span className="rounded-xl bg-[#3c3f4a] px-4 py-2 text-[0.95rem] font-semibold text-white">
        Here is our <span className="text-[#ffd24a]">quarterly</span> dashboard.
      </span>
    </div>
  )
}

function VoiceVisual() {
  const bars = [5, 9, 14, 8, 17, 11, 6, 13, 18, 9, 5, 12, 16, 7, 10, 15, 8, 4]
  return (
    <div className="space-y-3">
      <p className="border-primary/60 border-l-2 pl-3 text-sm leading-relaxed">
        &ldquo;This is the quarterly dashboard. Saving the report takes one
        click.&rdquo;
      </p>
      <div className="flex h-5 items-center gap-[3px]" aria-hidden>
        {bars.map((h, i) => (
          <span
            key={i}
            style={{ height: h }}
            className="bg-primary/60 w-[3px] rounded-full"
          />
        ))}
      </div>
    </div>
  )
}

export function Lanes() {
  return (
    <section id="how" className="mx-auto max-w-6xl px-6 py-24 sm:py-32">
      <SectionHeading title="What Glint adds to a raw take">
        While you record, Glint logs the pointer, clicks and typing next to the
        video. The editor uses that log to build each lane of the timeline.
        Nothing touches your original media.
      </SectionHeading>

      <BentoGrid className="mt-14 auto-rows-auto grid-cols-1 gap-4 md:grid-cols-6">
        <BlurFade inView className="rounded-2xl md:col-span-4 md:row-span-2">
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
              <p className="text-muted-foreground mt-2 max-w-xl leading-relaxed text-pretty">
                Clicks and typing become zooms that start before each action
                and hold after it. Nearby zooms merge or pan instead of pumping
                in and out.
              </p>
              <figure className="mt-6">
                <div className="overflow-hidden rounded-xl border">
                  <Lens zoomFactor={1.9} lensSize={190} ariaLabel="Magnify the rendered frame">
                    <Image
                      src="/img/frame-captions.jpg"
                      alt="A frame rendered by Glint mid camera move: the dashboard is zoomed in with motion blur, on a gradient background, with a caption whose current word is highlighted"
                      width={1280}
                      height={720}
                      sizes="(min-width: 768px) 700px, 100vw"
                    />
                  </Lens>
                </div>
                <figcaption className="text-muted-foreground mt-3 text-sm">
                  A frame rendered by a release build, mid camera move. Hover
                  it to look closer.
                </figcaption>
              </figure>
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
          Silent pauses get shorter, filler words are cut, and silent typing
          and idle waiting speed up.
        </Lane>

        <Lane
          className="md:col-span-2"
          delay={0.16}
          icon={<MousePointer2 className="size-4" />}
          lane="Cursor"
          title="Smooth cursor"
          visual={<CursorVisual />}
        >
          A redrawn cursor that moves smoothly and still lands exactly on each
          click, with click ripples and an idle fade.
        </Lane>

        <Lane
          className="md:col-span-3"
          delay={0.08}
          icon={<Captions className="size-4" />}
          lane="Captions"
          title="Captions"
          visual={<CaptionVisual />}
        >
          Transcribed on your Mac with Apple&rsquo;s speech recognition, split
          into readable lines with the spoken word highlighted.
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
          Glint splits the take into scenes, Claude writes a line for each, and
          an ElevenLabs voice reads them. The picture is retimed to fit each
          line. Uses your own API keys.
        </Lane>
      </BentoGrid>
    </section>
  )
}
