import { type ComponentPropsWithoutRef, type CSSProperties } from "react"

import { cn } from "@/lib/utils"

interface ShimmerOptions {
  shimmerColor?: string
  shimmerSize?: string
  borderRadius?: string
  shimmerDuration?: string
  background?: string
}

export type ShimmerButtonProps = ShimmerOptions &
  (
    | ({ href: string } & ComponentPropsWithoutRef<"a">)
    | ({ href?: undefined } & ComponentPropsWithoutRef<"button">)
  )

/**
 * Magic UI shimmer button, adapted for Glint: renders a link when `href` is
 * set, and defaults to the light-blue brand fill with dark text.
 */
export function ShimmerButton({
  shimmerColor = "#ffffff",
  shimmerSize = "0.09em",
  shimmerDuration = "3.2s",
  borderRadius = "12px",
  background = "var(--primary)",
  className,
  children,
  ...props
}: ShimmerButtonProps) {
  const style = {
    "--spread": "90deg",
    "--shimmer-color": shimmerColor,
    "--radius": borderRadius,
    "--speed": shimmerDuration,
    "--cut": shimmerSize,
    "--bg": background,
  } as CSSProperties

  const classes = cn(
    "group text-primary-foreground relative z-0 inline-flex cursor-pointer items-center justify-center gap-2 overflow-hidden [border-radius:var(--radius)] px-5 py-3 text-[0.95rem] font-semibold whitespace-nowrap [background:var(--bg)]",
    "transform-gpu transition-transform duration-300 ease-in-out active:translate-y-px",
    "focus-visible:ring-ring/60 focus-visible:ring-offset-background outline-none focus-visible:ring-2 focus-visible:ring-offset-2",
    className
  )

  const inner = (
    <>
      {/* spark container */}
      <span
        aria-hidden
        className="@container-[size] absolute inset-0 -z-30 overflow-visible blur-[2px]"
      >
        <span className="animate-shimmer-slide absolute inset-0 block aspect-[1] h-[100cqh] rounded-none [mask:none]">
          <span className="animate-spin-around absolute -inset-full block w-auto [translate:0_0] rotate-0 [background:conic-gradient(from_calc(270deg-(var(--spread)*0.5)),transparent_0,var(--shimmer-color)_var(--spread),transparent_var(--spread))]" />
        </span>
      </span>
      {children}
      {/* highlight */}
      <span
        aria-hidden
        className="absolute inset-0 size-full [border-radius:var(--radius)] shadow-[inset_0_-6px_10px_#ffffff26] transition-shadow duration-300 ease-in-out group-hover:shadow-[inset_0_-6px_14px_#ffffff59]"
      />
      {/* backdrop */}
      <span
        aria-hidden
        className="absolute inset-(--cut) -z-20 [border-radius:calc(var(--radius)-var(--cut))] [background:var(--bg)]"
      />
    </>
  )

  if (props.href !== undefined) {
    return (
      <a style={style} className={classes} {...props}>
        {inner}
      </a>
    )
  }

  return (
    <button style={style} className={classes} {...props}>
      {inner}
    </button>
  )
}
