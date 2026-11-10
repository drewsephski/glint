import Image from "next/image"
import { Download } from "lucide-react"

import { DOWNLOAD, RELEASES, REPO, VERSION } from "@/lib/site"
import { BlurFade } from "@/components/ui/blur-fade"
import { FlickeringGrid } from "@/components/ui/flickering-grid"
import { InteractiveHoverButton } from "@/components/ui/interactive-hover-button"
import { ShimmerButton } from "@/components/ui/shimmer-button"

const nav = [
  { href: "#how", label: "How it works" },
  { href: "#features", label: "Features" },
  { href: "#agents", label: "Agents" },
  { href: "#privacy", label: "Privacy" },
  { href: "#faq", label: "FAQ" },
]

export function Header() {
  return (
    <header className="fixed inset-x-0 top-0 z-40 border-b border-white/[0.06] bg-background/70 backdrop-blur-xl">
      <div className="mx-auto flex h-14 max-w-6xl items-center gap-8 px-6">
        <a
          href="#main"
          className="bg-primary text-primary-foreground sr-only rounded-md px-3 py-1.5 text-sm font-medium focus:not-sr-only focus:absolute focus:top-2 focus:left-2"
        >
          Skip to content
        </a>
        <a href="#" aria-label="Glint home" className="flex items-center gap-2.5">
          <Image src="/icon.svg" alt="" width={26} height={26} unoptimized />
          <span className="text-[1.05rem] font-semibold tracking-tight">
            Glint
          </span>
        </a>
        <nav aria-label="Main" className="hidden md:block">
          <ul className="flex items-center gap-7 text-sm">
            {nav.map((n) => (
              <li key={n.href}>
                <a
                  href={n.href}
                  className="text-muted-foreground hover:text-foreground transition-colors"
                >
                  {n.label}
                </a>
              </li>
            ))}
          </ul>
        </nav>
        <div className="ml-auto flex items-center gap-5">
          <a
            href={REPO}
            className="text-muted-foreground hover:text-foreground hidden text-sm transition-colors sm:block"
          >
            GitHub
          </a>
          <a
            href={DOWNLOAD}
            className="bg-primary text-primary-foreground inline-flex h-8 items-center gap-1.5 rounded-lg px-3 text-sm font-semibold transition-opacity hover:opacity-90"
          >
            <Download className="size-3.5" />
            Download
          </a>
        </div>
      </div>
    </header>
  )
}

const footerLinks = [
  { href: REPO, label: "GitHub" },
  { href: RELEASES, label: "Releases" },
  { href: `${REPO}/blob/main/docs/AGENTS.md`, label: "Agent docs" },
  { href: `${REPO}/blob/main/docs/ARCHITECTURE.md`, label: "Architecture" },
  { href: `${REPO}/blob/main/docs/GAPS.md`, label: "Known gaps" },
  { href: `${REPO}/issues`, label: "Report an issue" },
]

export function Closing() {
  return (
    <>
      <section className="relative overflow-hidden border-t">
        <FlickeringGrid
          className="absolute inset-0 [mask-image:radial-gradient(ellipse_70%_90%_at_50%_100%,black,transparent)]"
          squareSize={3}
          gridGap={7}
          color="#73bdff"
          maxOpacity={0.28}
          flickerChance={0.12}
        />
        <div className="relative mx-auto flex max-w-6xl flex-col items-center px-6 py-28 text-center sm:py-36">
          <BlurFade inView>
            <Image
              src="/icon.svg"
              alt=""
              width={56}
              height={56}
              unoptimized
              className="mx-auto"
            />
            <h2 className="mt-8 text-4xl leading-[1.05] font-semibold tracking-[-0.03em] text-balance sm:text-6xl">
              Try Glint on your next demo
            </h2>
            <div className="mt-9 flex flex-wrap items-center justify-center gap-3">
              <ShimmerButton href={DOWNLOAD}>
                <Download className="size-4" />
                Download Glint {VERSION}
              </ShimmerButton>
              <InteractiveHoverButton href={RELEASES}>
                All releases
              </InteractiveHoverButton>
            </div>
          </BlurFade>
        </div>
      </section>

      <footer className="border-t">
        <div className="mx-auto flex max-w-6xl flex-col gap-6 px-6 py-10 sm:flex-row sm:items-center sm:justify-between">
          <div className="flex items-center gap-2.5">
            <Image src="/icon.svg" alt="" width={22} height={22} unoptimized />
            <span className="font-semibold">Glint</span>
          </div>
          <ul className="text-muted-foreground flex flex-wrap gap-x-6 gap-y-2 text-sm">
            {footerLinks.map((l) => (
              <li key={l.label}>
                <a
                  href={l.href}
                  className="hover:text-foreground transition-colors"
                >
                  {l.label}
                </a>
              </li>
            ))}
          </ul>
        </div>
        <p className="text-muted-foreground mx-auto max-w-6xl px-6 pb-10 text-sm">
          This site uses no cookies or analytics.
        </p>
      </footer>
    </>
  )
}
