"use client"

import { useEffect, useState } from "react"
import { useReducedMotion } from "motion/react"

import { DemoScene, GlintCursor } from "./demo-scene"

const LINES = [
  ["Here", "is", "our", "quarterly", "dashboard."],
  ["Saving", "the", "report", "takes", "one", "click."],
]

/** A rendered frame with Glint's caption: the spoken word lights up in turn. */
export function CaptionDemo() {
  const reduced = useReducedMotion()
  const [pos, setPos] = useState({ line: 0, word: 3 })

  useEffect(() => {
    if (reduced) return
    const id = setInterval(() => {
      setPos((p) => {
        if (p.word + 1 < LINES[p.line].length) return { ...p, word: p.word + 1 }
        return { line: (p.line + 1) % LINES.length, word: 0 }
      })
    }, 420)
    return () => clearInterval(id)
  }, [reduced])

  return (
    <div
      className="@container relative aspect-[16/8.2] overflow-hidden rounded-xl border border-white/10"
      role="img"
      aria-label="A rendered frame of the dashboard with a caption at the bottom; the word being spoken is highlighted"
    >
      {/* Slightly zoomed, as a frame looks mid-demo. */}
      <div className="absolute top-[-24%] left-[-12%] aspect-video w-[124%]">
        <DemoScene />
        <GlintCursor className="absolute top-[52%] left-[58%] w-[3.2%] drop-shadow-[0_2px_3px_rgb(0_0_0/0.4)]" />
      </div>
      <div className="absolute inset-x-0 bottom-[9%] flex justify-center">
        <span className="rounded-[1.6cqw] bg-[#3c3f4a]/95 px-[2.6cqw] py-[1.3cqw] text-[3.3cqw] font-semibold text-white shadow-[0_1cqw_3cqw_rgb(0_0_0/0.35)]">
          {LINES[pos.line].map((w, i) => (
            <span
              key={`${pos.line}-${i}`}
              className={
                i === pos.word
                  ? "text-[#ffd24a] transition-colors duration-150"
                  : "transition-colors duration-150"
              }
            >
              {w}
              {i < LINES[pos.line].length - 1 ? " " : ""}
            </span>
          ))}
        </span>
      </div>
    </div>
  )
}
