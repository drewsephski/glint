import Image from "next/image"
import { ArrowUpRight, Download } from "lucide-react"

import { DOWNLOAD, RELEASE_PAGE, REPO, VERSION, ACCENT } from "@/lib/site"
import { AnimatedShinyText } from "@/components/ui/animated-shiny-text"
import { BlurFade } from "@/components/ui/blur-fade"
import { BorderBeam } from "@/components/ui/border-beam"
import { DotPattern } from "@/components/ui/dot-pattern"
import { InteractiveHoverButton } from "@/components/ui/interactive-hover-button"
import { LightRays } from "@/components/ui/light-rays"
import { NumberTicker } from "@/components/ui/number-ticker"
import { ShimmerButton } from "@/components/ui/shimmer-button"
import { TextAnimate } from "@/components/ui/text-animate"

const stats = [
  { value: 60, suffix: " fps", label: "Capture rate, up to" },
  { value: 4, suffix: "", label: "Export formats: H.264, HEVC, ProRes, GIF" },
  { value: 4, suffix: "", label: "Canvas shapes: 16:9, 1:1, 9:16, 4:3" },
  { value: 5.4, suffix: " MB", label: "Disk image size", decimals: 1 },
]

export function Hero() {
  return (
    <section
      aria-labelledby="hero-title"
      className="relative overflow-hidden pt-28 sm:pt-36"
    >
      <LightRays
        color="rgba(115, 189, 255, 0.16)"
        count={6}
        blur={44}
        speed={16}
        length="75vh"
      />
      <DotPattern
        width={22}
        height={22}
        cr={1}
        className="text-white/[0.13] [mask-image:radial-gradient(ellipse_60%_55%_at_50%_30%,black,transparent)]"
      />

      <div className="relative mx-auto max-w-6xl px-6">
        <div className="mx-auto flex max-w-3xl flex-col items-center text-center">
          <BlurFade delay={0.05}>
            <a
              href={RELEASE_PAGE}
              className="bg-card/70 hover:bg-secondary group inline-flex items-center gap-2 rounded-full border px-3.5 py-1.5 text-sm backdrop-blur transition-colors"
            >
              <span className="bg-primary size-1.5 rounded-full" />
              <AnimatedShinyText className="mx-0 max-w-none text-neutral-300/80">
                Glint {VERSION} is out, with facecam
              </AnimatedShinyText>
              <ArrowUpRight className="text-muted-foreground size-3.5 transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
            </a>
          </BlurFade>

          <h1
            id="hero-title"
            className="mt-7 text-[2.6rem] leading-[1.04] font-semibold tracking-[-0.035em] text-balance sm:text-6xl md:text-7xl"
          >
            <TextAnimate
              as="span"
              by="word"
              animation="blurInUp"
              duration={0.5}
              once
              className="block"
            >
              Record a take.
            </TextAnimate>
            <TextAnimate
              as="span"
              by="word"
              animation="blurInUp"
              duration={0.5}
              delay={0.35}
              once
              className="text-primary block"
            >
              Get a finished demo.
            </TextAnimate>
          </h1>

          <BlurFade delay={0.5}>
            <p className="text-muted-foreground mt-6 max-w-2xl text-lg leading-relaxed text-pretty">
              Glint is a native macOS screen recorder and editor. It reads what
              you did on screen and adds zooms, a smooth cursor, tighter pacing
              and captions. Your AI agents can do every one of those steps too,
              and each of their edits is labelled and can be undone.
            </p>
          </BlurFade>

          <BlurFade delay={0.62}>
            <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
              <ShimmerButton href={DOWNLOAD}>
                <Download className="size-4" />
                Download Glint {VERSION}
              </ShimmerButton>
              <InteractiveHoverButton href={REPO}>
                View the source
              </InteractiveHoverButton>
            </div>
            <p className="text-muted-foreground mt-5 text-sm">
              For Apple Silicon Macs on macOS 26 or later. Signed with Developer
              ID and notarized by Apple.
            </p>
          </BlurFade>
        </div>

        <BlurFade delay={0.75} offset={24} direction="up" blur="10px">
          <figure className="mt-16 sm:mt-20">
            <div className="bg-card relative rounded-2xl border p-1.5 shadow-[0_40px_120px_-30px_rgb(0_0_0/0.9)] sm:p-2">
              <Image
                src="/img/editor.jpg"
                alt="The Glint editor: a preview of a dashboard recording, a scene list with narration lines on the right, and timeline lanes for video, zoom, captions and voice"
                width={1600}
                height={874}
                priority
                sizes="(min-width: 1152px) 1100px, 100vw"
                className="rounded-[0.65rem]"
              />
              <BorderBeam
                size={220}
                duration={9}
                colorFrom={ACCENT}
                colorTo="#ffffff"
                borderWidth={1.5}
              />
            </div>
            <figcaption className="text-muted-foreground mt-4 text-center text-sm">
              Screenshot of the Glint editor from a release build: scenes and
              narration on the right, timeline lanes below.
            </figcaption>
          </figure>
        </BlurFade>

        <dl className="mt-16 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border bg-white/[0.07] md:grid-cols-4">
          {stats.map((s) => (
            <div key={s.label} className="bg-background flex flex-col p-6">
              <dt className="text-muted-foreground order-2 mt-2 text-sm leading-snug">
                {s.label}
              </dt>
              <dd className="font-mono text-3xl font-medium tracking-tight tabular-nums sm:text-4xl">
                <NumberTicker
                  value={s.value}
                  decimalPlaces={s.decimals ?? 0}
                  className="text-foreground"
                />
                <span className="text-primary text-xl">{s.suffix}</span>
              </dd>
            </div>
          ))}
        </dl>
      </div>
    </section>
  )
}
