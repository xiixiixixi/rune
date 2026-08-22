import type { Metadata } from "next"
import Link from "next/link"
import Image from "next/image"

export const metadata: Metadata = {
  title: "Privacy Policy - Rune",
  description: "Privacy policy for Rune, the local-first screenshot tool for macOS.",
  alternates: {
    canonical: "/privacy",
  },
}

export default function PrivacyPolicy() {
  return (
    <div className="min-h-screen bg-[#faf9f7] text-[#1a1a1a]/80">
      <header>
        <div className="max-w-[600px] mx-auto px-6 h-12 flex items-center">
          <Link href="/" className="flex items-center gap-2 text-[13px] font-medium text-[#1a1a1a]/70 tracking-[-0.01em]">
            <Image src="/logo.png" alt="Rune" width={18} height={18} className="rounded-[3px]" />
            Rune
          </Link>
        </div>
      </header>

      <main className="max-w-[600px] mx-auto px-6 py-16">
        <h1 className="text-2xl font-semibold tracking-[-0.03em] text-[#1a1a1a] mb-2">
          Privacy Policy
        </h1>
        <p className="text-[12px] text-[#1a1a1a]/25 mb-12">
          Last updated: June 2, 2026
        </p>

        <div className="space-y-10 text-[14px] leading-[1.7] text-[#1a1a1a]/50">
          <section>
            <h2 className="text-[15px] font-medium text-[#1a1a1a]/70 mb-3">Overview</h2>
            <p>
              Rune is a local-first screenshot tool for macOS. We are committed
              to protecting your privacy. This policy explains what data we collect and how
              we use it.
            </p>
          </section>

          <section>
            <h2 className="text-[15px] font-medium text-[#1a1a1a]/70 mb-3">Data Collection</h2>
            <p className="mb-3">
              <strong className="text-[#1a1a1a]/70">Rune does not collect, store, or transmit
              any personal data.</strong> All screenshots and annotations are processed locally
              on your device and never leave your computer.
            </p>
            <p>
              The application does not require an account, login, or any form of registration.
            </p>
          </section>

          <section>
            <h2 className="text-[15px] font-medium text-[#1a1a1a]/70 mb-3">Website Analytics</h2>
            <p>
              This website does not use analytics, cookies, or tracking identifiers.
            </p>
          </section>

          <section>
            <h2 className="text-[15px] font-medium text-[#1a1a1a]/70 mb-3">Third-Party Services</h2>
            <p>
              Rune does not integrate with any third-party services that collect user
              data. The application is distributed via its official release page.
            </p>
          </section>

          <section>
            <h2 className="text-[15px] font-medium text-[#1a1a1a]/70 mb-3">Licensing</h2>
            <p>
              Rune includes open-source components under their respective licenses.
              Required copyright and license notices are available on{" "}
              <a
                href="https://github.com/xiixiixixi/rune"
                target="_blank"
                rel="noopener noreferrer"
                className="text-[#1a1a1a]/70 underline underline-offset-4 hover:text-[#1a1a1a]/90 transition-colors"
              >
                GitHub
              </a>{" "}
              to verify these claims.
            </p>
          </section>

          <section>
            <h2 className="text-[15px] font-medium text-[#1a1a1a]/70 mb-3">Contact</h2>
            <p>
              If you have questions about this privacy policy, open an issue on{" "}
              <a
                href="https://github.com/xiixiixixi/rune/issues"
                target="_blank"
                rel="noopener noreferrer"
                className="text-[#1a1a1a]/70 underline underline-offset-4 hover:text-[#1a1a1a]/90 transition-colors"
              >
                GitHub
              </a>
              .
            </p>
          </section>
        </div>

        <div className="mt-16 pt-6 border-t border-[#1a1a1a]/[0.06]">
          <Link
            href="/"
            className="text-[12px] text-[#1a1a1a]/25 hover:text-[#1a1a1a]/50 transition-colors"
          >
            &larr; Home
          </Link>
        </div>
      </main>
    </div>
  )
}
