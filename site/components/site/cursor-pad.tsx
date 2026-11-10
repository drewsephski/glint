"use client"

import { useEffect, useState } from "react"
import {
  AnimatePresence,
  motion,
  useMotionTemplate,
  useReducedMotion,
  useSpring,
} from "motion/react"

import { cn } from "@/lib/utils"
import { Pointer } from "@/components/ui/pointer"

import { GlintCursor } from "./demo-scene"

interface Click {
  id: number
  x: number
  y: number
}

// Things to click, placed in percent of the pad.
const TARGETS = [
  { label: "Auto Zoom", x: 20, y: 30 },
  { label: "Tighten", x: 74, y: 24 },
  { label: "Captions", x: 36, y: 74 },
  { label: "Export", x: 82, y: 70 },
]

const GLIDE = { stiffness: 70, damping: 16, mass: 0.9 }

/**
 * Glint's redrawn cursor, to try out. Left alone, it glides between the
 * buttons and clicks each one. Move a mouse over the pad and it becomes your
 * pointer: it eases after the mouse, and each click leaves a ripple.
 */
export function CursorPad() {
  const reduced = useReducedMotion()
  const [hovering, setHovering] = useState(false)
  const [active, setActive] = useState(0)
  const [clicks, setClicks] = useState<Click[]>([])

  const gx = useSpring(TARGETS[0].x, GLIDE)
  const gy = useSpring(TARGETS[0].y, GLIDE)
  const left = useMotionTemplate`${gx}%`
  const top = useMotionTemplate`${gy}%`

  function addRipple(x: number, y: number) {
    const click = { id: Date.now() + Math.random(), x, y }
    setClicks((c) => [...c.slice(-4), click])
    setTimeout(() => setClicks((c) => c.filter((k) => k.id !== click.id)), 800)
  }

  // The idle demo: glide to the next button, then click it.
  useEffect(() => {
    if (reduced || hovering) return
    let i = active
    let clickTimer: ReturnType<typeof setTimeout>
    const step = () => {
      i = (i + 1) % TARGETS.length
      gx.set(TARGETS[i].x)
      gy.set(TARGETS[i].y)
      clickTimer = setTimeout(() => {
        setActive(i)
        addRipple(TARGETS[i].x, TARGETS[i].y)
      }, 900)
    }
    const id = setInterval(step, 1900)
    return () => {
      clearInterval(id)
      clearTimeout(clickTimer)
    }
    // `active` only seeds the starting point; restarting on it would stutter.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [reduced, hovering, gx, gy])

  function onClick(e: React.MouseEvent<HTMLDivElement>) {
    const r = e.currentTarget.getBoundingClientRect()
    addRipple(
      ((e.clientX - r.left) / r.width) * 100,
      ((e.clientY - r.top) / r.height) * 100
    )
  }

  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setHovering(true)}
      onMouseLeave={() => setHovering(false)}
      className="relative h-44 overflow-hidden rounded-xl border border-white/10 bg-[#0a0d11] bg-[radial-gradient(rgb(255_255_255/0.09)_1px,transparent_1px)] [background-size:16px_16px]"
    >
      {TARGETS.map((t, i) => (
        <button
          key={t.label}
          type="button"
          tabIndex={-1}
          onClick={() => setActive(i)}
          style={{ left: `${t.x}%`, top: `${t.y}%` }}
          className={cn(
            "absolute -translate-x-1/2 -translate-y-1/2 cursor-none rounded-lg border px-2.5 py-1.5 text-xs font-medium transition-colors duration-300",
            i === active
              ? "border-primary/60 bg-primary/15 text-primary"
              : "bg-card text-muted-foreground hover:text-foreground border-white/10"
          )}
        >
          {t.label}
        </button>
      ))}

      <AnimatePresence>
        {clicks.map((c) => (
          <motion.span
            key={c.id}
            className="border-primary pointer-events-none absolute z-10 size-10 -translate-x-1/2 -translate-y-1/2 rounded-full border-2"
            style={{ left: `${c.x}%`, top: `${c.y}%` }}
            initial={{ scale: 0.2, opacity: 0.9 }}
            animate={{ scale: 1.5, opacity: 0 }}
            exit={{ opacity: 0 }}
            transition={{ duration: 0.7, ease: "easeOut" }}
          />
        ))}
      </AnimatePresence>

      {/* Idle cursor, hidden while the visitor is driving. */}
      <motion.div
        aria-hidden
        className="pointer-events-none absolute z-20"
        style={{ left, top }}
        animate={{ opacity: hovering ? 0 : 1 }}
        transition={{ duration: 0.2 }}
      >
        <GlintCursor light className="size-7 -translate-x-[18%] -translate-y-[10%] drop-shadow-[0_2px_4px_rgb(0_0_0/0.6)]" />
      </motion.div>

      <Pointer spring={{ stiffness: 170, damping: 20, mass: 0.7 }}>
        {/* Offset so the arrow's tip, not its centre, sits on the pointer. */}
        <GlintCursor light className="size-7 translate-x-[32%] translate-y-[40%] drop-shadow-[0_2px_4px_rgb(0_0_0/0.6)]" />
      </Pointer>
    </div>
  )
}
