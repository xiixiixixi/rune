import Link from "next/link"
import {
  ArrowUpRight,
  Camera,
  Check,
  Copy,
  Crop,
  LockKeyhole,
  MousePointer2,
  Pin,
  Scissors,
  SquareDashedMousePointer,
  Video,
} from "lucide-react"
import { DownloadDropdown } from "@/components/download-dropdown"
import { EditorPreview } from "@/components/editor-demo"
import { SiteFooter, SiteHeader } from "@/components/site-shell"
import { getLatestRelease } from "@/lib/downloads"

const shortcuts = [
  ["Capture a region", ["⌘", "⇧", "4"]],
  ["Capture the screen", ["⌘", "⇧", "3"]],
  ["Capture a window", ["⌘", "⇧", "5"]],
  ["Record the screen", ["⌘", "⇧", "2"]],
  ["Read text", ["⌘", "⇧", "O"]],
] as const

export default async function Home() {
  const release = await getLatestRelease()

  return (
    <div className="min-h-dvh overflow-x-hidden bg-background text-foreground">
      <SiteHeader
        actions={
          <DownloadDropdown
            release={release}
            source="navbar"
            size="sm"
            showLabel={false}
            className="rounded-full"
          />
        }
      />

      <main id="main-content" className="pt-16">
        <section className="mx-auto flex max-w-5xl flex-col items-center px-6 pb-20 pt-24 text-center sm:pt-32">
          <p className="mb-5 text-sm font-semibold text-primary">A private capture studio for your Mac</p>
          <h1 className="max-w-4xl text-balance text-5xl font-semibold leading-none sm:text-6xl lg:text-7xl">
            One shortcut from screen to shared.
          </h1>
          <p className="mt-7 max-w-2xl text-pretty text-lg leading-relaxed text-muted-foreground sm:text-xl">
            Rune captures screenshots and recordings, lets you explain what matters, and keeps every pixel on your Mac.
          </p>

          <div className="mt-10 flex flex-wrap items-center justify-center gap-3">
            <DownloadDropdown release={release} source="hero" className="h-11 rounded-full px-6" />
            <a
              href="https://github.com/xiixiixixi/rune"
              target="_blank"
              rel="noopener noreferrer"
              className="glass-surface inline-flex h-11 items-center gap-2 rounded-full border px-5 text-sm font-medium text-foreground shadow-sm focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
            >
              View source
              <ArrowUpRight className="size-4" aria-hidden="true" />
            </a>
          </div>

          <p className="mt-6 text-sm text-muted-foreground">macOS 14+ · Apple silicon and Intel · No account</p>
        </section>

        <section aria-label="Rune editor preview" className="mx-auto max-w-6xl px-6 pb-28">
          <div className="relative p-4 sm:p-6">
            <ViewfinderCorners />
            <div className="glass-surface overflow-hidden rounded-2xl border p-2 shadow-2xl">
              <div className="overflow-hidden rounded-xl border border-border/70 bg-card">
                <EditorPreview />
              </div>
            </div>
          </div>
        </section>

        <section className="border-y border-border/70 bg-card/35">
          <div className="mx-auto grid max-w-6xl divide-y divide-border/70 px-6 md:grid-cols-3 md:divide-x md:divide-y-0">
            <ProofPoint icon={<LockKeyhole />} title="Local by design" detail="No cloud upload, account, or telemetry." />
            <ProofPoint icon={<Camera />} title="Native and ready" detail="A Swift app that lives in your menu bar." />
            <ProofPoint icon={<Check />} title="Open source" detail="Inspect the code and keep your workflow portable." />
          </div>
        </section>

        <WorkflowChapter
          step="01"
          eyebrow="Capture"
          title="Take exactly the frame you mean."
          description="Drag a region, click a window, capture the full display, or start a recording. Rune stays in the menu bar until you need it."
          bullets={["Region, window, and full-screen capture", "MP4 recording with pause and resume", "Scrolling capture, OCR, and color picking"]}
          visual={<CaptureModesMock />}
        />

        <WorkflowChapter
          step="02"
          eyebrow="Explain"
          title="Turn a capture into a clear answer."
          description="Add one precise arrow, hide private information, crop the noise, or frame the image for sharing. The canvas stays primary; tools float at the edge."
          bullets={["Shapes, arrows, text, blur, and spotlight", "Non-destructive crop and undo", "Padding, corners, shadows, and backgrounds"]}
          visual={<AnnotationToolsMock />}
          reverse
        />

        <WorkflowChapter
          step="03"
          eyebrow="Share"
          title="Copy it, drag it, or keep it in sight."
          description="The saved preview gives you the next useful action immediately. Copy to the clipboard, drag into another app, pin it above your work, or open the editor."
          bullets={["Drag directly into Figma, Slack, or Finder", "Pin references above every window", "Search recent screenshots and recordings"]}
          visual={<ShareFlowMock />}
        />

        <section className="border-y border-border/70 bg-card/35 py-24 sm:py-28">
          <div className="mx-auto grid max-w-6xl gap-14 px-6 lg:grid-cols-[0.8fr_1.2fr] lg:items-start">
            <div>
              <p className="text-sm font-semibold text-primary">Keyboard first</p>
              <h2 className="mt-3 text-balance text-4xl font-semibold sm:text-5xl">Fast enough to become muscle memory.</h2>
              <p className="mt-5 max-w-md text-pretty text-lg leading-relaxed text-muted-foreground">
                Familiar macOS shortcuts start the job. Clear labels and visible focus keep every action reachable without guessing.
              </p>
            </div>

            <div className="glass-surface overflow-hidden rounded-2xl border shadow-xl">
              <div className="divide-y divide-border/70">
                {shortcuts.map(([label, keys]) => (
                  <div key={label} className="flex items-center justify-between gap-6 px-5 py-4 sm:px-6">
                    <span className="text-sm font-medium">{label}</span>
                    <div className="flex items-center gap-1.5" role="group" aria-label={keys.join(" ")}>
                      {keys.map((key) => (
                        <kbd aria-hidden="true" key={key} className="flex size-7 items-center justify-center rounded-md border bg-card font-mono text-xs text-muted-foreground shadow-sm">
                          {key}
                        </kbd>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </section>

        <section className="mx-auto max-w-5xl px-6 py-24 text-center sm:py-32">
          <div className="glass-surface rounded-3xl border px-6 py-16 shadow-xl sm:px-12">
            <h2 className="text-balance text-4xl font-semibold sm:text-5xl">Your screen stays yours.</h2>
            <p className="mx-auto mt-5 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground">
              Download Rune, grant screen recording permission once, and capture without creating an account or sending images to a server.
            </p>
            <div className="mt-8 flex justify-center">
              <DownloadDropdown release={release} source="cta" className="h-11 rounded-full px-6" />
            </div>
            <Link href="/privacy" className="mt-5 inline-block text-sm text-primary hover:underline">
              Read the privacy policy
            </Link>
          </div>
        </section>
      </main>

      <SiteFooter />
    </div>
  )
}

function ViewfinderCorners() {
  return (
    <>
      <span className="viewfinder-corner left-0 top-0 border-l-2 border-t-2" />
      <span className="viewfinder-corner right-0 top-0 border-r-2 border-t-2" />
      <span className="viewfinder-corner bottom-0 left-0 border-b-2 border-l-2" />
      <span className="viewfinder-corner bottom-0 right-0 border-b-2 border-r-2" />
    </>
  )
}

function ProofPoint({ icon, title, detail }: { icon: React.ReactNode; title: string; detail: string }) {
  return (
    <div className="flex gap-4 py-8 md:px-8">
      <span className="flex size-10 shrink-0 items-center justify-center rounded-xl bg-accent text-primary [&>svg]:size-5">{icon}</span>
      <div>
        <h2 className="font-semibold">{title}</h2>
        <p className="mt-1 text-sm leading-relaxed text-muted-foreground">{detail}</p>
      </div>
    </div>
  )
}

function WorkflowChapter({
  step,
  eyebrow,
  title,
  description,
  bullets,
  visual,
  reverse = false,
}: {
  step: string
  eyebrow: string
  title: string
  description: string
  bullets: string[]
  visual: React.ReactNode
  reverse?: boolean
}) {
  return (
    <section className="border-b border-border/70 py-24 sm:py-32">
      <div className={`mx-auto grid max-w-6xl gap-14 px-6 lg:grid-cols-2 lg:items-center ${reverse ? "lg:[&>*:first-child]:order-2" : ""}`}>
        <div>
          <p className="font-mono text-sm text-muted-foreground">{step} · {eyebrow}</p>
          <h2 className="mt-4 text-balance text-4xl font-semibold sm:text-5xl">{title}</h2>
          <p className="mt-5 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground">{description}</p>
          <ul className="mt-7 space-y-3">
            {bullets.map((bullet) => (
              <li key={bullet} className="flex items-start gap-3 text-sm text-muted-foreground">
                <Check className="mt-0.5 size-4 shrink-0 text-primary" aria-hidden="true" />
                {bullet}
              </li>
            ))}
          </ul>
        </div>
        <div className="relative p-3">
          <ViewfinderCorners />
          {visual}
        </div>
      </div>
    </section>
  )
}

function CaptureModesMock() {
  const rows = [
    [<SquareDashedMousePointer key="region" />, "Capture region", "⌘⇧4"],
    [<MousePointer2 key="window" />, "Capture window", "⌘⇧5"],
    [<Video key="video" />, "Record screen", "⌘⇧2"],
  ]

  return (
    <div className="glass-surface rounded-2xl border p-3 shadow-xl">
      <div className="rounded-xl border border-border/70 bg-card/70 p-3">
        <div className="mb-2 flex items-center justify-between px-2 py-2">
          <span className="font-semibold">Rune</span>
          <span className="text-xs text-muted-foreground">Capture</span>
        </div>
        <div className="space-y-2">
          {rows.map(([icon, label, shortcut]) => (
            <div key={String(label)} className="flex items-center gap-3 rounded-lg bg-secondary/70 px-3 py-3">
              <span className="text-primary [&>svg]:size-5">{icon}</span>
              <span className="flex-1 text-sm font-medium">{label}</span>
              <kbd className="font-mono text-xs text-muted-foreground">{shortcut}</kbd>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

function AnnotationToolsMock() {
  const tools = [
    [<MousePointer2 key="pointer" />, "Select"],
    [<Crop key="crop" />, "Crop"],
    [<Scissors key="trim" />, "Trim"],
    [<LockKeyhole key="redact" />, "Redact"],
  ]

  return (
    <div className="glass-surface rounded-2xl border p-5 shadow-xl">
      <div className="grid grid-cols-2 gap-3">
        {tools.map(([icon, label], index) => (
          <div key={String(label)} className={`rounded-xl border p-4 ${index === 1 ? "border-primary/40 bg-accent" : "border-border/70 bg-card/60"}`}>
            <span className={`flex size-9 items-center justify-center rounded-lg ${index === 1 ? "bg-primary text-primary-foreground" : "bg-secondary text-muted-foreground"} [&>svg]:size-4`}>
              {icon}
            </span>
            <p className="mt-3 text-sm font-semibold">{label}</p>
          </div>
        ))}
      </div>
      <div className="mt-4 rounded-xl border border-border/70 bg-card/60 p-4">
        <div className="flex items-center justify-between text-xs text-muted-foreground"><span>Padding</span><span className="font-mono">12%</span></div>
        <div className="mt-3 h-1.5 rounded-full bg-secondary"><div className="h-full w-2/5 rounded-full bg-primary" /></div>
      </div>
    </div>
  )
}

function ShareFlowMock() {
  return (
    <div className="glass-surface rounded-2xl border p-5 shadow-xl">
      <div className="aspect-video rounded-xl border border-border/70 bg-secondary/80 p-4">
        <div className="flex h-full items-center justify-center rounded-lg border border-border/70 bg-card">
          <Camera className="size-10 text-muted-foreground" aria-hidden="true" />
        </div>
      </div>
      <div className="mt-4 flex flex-wrap gap-2">
        <MockAction icon={<Copy />} label="Copy" primary />
        <MockAction icon={<Pin />} label="Pin" />
        <MockAction icon={<Scissors />} label="Edit" />
      </div>
    </div>
  )
}

function MockAction({ icon, label, primary = false }: { icon: React.ReactNode; label: string; primary?: boolean }) {
  return (
    <span className={`inline-flex items-center gap-2 rounded-full px-4 py-2 text-sm font-medium ${primary ? "bg-primary text-primary-foreground" : "bg-secondary text-secondary-foreground"}`}>
      <span className="[&>svg]:size-4">{icon}</span>
      {label}
    </span>
  )
}
