"use client"

import { useState } from "react"
import { AnimatePresence, motion } from "motion/react"

import { ACCENT } from "@/lib/site"
import { Pointer } from "@/components/ui/pointer"

import { GlintCursor } from "./demo-scene"

interface Click {
  id: number
  x: number
  y: number
}

/**
 * A pad where the visitor's own pointer is replaced by Glint's redrawn cursor:
 * it eases after the mouse, and each click leaves a ripple at the exact spot.
 */
export function CursorPad() {
  const [clicks, setClicks] = useState<Click[]>([])

  function ripple(e: React.MouseEvent<HTMLDivElement>) {
    const r = e.currentTarget.getBoundingClientRect()
    const click = { id: Date.now(), x: e.clientX - r.left, y: e.clientY - r.top }
    setClicks((c) => [...c.slice(-4), click])
    setTimeout(
      () => setClicks((c) => c.filter((k) => k.id !== click.id)),
      800
    )
  }

  return (
    <div
      onClick={ripple}
      className="relative h-36 overflow-hidden rounded-xl border border-white/10 bg-[#0a0d11]"
    >
      <svg
        viewBox="0 0 320 120"
        preserveAspectRatio="none"
        className="absolute inset-0 size-full"
        fill="none"
        aria-hidden
      >
        <path
          d="M10 92 L54 44 L74 84 L122 30 L154 72 L208 38 L240 62 L306 22"
          stroke="rgba(255,255,255,0.16)"
          strokeWidth="1.5"
          strokeDasharray="3 5"
          vectorEffect="non-scaling-stroke"
        />
        <path
          d="M10 92 C74 30 114 86 164 56 S254 44 306 22"
          stroke={ACCENT}
          strokeWidth="2"
          strokeLinecap="round"
          vectorEffect="non-scaling-stroke"
        />
      </svg>

      <span className="text-muted-foreground absolute bottom-2.5 left-3 font-mono text-[0.7rem] [@media(hover:none)]:hidden">
        Move and click in here
      </span>

      <AnimatePresence>
        {clicks.map((c) => (
          <motion.span
            key={c.id}
            className="border-primary pointer-events-none absolute size-10 rounded-full border-2"
            style={{ left: c.x - 20, top: c.y - 20 }}
            initial={{ scale: 0.2, opacity: 0.9 }}
            animate={{ scale: 1.5, opacity: 0 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.7, ease: "easeOut" }}
          />
        ))}
      </AnimatePresence>

      <Pointer spring={{ stiffness: 170, damping: 20, mass: 0.7 }}>
        {/* Offset so the arrow's tip, not its centre, sits on the pointer. */}
        <GlintCursor className="size-8 translate-x-[36%] translate-y-[40%] drop-shadow-[0_2px_4px_rgb(0_0_0/0.5)]" />
      </Pointer>
    </div>
  )
}
