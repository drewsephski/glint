import { cn } from "@/lib/utils"

const charts = [
  { label: "ARR", value: "$4.2M", bars: [22, 52, 68, 58, 30, 56, 70] },
  { label: "Net retention", value: "118%", bars: [66, 62, 36, 40, 64, 66, 46] },
  { label: "Pipeline", value: "$9.8M", bars: [46, 32, 62, 70, 52, 28, 60] },
]

/**
 * The sample recording used across the page: the same "Acme" dashboard that
 * appears in Glint's demo project, drawn in HTML so it stays sharp when the
 * camera zooms. Sizes are in container units, so it scales with its box.
 */
export function DemoScene({
  search = "",
  className,
}: {
  search?: string
  className?: string
}) {
  return (
    <div
      className={cn(
        "@container absolute inset-0 bg-linear-to-br from-[#f29a86] via-[#8e479f] to-[#3b1f5e]",
        className
      )}
    >
      <div className="absolute inset-x-[7%] inset-y-[8%] flex overflow-hidden rounded-[1.2cqw] bg-[#f7f7fb] text-[#1c2030] shadow-[0_3cqw_6cqw_rgb(0_0_0/0.35)]">
        <div className="flex w-[19%] flex-col gap-[1.3cqw] bg-[#1e2330] px-[2cqw] py-[2.6cqw] text-[1.25cqw] text-white/70">
          <span className="mb-[1.4cqw] text-[1.7cqw] font-bold text-white">
            Acme
          </span>
          <span>Overview</span>
          <span className="-mx-[0.8cqw] rounded-[0.5cqw] bg-white/15 px-[0.8cqw] py-[0.5cqw] text-white">
            Reports
          </span>
          <span>Customers</span>
          <span>Billing</span>
          <span>Settings</span>
        </div>
        <div className="flex flex-1 flex-col px-[3cqw] py-[2.8cqw]">
          <div className="flex items-start justify-between">
            <span className="text-[2cqw] font-semibold">Quarterly revenue</span>
            <span className="rounded-[0.6cqw] bg-[#ef3340] px-[3.4cqw] py-[1cqw] text-[1.2cqw] font-semibold text-white">
              Save
            </span>
          </div>
          <div className="mt-[9cqw] flex h-[3.6cqw] w-[45%] items-center rounded-[0.6cqw] border border-[#d6d9e6] bg-white px-[1.2cqw] text-[1.2cqw]">
            {search ? (
              <span>{search}</span>
            ) : (
              <span className="text-[#9aa0b4]">Search reports…</span>
            )}
          </div>
          <div className="mt-[2.4cqw] grid flex-1 grid-cols-3 gap-[1.6cqw]">
            {charts.map((c) => (
              <div
                key={c.label}
                className="flex flex-col rounded-[0.8cqw] bg-white p-[1.4cqw] shadow-[0_0.2cqw_0.8cqw_rgb(20_24_40/0.06)]"
              >
                <span className="text-[1cqw] text-[#8a90a4]">{c.label}</span>
                <span className="mt-[0.5cqw] text-[1.7cqw] font-semibold">
                  {c.value}
                </span>
                <div className="mt-auto flex h-[45%] items-end gap-[0.7cqw]">
                  {c.bars.map((h, i) => (
                    <span
                      key={i}
                      style={{ height: `${h}%` }}
                      className="flex-1 rounded-t-[0.25cqw] bg-[#5b7cf0]"
                    />
                  ))}
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

/** The redrawn arrow cursor Glint renders: black with a white edge. */
// (Path is one closed arrow; `light` swaps the two colours.)
export function GlintCursor({
  className,
  light = false,
}: {
  className?: string
  /** White with a dark edge, for dark surfaces. */
  light?: boolean
}) {
  return (
    <svg viewBox="0 0 24 24" className={className} aria-hidden>
      <path
        d="M4 2.5v17.2l4.7-4.2 3 6.9 3.2-1.4-3-6.8h6.4z"
        fill={light ? "#fff" : "#0b0b0f"}
        stroke={light ? "#0b0b0f" : "#fff"}
        strokeWidth="1.5"
        strokeLinejoin="round"
      />
    </svg>
  )
}
