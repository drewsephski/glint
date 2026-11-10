"use client"

import { useEffect, useRef, useState } from "react"
import {
  motion,
  useMotionTemplate,
  useMotionValue,
  useMotionValueEvent,
  useReducedMotion,
  useSpring,
  useTransform,
} from "motion/react"

import { DemoScene, GlintCursor } from "./demo-scene"

/** Glint's default zoom depth, as in the "1.7×" proposal on this page. */
const ZOOM = 1.7
// Slow, slightly overdamped: the camera eases in and never bounces.
const CAMERA = { stiffness: 46, damping: 17, mass: 1 }
const POINTER = { stiffness: 120, damping: 22, mass: 0.6 }

// Normalised positions on the recorded frame.
const SAVE = { x: 0.85, y: 0.165 }
const SEARCH = { x: 0.36, y: 0.39 }
const REST = { x: 0.6, y: 0.72 }
const QUERY = "enterprise"

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

/**
 * How Glint's auto zoom moves: the whole frame is the lens. The camera eases
 * in before each click, holds, pans between nearby actions instead of zooming
 * out and back in, then eases out. It plays by itself; moving a pointer over
 * it lets the visitor steer the camera.
 */
export function AutoZoom() {
  const reduced = useReducedMotion()
  const box = useRef<HTMLDivElement>(null)
  const steering = useRef(false)

  const [search, setSearch] = useState("")
  const [label, setLabel] = useState("1.0×")
  const [lane, setLane] = useState<"idle" | "zoom">("idle")

  // Camera target: focus point and scale.
  const fx = useMotionValue(0.5)
  const fy = useMotionValue(0.5)
  const scale = useMotionValue(1)
  const sfx = useSpring(fx, CAMERA)
  const sfy = useSpring(fy, CAMERA)
  const s = useSpring(scale, CAMERA)

  // Keep the focus point centred, without showing past the frame's edges.
  const pan = (f: number, k: number) => {
    const limit = (k - 1) * 50
    return Math.max(-limit, Math.min(limit, (0.5 - f) * k * 100))
  }
  const tx = useTransform(() => pan(sfx.get(), s.get()))
  const ty = useTransform(() => pan(sfy.get(), s.get()))
  const transform = useMotionTemplate`translate(${tx}%, ${ty}%) scale(${s})`

  // The recorded cursor, and its click ripple.
  const cx = useSpring(REST.x * 100, POINTER)
  const cy = useSpring(REST.y * 100, POINTER)
  const left = useMotionTemplate`${cx}%`
  const top = useMotionTemplate`${cy}%`
  const [click, setClick] = useState(0)

  useMotionValueEvent(s, "change", (v) => setLabel(`${v.toFixed(1)}×`))

  useEffect(() => {
    if (reduced) return
    let alive = true

    const wait = async (ms: number) => {
      await sleep(ms)
      // While the visitor is steering, the script holds its place.
      while (alive && steering.current) await sleep(200)
      return alive
    }
    const moveCursor = (p: { x: number; y: number }) => {
      cx.set(p.x * 100)
      cy.set(p.y * 100)
    }
    const aim = (p: { x: number; y: number }, k: number) => {
      fx.set(p.x)
      fy.set(p.y)
      scale.set(k)
      setLane(k > 1 ? "zoom" : "idle")
    }

    async function run() {
      while (alive) {
        setSearch("")
        moveCursor(REST)
        aim({ x: 0.5, y: 0.5 }, 1)
        if (!(await wait(1400))) return

        // The zoom starts before the click it is for.
        aim(SAVE, ZOOM)
        if (!(await wait(350))) return
        moveCursor(SAVE)
        if (!(await wait(1100))) return
        setClick((n) => n + 1)
        if (!(await wait(1300))) return

        // A nearby action: pan across, staying zoomed in.
        moveCursor(SEARCH)
        if (!(await wait(250))) return
        aim(SEARCH, ZOOM)
        if (!(await wait(1200))) return
        setClick((n) => n + 1)
        for (let i = 1; i <= QUERY.length; i++) {
          if (!(await wait(95))) return
          setSearch(QUERY.slice(0, i))
        }

        // Hold after the action, then ease back out.
        if (!(await wait(1500))) return
        aim({ x: 0.5, y: 0.5 }, 1)
        moveCursor(REST)
        if (!(await wait(2000))) return
      }
    }

    run()
    return () => {
      alive = false
    }
  }, [reduced, cx, cy, fx, fy, scale])

  function steer(e: React.PointerEvent<HTMLDivElement>) {
    if (e.pointerType !== "mouse" || reduced || !box.current) return
    const r = box.current.getBoundingClientRect()
    steering.current = true
    fx.set((e.clientX - r.left) / r.width)
    fy.set((e.clientY - r.top) / r.height)
    scale.set(ZOOM)
    setLane("zoom")
  }

  function release() {
    if (!steering.current) return
    steering.current = false
    scale.set(1)
    setLane("idle")
  }

  return (
    <div>
      <div
        ref={box}
        onPointerMove={steer}
        onPointerLeave={release}
        className="relative aspect-video overflow-hidden rounded-xl border border-white/10 bg-black"
        role="img"
        aria-label="A recording of a dashboard. The camera eases in on the Save button before it is clicked, pans to the search field while text is typed, then eases back out."
      >
        <motion.div
          className="absolute inset-0 will-change-transform"
          style={{ transform }}
        >
          <DemoScene search={search} />
          <motion.div
            className="absolute z-10 w-[3.4%]"
            style={{ left, top }}
          >
            {click > 0 && (
              <motion.span
                key={click}
                className="absolute top-0 left-0 size-[160%] -translate-x-1/2 -translate-y-1/2 rounded-full border-2 border-white"
                initial={{ scale: 0.2, opacity: 0.9 }}
                animate={{ scale: 1.6, opacity: 0 }}
                transition={{ duration: 0.7, ease: "easeOut" }}
              />
            )}
            <GlintCursor className="relative w-full drop-shadow-[0_2px_3px_rgb(0_0_0/0.4)]" />
          </motion.div>
        </motion.div>

        <div className="absolute top-3 left-3 flex items-center gap-2 rounded-md bg-black/60 px-2 py-1 font-mono text-xs text-white backdrop-blur">
          <span
            className={
              lane === "zoom"
                ? "bg-primary size-1.5 rounded-full"
                : "size-1.5 rounded-full bg-white/40"
            }
          />
          {label}
        </div>
      </div>

      {/* Zoom lane: one block that spans both actions, like the timeline. */}
      <div
        className="mt-3 flex items-center gap-3 font-mono text-[0.7rem]"
        aria-hidden
      >
        <span className="text-muted-foreground w-10">Zoom</span>
        <div className="relative h-5 flex-1 rounded bg-white/[0.06]">
          <span className="border-primary/60 bg-primary/25 text-primary absolute inset-y-0 left-[14%] flex w-[58%] items-center rounded border px-2">
            1.7× · click “Save”, click “Search”, typing
          </span>
        </div>
      </div>
    </div>
  )
}
