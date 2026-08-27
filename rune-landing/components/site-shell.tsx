import type { ReactNode } from "react"
import Image from "next/image"
import Link from "next/link"

export function SiteHeader({ actions }: { actions?: ReactNode }) {
  return (
    <header className="glass-nav fixed inset-x-0 top-0 z-50 border-b">
      <a
        href="#main-content"
        className="absolute left-4 top-3 -translate-y-20 rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground focus:translate-y-0 focus:outline-2 focus:outline-offset-2 focus:outline-primary"
      >
        Skip to content
      </a>
      <div className="mx-auto flex h-16 max-w-6xl items-center justify-between px-6">
        <Link href="/" className="flex items-center gap-2.5 rounded-md focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary">
          <Image src="/logo.png" alt="" width={24} height={24} className="rounded-md" priority />
          <span className="text-sm font-semibold text-foreground">Rune</span>
        </Link>

        <div className="flex items-center gap-5">
          <nav aria-label="Primary" className="hidden items-center gap-5 sm:flex">
            <Link href="/changelog" className="text-sm text-muted-foreground hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary">
              Changelog
            </Link>
            <Link href="/privacy" className="text-sm text-muted-foreground hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary">
              Privacy
            </Link>
            <a
              href="https://github.com/xiixiixixi/rune"
              target="_blank"
              rel="noopener noreferrer"
              className="text-sm text-muted-foreground hover:text-foreground focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-primary"
            >
              GitHub
            </a>
          </nav>
          {actions}
        </div>
      </div>
    </header>
  )
}

export function SiteFooter() {
  return (
    <footer className="border-t border-border/70">
      <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-4 px-6 py-8 sm:flex-row">
        <div className="flex items-center gap-2.5">
          <Image src="/logo.png" alt="" width={18} height={18} className="rounded opacity-60" />
          <p className="text-xs text-muted-foreground">© {new Date().getFullYear()} Rune</p>
        </div>
        <nav aria-label="Footer" className="flex items-center gap-5">
          <Link href="/" className="text-xs text-muted-foreground hover:text-foreground">Home</Link>
          <Link href="/changelog" className="text-xs text-muted-foreground hover:text-foreground">Changelog</Link>
          <Link href="/privacy" className="text-xs text-muted-foreground hover:text-foreground">Privacy</Link>
        </nav>
      </div>
    </footer>
  )
}
