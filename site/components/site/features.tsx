import {
  Camera,
  FileCheck2,
  FolderOpen,
  Gauge,
  Keyboard,
  Monitor,
  Undo2,
} from "lucide-react"

import { VERSION } from "@/lib/site"
import { BlurFade } from "@/components/ui/blur-fade"
import { Iphone } from "@/components/ui/iphone"

import { DemoScene, GlintCursor } from "./demo-scene"
import { SectionHeading } from "./section-heading"

const features = [
  {
    icon: Monitor,
    title: "Display or window capture",
    body: "HEVC at up to 60 fps, with system audio and microphone.",
  },
  {
    icon: Camera,
    title: "Facecam",
    badge: "New",
    body: "A camera bubble that follows your cuts and shrinks during zooms.",
  },
  {
    icon: Keyboard,
    title: "Private input tracking",
    body: "Records when you type, never which keys.",
  },
  {
    icon: FileCheck2,
    title: "Export that checks itself",
    body: "H.264, HEVC, ProRes and GIF, each measured after it renders.",
  },
  {
    icon: FolderOpen,
    title: "Non-destructive projects",
    body: "Your media is never modified.",
  },
  {
    icon: Undo2,
    title: "Undo from anyone",
    body: "Every edit has an author and can be reverted on its own.",
  },
  {
    icon: Gauge,
    title: "Quality checks",
    body: "Flags pumping zooms, dead air and rushed captions, each with a fix.",
  },
]

const shapes = [
  { label: "16:9", w: 64, h: 36 },
  { label: "1:1", w: 40, h: 40 },
  { label: "9:16", w: 26, h: 46, active: true },
  { label: "4:3", w: 52, h: 39 },
]

export function Features() {
  return (
    <section id="features" className="border-y bg-[#0b0f13] py-24 sm:py-32">
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading title={`Everything in Glint ${VERSION}`} />

        <div className="bg-background mt-14 grid items-center gap-10 rounded-3xl border p-8 sm:px-12 sm:py-10 md:grid-cols-[1fr_auto] md:gap-16">
          <BlurFade inView>
            <h3 className="text-2xl font-semibold tracking-tight">
              Backgrounds and canvases
            </h3>
            <p className="text-muted-foreground mt-3 max-w-md text-lg leading-relaxed text-pretty">
              Square and vertical exports follow the cursor.
            </p>
            <ul className="mt-8 flex flex-wrap items-end gap-5">
              {shapes.map((s) => (
                <li key={s.label} className="flex flex-col items-center gap-2">
                  <span
                    style={{ width: s.w, height: s.h }}
                    className={
                      s.active
                        ? "border-primary bg-primary/15 rounded-md border"
                        : "rounded-md border border-white/20"
                    }
                  />
                  <span
                    className={
                      s.active
                        ? "text-primary font-mono text-xs"
                        : "text-muted-foreground font-mono text-xs"
                    }
                  >
                    {s.label}
                  </span>
                </li>
              ))}
            </ul>
          </BlurFade>

          <BlurFade inView delay={0.15} className="mx-auto w-48 sm:w-52">
            <Iphone
              role="img"
              aria-label="Illustration of a vertical 9:16 canvas: the recording cropped around the cursor on a gradient background, with a caption below"
            >
              <div className="relative size-full bg-linear-to-br from-[#f29a86] via-[#8e479f] to-[#3b1f5e]">
                <div className="absolute inset-x-[7%] top-[20%] aspect-[4/5] overflow-hidden rounded-lg shadow-[0_12px_30px_rgb(0_0_0/0.45)]">
                  {/* The 16:9 scene, enlarged and shifted to frame the cursor. */}
                  <div className="absolute top-[-24%] left-[-130%] aspect-video w-[300%]">
                    <DemoScene className="bg-none" />
                    <GlintCursor className="absolute top-[50%] left-[60%] w-[3.4%]" />
                  </div>
                </div>
                <span className="absolute inset-x-[7%] bottom-[11%] rounded-lg bg-[#3c3f4a] px-2 py-1.5 text-center text-[0.68rem] leading-snug font-semibold text-white">
                  Here is our <span className="text-[#ffd24a]">quarterly</span>{" "}
                  dashboard.
                </span>
              </div>
            </Iphone>
          </BlurFade>
        </div>

        <ul className="mt-4 grid gap-px overflow-hidden rounded-3xl border bg-white/[0.07] sm:grid-cols-2 lg:grid-cols-4">
          {features.map((f, i) => (
            <li key={f.title} className="bg-background flex">
              <BlurFade inView delay={0.04 * i} className="p-6">
                <f.icon className="text-primary size-5" strokeWidth={1.75} />
                <h3 className="mt-4 flex flex-wrap items-center gap-2 font-semibold">
                  {f.title}
                  {f.badge && (
                    <span className="bg-primary/12 text-primary rounded-md px-1.5 py-0.5 text-xs font-medium">
                      {f.badge}
                    </span>
                  )}
                </h3>
                <p className="text-muted-foreground mt-1.5 text-[0.95rem] leading-relaxed text-pretty">
                  {f.body}
                </p>
              </BlurFade>
            </li>
          ))}
          <li className="bg-background flex items-center p-6">
            <a
              href="#source-builds"
              className="text-muted-foreground hover:text-foreground text-[0.95rem] leading-relaxed transition-colors"
            >
              More is on the way.{" "}
              <span className="text-foreground decoration-primary/60 underline underline-offset-4">
                See source builds
              </span>
            </a>
          </li>
        </ul>
      </div>
    </section>
  )
}
