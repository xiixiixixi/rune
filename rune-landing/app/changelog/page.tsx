import { CheckCircle2, Wrench } from "lucide-react"
import { SiteFooter, SiteHeader } from "@/components/site-shell"
import { getChangelog } from "@/lib/changelog"

export const metadata = {
  title: "Changelog — Rune",
  description: "What's new in Rune. Release notes for every version.",
}

export default function ChangelogPage() {
  const changelog = getChangelog()

  return (
    <div className="min-h-dvh bg-background text-foreground">
      <SiteHeader />
      <main id="main-content" className="pt-16">
        <header className="mx-auto max-w-3xl px-6 pb-14 pt-20 sm:pt-28">
          <p className="text-sm font-semibold text-primary">Release notes</p>
          <h1 className="mt-3 text-balance text-5xl font-semibold sm:text-6xl">What changed in Rune.</h1>
          <p className="mt-5 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground">
            New capture tools, interaction fixes, and the details that make the app feel at home on macOS.
          </p>
        </header>

        <section className="mx-auto max-w-3xl px-6 pb-24">
          <div className="space-y-6">
            {changelog.map((version, index) => (
              <article key={version.version} className="glass-surface overflow-hidden rounded-2xl border shadow-lg">
                <header className="flex flex-col gap-3 border-b border-border/70 px-5 py-5 sm:flex-row sm:items-center sm:justify-between sm:px-6">
                  <div className="flex items-center gap-3">
                    <span className="flex size-10 items-center justify-center rounded-xl bg-accent text-primary">
                      {index === 0 ? <CheckCircle2 className="size-5" /> : <Wrench className="size-5" />}
                    </span>
                    <div>
                      <h2 className="font-semibold">
                        {version.version.startsWith("Rune ") ? version.version : `Rune ${version.version}`}
                      </h2>
                      <p className="text-xs text-muted-foreground">{index === 0 ? "Latest release" : "Previous release"}</p>
                    </div>
                  </div>
                  <time className="font-mono text-xs text-muted-foreground">{version.date}</time>
                </header>

                <div className="space-y-7 bg-card/45 px-5 py-6 sm:px-6">
                  {version.sections.map((section) => (
                    <section key={section.label}>
                      <h3 className="text-sm font-semibold text-foreground">{section.label}</h3>
                      <ul className="mt-3 space-y-2.5">
                        {section.items.map((item) => (
                          <li key={item} className="flex items-start gap-3 text-sm leading-relaxed text-muted-foreground">
                            <span className="mt-2 size-1.5 shrink-0 rounded-full bg-primary" />
                            {item}
                          </li>
                        ))}
                      </ul>
                    </section>
                  ))}
                </div>
              </article>
            ))}
          </div>
        </section>
      </main>
      <SiteFooter />
    </div>
  )
}
