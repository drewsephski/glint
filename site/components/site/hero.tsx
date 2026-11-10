import Image from "next/image"
import { ArrowUpRight, Download } from "lucide-react"

import { DOWNLOAD, RELEASE_PAGE, REPO, VERSION } from "@/lib/site"
import { AnimatedShinyText } from "@/components/ui/animated-shiny-text"
import { BlurFade } from "@/components/ui/blur-fade"
import { DotPattern } from "@/components/ui/dot-pattern"
import { InteractiveHoverButton } from "@/components/ui/interactive-hover-button"
import { LightRays } from "@/components/ui/light-rays"
import { NumberTicker } from "@/components/ui/number-ticker"
import { ShimmerButton } from "@/components/ui/shimmer-button"
import { TextAnimate } from "@/components/ui/text-animate"

const stats = [
  { value: 60, suffix: " fps", label: "Capture, up to" },
  { value: 4, suffix: "", label: "Export formats" },
  { value: 4, suffix: "", label: "Canvas shapes" },
  { value: 5.4, suffix: " MB", label: "Download", decimals: 1 },
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
            <p className="text-muted-foreground mt-6 max-w-xl text-lg leading-relaxed text-pretty">
              A native macOS screen recorder that adds the zooms, smooth
              cursor, tighter pacing and captions for you. Your AI agents can
              run every step too.
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
              Apple Silicon, macOS 26 or later. Signed and notarized.
            </p>
          </BlurFade>
        </div>

        <BlurFade
          delay={0.75}
          offset={24}
          direction="up"
          blur="10px"
          className="mix-blend-lighten"
        >
          <Image
            src="/glint/img/gen/hero.jpg"
            alt="The Glint editor: a preview of a dashboard recording, a scene list with narration on the right, and timeline lanes for video, zoom, captions and voice"
            width={2400}
            height={1500}
            priority
            sizes="(min-width: 1280px) 1240px, 100vw"
            className="mx-auto mt-6 w-full max-w-none shot-fade sm:-mx-[4%] sm:w-[108%]"
          />
        </BlurFade>

        <dl className="mt-10 grid grid-cols-2 gap-px overflow-hidden rounded-2xl border bg-white/[0.07] md:grid-cols-4">
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
