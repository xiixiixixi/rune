import {
  ArrowUpRight,
  Circle,
  Crop,
  EyeOff,
  MousePointer2,
  Square,
  Type,
} from "lucide-react"

const tools = [MousePointer2, Square, ArrowUpRight, Type, EyeOff, Circle]
const swatches = ["#f2f2f7", "#1c1c1e", "#ff453a", "#ff9f0a", "#30d158", "#0a84ff", "#bf5af2"]

export function EditorPreview() {
  return (
    <div className="relative aspect-[1200/760] min-h-[360px] w-full bg-secondary p-3 sm:p-5">
      <div className="glass-surface flex h-full overflow-hidden rounded-xl border shadow-xl">
        <div className="flex min-w-0 flex-1 flex-col">
          <WindowToolbar />

          <div className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden bg-[#242426] p-6 sm:p-10">
            <div className="flex aspect-[16/10] w-[76%] max-w-2xl items-center justify-center rounded-2xl bg-[#3974a8] p-[8%] shadow-2xl">
              <div className="h-full w-full overflow-hidden rounded-xl border border-white/10 bg-[#111214] shadow-xl">
                <div className="flex h-7 items-center gap-1.5 border-b border-white/10 bg-white/5 px-2.5">
                  <span className="size-2 rounded-full bg-[#ff5f57]" />
                  <span className="size-2 rounded-full bg-[#febc2e]" />
                  <span className="size-2 rounded-full bg-[#28c840]" />
                </div>
                <div className="flex h-[calc(100%-1.75rem)] items-center justify-center p-5 text-center">
                  <div>
                    <div aria-hidden="true" className="mx-auto flex size-11 items-center justify-center rounded-xl bg-white/10 text-lg text-white">⌘</div>
                    <p className="mt-3 text-sm font-semibold text-white">Rune</p>
                    <p className="mt-1 text-xs text-white/50">Capture. Explain. Share.</p>
                  </div>
                </div>
              </div>
            </div>

            <ToolShelf />
          </div>
        </div>

        <Inspector />
      </div>
    </div>
  )
}

function WindowToolbar() {
  return (
    <div className="glass-surface flex h-12 shrink-0 items-center border-b px-3 sm:px-4">
      <div className="flex gap-1.5">
        <span className="size-3 rounded-full bg-[#ff5f57]" />
        <span className="size-3 rounded-full bg-[#febc2e]" />
        <span className="size-3 rounded-full bg-[#28c840]" />
      </div>
      <span className="flex-1 text-center text-xs font-medium text-muted-foreground">Rune editor</span>
      <div className="flex items-center gap-2">
        <span className="hidden rounded-md bg-secondary px-2 py-1 text-xs text-muted-foreground sm:inline">Copy</span>
        <span className="rounded-md bg-primary px-2.5 py-1 text-xs font-medium text-primary-foreground">Export</span>
      </div>
    </div>
  )
}

function ToolShelf() {
  return (
    <div className="glass-surface absolute bottom-4 left-1/2 flex -translate-x-1/2 items-center gap-1 rounded-2xl border p-1.5 shadow-xl">
      {tools.map((Icon, index) => (
        <span
          key={index}
          className={`flex size-9 items-center justify-center rounded-xl ${index === 0 ? "bg-primary text-primary-foreground" : "text-foreground"}`}
        >
          <Icon className="size-4" aria-hidden="true" />
        </span>
      ))}
    </div>
  )
}

function Inspector() {
  return (
    <aside className="hidden w-60 shrink-0 border-l border-border/70 bg-card/80 md:block">
      <div className="grid grid-cols-2 gap-1 border-b border-border/70 p-2">
        <span className="rounded-lg bg-secondary px-3 py-2 text-center text-xs font-medium">Appearance</span>
        <span className="px-3 py-2 text-center text-xs text-muted-foreground">Annotate</span>
      </div>

      <div className="space-y-5 p-4">
        <section>
          <div className="mb-3 flex items-center gap-2">
            <Crop className="size-4 text-muted-foreground" aria-hidden="true" />
            <h2 className="text-xs font-semibold">Frame</h2>
          </div>
          <Slider label="Padding" value="8%" width="40%" />
          <Slider label="Corner radius" value="18" width="46%" />
          <Slider label="Shadow" value="36%" width="58%" />
        </section>

        <section className="border-t border-border/70 pt-4">
          <h2 className="mb-3 text-xs font-semibold">Background</h2>
          <div className="grid grid-cols-7 gap-1.5">
            {swatches.map((swatch, index) => (
              <span
                key={swatch}
                className={`aspect-square rounded-md border ${index === 5 ? "ring-2 ring-primary ring-offset-1 ring-offset-card" : "border-border"}`}
                style={{ backgroundColor: swatch }}
              />
            ))}
          </div>
        </section>

        <section className="border-t border-border/70 pt-4">
          <div className="flex items-center justify-between text-xs">
            <span className="text-muted-foreground">Ratio</span>
            <span className="font-medium">Automatic</span>
          </div>
        </section>
      </div>
    </aside>
  )
}

function Slider({ label, value, width }: { label: string; value: string; width: string }) {
  return (
    <div className="mb-3">
      <div className="mb-1.5 flex justify-between text-[11px] text-muted-foreground">
        <span>{label}</span>
        <span className="font-mono">{value}</span>
      </div>
      <div className="h-1.5 overflow-hidden rounded-full bg-secondary">
        <div className="h-full rounded-full bg-primary" style={{ width }} />
      </div>
    </div>
  )
}
