"use client"

import { useState } from "react"
import { Check, Copy } from "lucide-react"

import { cn } from "@/lib/utils"

export function CopyButton({
  text,
  className,
}: {
  text: string
  className?: string
}) {
  const [copied, setCopied] = useState(false)

  async function copy() {
    try {
      await navigator.clipboard.writeText(text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1600)
    } catch {
      // Clipboard access can be blocked; the text stays selectable.
    }
  }

  return (
    <button
      type="button"
      onClick={copy}
      className={cn(
        "text-muted-foreground hover:text-foreground hover:bg-secondary focus-visible:ring-ring/60 inline-flex items-center gap-1.5 rounded-md border px-2 py-1 text-xs font-medium transition-colors outline-none focus-visible:ring-2",
        className
      )}
    >
      {copied ? (
        <Check className="text-primary size-3.5" />
      ) : (
        <Copy className="size-3.5" />
      )}
      <span aria-live="polite">{copied ? "Copied" : "Copy"}</span>
    </button>
  )
}
