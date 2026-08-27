import type { Metadata } from "next"
import { Check, LockKeyhole } from "lucide-react"
import { SiteFooter, SiteHeader } from "@/components/site-shell"

export const metadata: Metadata = {
  title: "Privacy Policy — Rune",
  description: "Privacy policy for Rune, the local-first screen capture tool for macOS.",
  alternates: { canonical: "/privacy" },
}

const promises = [
  "Screenshots and recordings are processed on your Mac.",
  "Rune does not require an account or login.",
  "The website does not use cookies or tracking identifiers.",
]

export default function PrivacyPolicy() {
  return (
    <div className="min-h-dvh bg-background text-foreground">
      <SiteHeader />
      <main id="main-content" className="pt-16">
        <header className="mx-auto max-w-3xl px-6 pb-12 pt-20 text-center sm:pt-28">
          <span className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-accent text-primary">
            <LockKeyhole className="size-7" aria-hidden="true" />
          </span>
          <h1 className="mt-6 text-balance text-5xl font-semibold sm:text-6xl">Your captures stay on your Mac.</h1>
          <p className="mx-auto mt-5 max-w-xl text-pretty text-lg leading-relaxed text-muted-foreground">
            Rune is built around a simple privacy boundary: your screen content is not an online service.
          </p>
          <p className="mt-4 font-mono text-xs text-muted-foreground">Last updated June 2, 2026</p>
        </header>

        <section className="mx-auto max-w-3xl px-6 pb-10">
          <div className="glass-surface rounded-2xl border p-5 shadow-lg sm:p-6">
            <ul className="space-y-4">
              {promises.map((promise) => (
                <li key={promise} className="flex items-start gap-3 text-sm leading-relaxed">
                  <span className="mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full bg-primary text-primary-foreground">
                    <Check className="size-3" aria-hidden="true" />
                  </span>
                  {promise}
                </li>
              ))}
            </ul>
          </div>
        </section>

        <article className="mx-auto max-w-3xl space-y-12 px-6 pb-24 pt-10 text-base leading-relaxed text-muted-foreground">
          <PolicySection title="Overview">
            Rune is a local-first screen capture tool for macOS. This policy explains what the app and this website do with data.
          </PolicySection>

          <PolicySection title="Data collection">
            <strong className="font-semibold text-foreground">Rune does not collect, store, or transmit personal data.</strong> Screenshots, recordings, annotations, OCR, and image processing happen locally on your device. The app does not require registration.
          </PolicySection>

          <PolicySection title="Website analytics">
            This website does not use analytics, cookies, advertising pixels, or tracking identifiers.
          </PolicySection>

          <PolicySection title="Third-party services">
            Rune does not connect your captures to third-party services. The app is distributed from its official GitHub release page, which is governed by GitHub&apos;s own terms and privacy policy.
          </PolicySection>

          <PolicySection title="Open-source licenses">
            Rune includes open-source components under their respective licenses. Copyright notices and license terms are available in the{" "}
            <a href="https://github.com/xiixiixixi/rune" target="_blank" rel="noopener noreferrer" className="font-medium text-primary hover:underline">
              source repository
            </a>.
          </PolicySection>

          <PolicySection title="Contact">
            Questions about this policy can be filed in the{" "}
            <a href="https://github.com/xiixiixixi/rune/issues" target="_blank" rel="noopener noreferrer" className="font-medium text-primary hover:underline">
              public issue tracker
            </a>.
          </PolicySection>
        </article>
      </main>
      <SiteFooter />
    </div>
  )
}

function PolicySection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="grid gap-3 border-t border-border/70 pt-7 sm:grid-cols-[11rem_1fr] sm:gap-8">
      <h2 className="font-semibold text-foreground">{title}</h2>
      <p className="text-pretty">{children}</p>
    </section>
  )
}
