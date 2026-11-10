import { type ComponentPropsWithoutRef } from "react"
import { ArrowRight } from "lucide-react"

import { cn } from "@/lib/utils"

type InteractiveHoverButtonProps =
  | ({ href: string } & ComponentPropsWithoutRef<"a">)
  | ({ href?: undefined } & ComponentPropsWithoutRef<"button">)

/**
 * Magic UI interactive hover button, adapted for Glint: renders a link when
 * `href` is set and uses the page's 12px radius instead of a pill.
 */
export function InteractiveHoverButton({
  children,
  className,
  ...props
}: InteractiveHoverButtonProps) {
  const classes = cn(
    "group bg-card relative inline-block w-auto cursor-pointer overflow-hidden rounded-xl border px-5 py-3 text-center text-[0.95rem] font-semibold",
    "focus-visible:ring-ring/60 focus-visible:ring-offset-background outline-none focus-visible:ring-2 focus-visible:ring-offset-2",
    className
  )

  const inner = (
    <>
      <span className="flex items-center justify-center gap-2.5">
        <span className="bg-primary size-2 rounded-full transition-all duration-300 group-hover:scale-[100.8]" />
        <span className="inline-block transition-all duration-300 group-hover:translate-x-12 group-hover:opacity-0">
          {children}
        </span>
      </span>
      <span
        aria-hidden
        className="text-primary-foreground absolute top-0 left-0 z-10 flex h-full w-full translate-x-12 items-center justify-center gap-2 opacity-0 transition-all duration-300 group-hover:translate-x-0 group-hover:opacity-100"
      >
        <span>{children}</span>
        <ArrowRight className="size-4" />
      </span>
    </>
  )

  if (props.href !== undefined) {
    return (
      <a className={classes} {...props}>
        {inner}
      </a>
    )
  }

  return (
    <button className={classes} {...props}>
      {inner}
    </button>
  )
}
