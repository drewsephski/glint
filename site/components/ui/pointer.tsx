"use client"

import { useEffect, useRef, useState } from "react"
import {
  AnimatePresence,
  motion,
  useMotionValue,
  useSpring,
  type HTMLMotionProps,
  type SpringOptions,
} from "motion/react"

import { cn } from "@/lib/utils"

/**
 * A custom pointer component that displays an animated cursor.
 * Add this as a child to any positioned (relative) component to enable a custom
 * pointer when hovering.
 * You can pass custom children to render as the pointer.
 *
 * @component
 * @param {HTMLMotionProps<"div">} props - The component props
 */
export function Pointer({
  className,
  style,
  children,
  spring,
  ...props
}: HTMLMotionProps<"div"> & {
  /** Glint addition: ease the pointer toward the mouse instead of snapping. */
  spring?: SpringOptions
}): React.ReactNode {
  const x = useMotionValue(0)
  const y = useMotionValue(0)
  const sx = useSpring(x, spring ?? { duration: 0 })
  const sy = useSpring(y, spring ?? { duration: 0 })
  const [isActive, setIsActive] = useState<boolean>(false)
  const containerRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const parentElement =
      typeof window !== "undefined"
        ? (containerRef.current?.parentElement ?? null)
        : null

    // Glint change: positions are relative to the parent, and the pointer is
    // absolutely positioned inside it. The original used viewport coordinates
    // with position: fixed, which breaks under any transformed or filtered
    // ancestor (the pointer lands far off-screen and widens the page).
    const local = (e: MouseEvent) => {
      const r = parentElement!.getBoundingClientRect()
      return [e.clientX - r.left, e.clientY - r.top] as const
    }

    const handleMouseMove = (e: MouseEvent) => {
      const [px, py] = local(e)
      x.set(px)
      y.set(py)
      setIsActive(true)
    }

    const handleMouseEnter = (e: MouseEvent) => {
      const [px, py] = local(e)
      x.jump(px)
      y.jump(py)
      sx.jump(px)
      sy.jump(py)
      setIsActive(true)
    }

    const handleMouseLeave = () => {
      setIsActive(false)
    }

    if (parentElement) {
      parentElement.style.cursor = "none"
      parentElement.addEventListener("mousemove", handleMouseMove)
      parentElement.addEventListener("mouseenter", handleMouseEnter)
      parentElement.addEventListener("mouseleave", handleMouseLeave)
    }

    return () => {
      if (parentElement) {
        parentElement.style.cursor = ""
        parentElement.removeEventListener("mousemove", handleMouseMove)
        parentElement.removeEventListener("mouseenter", handleMouseEnter)
        parentElement.removeEventListener("mouseleave", handleMouseLeave)
      }
    }
  }, [x, y, sx, sy])

  return (
    <>
      <div ref={containerRef} />
      <AnimatePresence>
        {isActive && (
          <motion.div
            className="pointer-events-none absolute z-50 transform-[translate(-50%,-50%)]"
            style={{
              top: sy,
              left: sx,
              ...style,
            }}
            initial={{
              scale: 0,
              opacity: 0,
            }}
            animate={{
              scale: 1,
              opacity: 1,
            }}
            exit={{
              scale: 0,
              opacity: 0,
            }}
            {...props}
          >
            {children || (
              <svg
                stroke="currentColor"
                fill="currentColor"
                strokeWidth="1"
                viewBox="0 0 16 16"
                height="24"
                width="24"
                xmlns="http://www.w3.org/2000/svg"
                className={cn(
                  "rotate-[-70deg] stroke-white text-black",
                  className
                )}
              >
                <path d="M14.082 2.182a.5.5 0 0 1 .103.557L8.528 15.467a.5.5 0 0 1-.917-.007L5.57 10.694.803 8.652a.5.5 0 0 1-.006-.916l12.728-5.657a.5.5 0 0 1 .556.103z" />
              </svg>
            )}
          </motion.div>
        )}
      </AnimatePresence>
    </>
  )
}
