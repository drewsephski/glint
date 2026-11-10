import { cn } from "@/lib/utils"
import { BlurFade } from "@/components/ui/blur-fade"

export function SectionHeading({
  title,
  children,
  note,
  className,
}: {
  title: React.ReactNode
  children?: React.ReactNode
  note?: React.ReactNode
  className?: string
}) {
  return (
    <BlurFade inView className={cn("max-w-2xl", className)}>
      {note && (
        <p className="text-primary mb-4 font-mono text-sm">{note}</p>
      )}
      <h2 className="text-3xl leading-[1.1] font-semibold tracking-[-0.025em] text-balance sm:text-[2.6rem]">
        {title}
      </h2>
      {children && (
        <p className="text-muted-foreground mt-5 text-lg leading-relaxed text-pretty">
          {children}
        </p>
      )}
    </BlurFade>
  )
}
