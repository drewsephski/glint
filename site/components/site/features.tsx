import Image from "next/image"
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

import { SectionHeading } from "./section-heading"

const features = [
  {
    icon: Monitor,
    title: "Record a display or a window",
    body: "Captured with ScreenCaptureKit in HEVC at up to 60 fps, with system audio and an optional microphone. Start from the app with ⇧⌘R.",
  },
  {
    icon: Camera,
    title: "Facecam",
    badge: `New in ${VERSION}`,
    body: "Your camera records to its own track and appears as a bubble: circle, square or wide, in any corner. It follows your cuts, shrinks while the screen zooms, and captions move out of its way.",
  },
  {
    icon: Keyboard,
    title: "Private input tracking",
    body: "Glint records when you type, never which keys. Input tracking needs no extra permission.",
  },
  {
    icon: FileCheck2,
    title: "Export that checks itself",
    body: "H.264, HEVC, ProRes and GIF, with loudness normalized toward −16 LUFS. Every output is measured for length, resolution, black or frozen frames, sharpness, loudness and clipping.",
  },
  {
    icon: FolderOpen,
    title: "Non-destructive projects",
    body: "Your media is never modified. A project is an open folder of JSON and standard media files. Deleted recordings go to the Trash, so Finder can put them back.",
  },
  {
    icon: Undo2,
    title: "Undo everything, from anyone",
    body: "Every edit is a transaction with an author. Undo, redo, or revert one earlier change on its own, whether you or an agent made it.",
  },
  {
    icon: Gauge,
    title: "Quality checks before you render",
    body: "Glint flags zooms that pump, a cursor that leaves the frame while zoomed, fast camera moves, dead air and captions that go by too quickly, each with a suggested fix.",
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
    <section
      id="features"
      className="border-y bg-[#0b0f13] py-24 sm:py-32"
    >
      <div className="mx-auto max-w-6xl px-6">
        <SectionHeading title="Everything in the current release">
          These are in Glint {VERSION}, the latest download. Newer features that
          haven&rsquo;t shipped yet are listed under{" "}
          <a
            href="#source-builds"
            className="text-foreground decoration-primary/60 underline underline-offset-4"
          >
            Available in source builds
          </a>
          .
        </SectionHeading>

        <div className="mt-14 grid items-center gap-10 rounded-3xl border bg-background p-8 sm:p-10 md:grid-cols-[1fr_auto] md:gap-16">
          <BlurFade inView>
            <h3 className="text-2xl font-semibold tracking-tight">
              Backgrounds and canvases
            </h3>
            <p className="text-muted-foreground mt-3 max-w-lg text-lg leading-relaxed text-pretty">
              Gradient or image backgrounds, padding, rounded corners and
              shadow. Export 16:9, 1:1, 9:16 or 4:3; square and vertical
              versions follow the cursor.
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

          <BlurFade inView delay={0.15} className="mx-auto w-52 sm:w-60">
            <figure>
              <Iphone>
                <div className="relative size-full bg-linear-to-br from-[#f29a86] via-[#8e479f] to-[#3b1f5e]">
                  <div className="absolute inset-x-[7%] top-[21%] aspect-[340/438] overflow-hidden rounded-lg shadow-[0_12px_30px_rgb(0_0_0/0.45)]">
                    <Image
                      src="/img/frame-captions.jpg"
                      alt="The rendered dashboard frame cropped to a vertical canvas around the cursor"
                      width={1280}
                      height={720}
                      sizes="800px"
                      className="absolute max-w-none"
                      style={{ width: "376.5%", left: "-164.7%", top: "-38.8%" }}
                    />
                  </div>
                  <span className="absolute inset-x-[7%] bottom-[11%] rounded-lg bg-[#3c3f4a] px-2 py-1.5 text-center text-[0.7rem] leading-snug font-semibold text-white">
                    Here is our <span className="text-[#ffd24a]">quarterly</span>{" "}
                    dashboard.
                  </span>
                </div>
              </Iphone>
              <figcaption className="text-muted-foreground mt-4 text-center text-xs leading-relaxed">
                Illustration of a 9:16 canvas, made from the frame above
                cropped around the cursor.
              </figcaption>
            </figure>
          </BlurFade>
        </div>

        <ul className="mt-4 grid gap-px overflow-hidden rounded-3xl border bg-white/[0.07] sm:grid-cols-2 lg:grid-cols-3">
          {features.map((f, i) => (
            <li key={f.title} className="bg-background flex">
              <BlurFade inView delay={0.04 * i} className="p-7">
                <f.icon className="text-primary size-5" strokeWidth={1.75} />
                <h3 className="mt-4 flex flex-wrap items-center gap-2 font-semibold">
                  {f.title}
                  {f.badge && (
                    <span className="bg-primary/12 text-primary rounded-md px-1.5 py-0.5 text-xs font-medium">
                      {f.badge}
                    </span>
                  )}
                </h3>
                <p className="text-muted-foreground mt-2 text-[0.95rem] leading-relaxed text-pretty">
                  {f.body}
                </p>
              </BlurFade>
            </li>
          ))}
          <li className="bg-background hidden items-center justify-center p-7 sm:flex sm:col-span-1 lg:col-span-2">
            <p className="text-muted-foreground max-w-sm text-center text-sm leading-relaxed">
              Recording, editing and export run on your Mac. See{" "}
              <a
                href="#privacy"
                className="text-foreground decoration-primary/60 underline underline-offset-4"
              >
                what stays local and what doesn&rsquo;t
              </a>
              .
            </p>
          </li>
        </ul>
      </div>
    </section>
  )
}
