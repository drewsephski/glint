"use client"

import { useRef, type RefObject } from "react"
import Image from "next/image"
import { AppWindow, Bot, SquareTerminal } from "lucide-react"

import { cn } from "@/lib/utils"
import { ACCENT } from "@/lib/site"
import { AnimatedBeam } from "@/components/ui/animated-beam"

function Node({
  ref,
  label,
  note,
  icon,
  className,
}: {
  ref: RefObject<HTMLDivElement | null>
  label: string
  note: string
  icon: React.ReactNode
  className?: string
}) {
  return (
    <div
      ref={ref}
      className={cn(
        "bg-card relative z-10 flex w-36 items-center gap-2.5 rounded-xl border px-3 py-2.5 sm:w-48 sm:px-3.5",
        className
      )}
    >
      <span className="text-primary shrink-0">{icon}</span>
      <span className="min-w-0">
        <span className="block truncate text-sm font-medium">{label}</span>
        <span className="text-muted-foreground block truncate text-xs">
          {note}
        </span>
      </span>
    </div>
  )
}

/** The app, the CLI and MCP agents all drive one engine and one project. */
export function AgentBeam() {
  const container = useRef<HTMLDivElement>(null)
  const app = useRef<HTMLDivElement>(null)
  const cli = useRef<HTMLDivElement>(null)
  const mcp = useRef<HTMLDivElement>(null)
  const engine = useRef<HTMLDivElement>(null)
  const project = useRef<HTMLDivElement>(null)

  const beam = {
    containerRef: container,
    pathColor: "#ffffff",
    pathOpacity: 0.12,
    pathWidth: 1.5,
    gradientStartColor: ACCENT,
    gradientStopColor: "#ffffff",
  }

  return (
    <div
      ref={container}
      className="relative flex items-center justify-between gap-4 overflow-hidden py-2"
      role="img"
      aria-label="The Glint app, the glint command line tool and MCP agents all run on one engine that edits one project."
    >
      <div className="flex flex-col gap-4">
        <Node
          ref={app}
          label="Glint.app"
          note="You, in the editor"
          icon={<AppWindow className="size-4" />}
        />
        <Node
          ref={cli}
          label="glint CLI"
          note="Scripts and terminals"
          icon={<SquareTerminal className="size-4" />}
        />
        <Node
          ref={mcp}
          label="MCP server"
          note="Claude Code, Codex"
          icon={<Bot className="size-4" />}
        />
      </div>

      <div
        ref={engine}
        className="bg-card relative z-10 flex size-20 shrink-0 flex-col items-center justify-center gap-1 rounded-2xl border sm:size-24"
      >
        <Image src="/glint/icon.svg" alt="" width={36} height={36} unoptimized />
        <span className="text-muted-foreground text-[0.7rem]">Engine</span>
      </div>

      <div
        ref={project}
        className="bg-card relative z-10 hidden w-44 rounded-xl border p-3.5 sm:block"
      >
        <span className="block text-sm font-medium">One project</span>
        <span className="text-muted-foreground mt-1 block text-xs leading-relaxed">
          Every edit is a transaction with an author, so anyone can undo it.
        </span>
      </div>

      <AnimatedBeam {...beam} fromRef={app} toRef={engine} curvature={-40} />
      <AnimatedBeam {...beam} fromRef={cli} toRef={engine} delay={0.6} />
      <AnimatedBeam
        {...beam}
        fromRef={mcp}
        toRef={engine}
        curvature={40}
        delay={1.2}
      />
      {/* The project node is hidden on phones, so its beam is too. */}
      <div className="hidden sm:block">
        <AnimatedBeam {...beam} fromRef={engine} toRef={project} delay={0.3} />
      </div>
    </div>
  )
}
