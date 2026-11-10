"use client"

import { useId, useState } from "react"
import { AnimatePresence, motion } from "motion/react"
import { Plus } from "lucide-react"

export interface FaqItem {
  q: string
  a: React.ReactNode
}

const ease = [0.22, 1, 0.36, 1] as const

export function FaqList({ items }: { items: FaqItem[] }) {
  const [open, setOpen] = useState<number | null>(0)
  const id = useId()

  return (
    <div className="divide-y divide-white/[0.08] border-y border-white/[0.08]">
      {items.map((item, i) => {
        const isOpen = open === i
        return (
          <div key={item.q}>
            <h3>
              <button
                type="button"
                id={`${id}-q${i}`}
                aria-expanded={isOpen}
                aria-controls={`${id}-a${i}`}
                onClick={() => setOpen(isOpen ? null : i)}
                className="hover:text-primary focus-visible:text-primary flex w-full cursor-pointer items-center justify-between gap-6 py-5 text-left text-lg font-medium transition-colors outline-none"
              >
                {item.q}
                <motion.span
                  animate={{ rotate: isOpen ? 45 : 0 }}
                  transition={{ duration: 0.35, ease }}
                  className={isOpen ? "text-primary" : "text-muted-foreground"}
                >
                  <Plus className="size-5" />
                </motion.span>
              </button>
            </h3>
            <AnimatePresence initial={false}>
              {isOpen && (
                <motion.div
                  id={`${id}-a${i}`}
                  role="region"
                  aria-labelledby={`${id}-q${i}`}
                  initial={{ height: 0, opacity: 0 }}
                  animate={{
                    height: "auto",
                    opacity: 1,
                    transition: {
                      height: { duration: 0.42, ease },
                      opacity: { duration: 0.3, delay: 0.1 },
                    },
                  }}
                  exit={{
                    height: 0,
                    opacity: 0,
                    transition: {
                      height: { duration: 0.32, ease },
                      opacity: { duration: 0.15 },
                    },
                  }}
                  className="overflow-hidden"
                >
                  <motion.p
                    initial={{ y: -6, filter: "blur(4px)" }}
                    animate={{ y: 0, filter: "blur(0px)" }}
                    exit={{ y: -6, filter: "blur(4px)" }}
                    transition={{ duration: 0.35, ease }}
                    className="text-muted-foreground max-w-2xl pb-6 leading-relaxed text-pretty"
                  >
                    {item.a}
                  </motion.p>
                </motion.div>
              )}
            </AnimatePresence>
          </div>
        )
      })}
    </div>
  )
}
