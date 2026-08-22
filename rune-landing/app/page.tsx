import Image from "next/image"
import Link from "next/link"
import { ArrowUpRight, Shield, Zap } from "lucide-react"
import { DownloadDropdown } from "@/components/download-dropdown"
import { getLatestRelease } from "@/lib/downloads"
import { StarCount } from "@/components/star-count"
import { EditorPreview } from "@/components/editor-demo"

export default async function Home() {
  const release = await getLatestRelease()
  return (
    <div className="min-h-screen w-full bg-[#fafaf9] text-[#111] selection:bg-[#e78a53]/20">
      {/* Nav */}
      <nav className="fixed top-0 inset-x-0 z-50 h-14 backdrop-blur-xl bg-[#fafaf9]/80 border-b border-[#111]/[0.04]">
        <div className="max-w-[1080px] mx-auto h-full px-6 flex items-center justify-between">
          <a href="/" className="flex items-center gap-2.5">
            <Image src="/logo.png" alt="" width={22} height={22} className="rounded-[5px]" />
            <span className="text-[13px] font-semibold tracking-[-0.01em] text-[#111]/70">
              Rune
            </span>
          </a>
          <div className="flex items-center gap-6">
            <Link
              href="/changelog"
              className="text-[12px] text-[#111]/30 hover:text-[#111]/60 transition-colors hidden sm:block"
            >
              Changelog
            </Link>
            <a
              href="https://github.com/xiixiixixi/rune"
              target="_blank"
              rel="noopener noreferrer"
              className="text-[12px] text-[#111]/30 hover:text-[#111]/60 transition-colors hidden sm:block"
            >
              <StarCount />
            </a>
            <DownloadDropdown release={release} source="navbar" size="sm" showLabel={false} />
          </div>
        </div>
      </nav>

      {/* Hero */}
      <main className="pt-14">
        <section className="flex flex-col items-center px-6 pt-28 pb-20 sm:pt-36 sm:pb-24">
          <h1 className="text-center text-[clamp(36px,6.5vw,68px)] leading-[1.02] font-bold tracking-[-0.04em] text-[#111] max-w-[740px] text-balance">
            Capture your screen,{" "}
            <span className="text-[#111]/30">make&nbsp;it&nbsp;beautiful</span>
          </h1>

          <p className="text-center text-[16px] leading-[1.7] text-[#111]/40 mt-6 max-w-[460px] text-pretty">
            Screenshots, recordings, annotations, and effects — all in one local&#8209;first macOS app. No account, no cloud, no subscription.
          </p>

          <div className="flex items-center gap-3 mt-10">
            <DownloadDropdown release={release} source="hero" />
            <a
              href="https://github.com/xiixiixixi/rune"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1.5 px-5 h-11 text-[13px] font-medium text-[#111]/35 hover:text-[#111]/60 border border-[#111]/[0.08] hover:border-[#111]/[0.15] rounded-lg transition-all"
            >
              Source
              <ArrowUpRight className="h-3.5 w-3.5" />
            </a>
          </div>

          <div className="flex flex-wrap justify-center items-center gap-4 sm:gap-6 mt-8 text-[11px] text-[#111]/25">
            <span className="flex items-center gap-1.5">
              <span className="h-1 w-1 rounded-full bg-[#111]/15" />
              macOS 14+
            </span>
            <span className="flex items-center gap-1.5">
              <span className="h-1 w-1 rounded-full bg-[#111]/15" />
              Apple Silicon &amp; Intel
            </span>
            <span className="flex items-center gap-1.5">
              <span className="h-1 w-1 rounded-full bg-[#111]/15" />
              Local-first &amp; private
            </span>
          </div>
        </section>

        {/* Editor preview — the hero product shot, largest visual on the page */}
        <section className="max-w-[960px] mx-auto px-6 pb-32">
          <div className="rounded-2xl border border-[#111]/[0.06] bg-[#111]/[0.02] p-2 shadow-[0_8px_40px_rgba(0,0,0,0.04)] overflow-hidden">
            <EditorPreview />
          </div>
        </section>

        {/* ─── PRIMARY FEATURES — full-width with visuals ─── */}

        {/* 1. Capture — the core, gets the most space */}
        <section className="border-t border-[#111]/[0.06] py-20 sm:py-28">
          <div className="max-w-[960px] mx-auto px-6">
            <div className="flex flex-col md:flex-row md:items-center gap-12 md:gap-20">
              <div className="flex-1 min-w-0">
                <h2 className="text-[28px] sm:text-[36px] font-bold tracking-[-0.03em] text-[#111] mb-5">
                  Capture everything
                </h2>
                <p className="text-[15px] leading-[1.8] text-[#111]/40 max-w-[400px] mb-8">
                  Region, fullscreen, or window — pick how you want to capture. A floating preview appears after every shot so you can edit, copy, or drag it straight into another app.
                </p>
                <div className="flex flex-wrap gap-x-6 gap-y-3">
                  <FeatureBullet label="Region capture" />
                  <FeatureBullet label="Window capture" />
                  <FeatureBullet label="Fullscreen" />
                  <FeatureBullet label="Floating preview" />
                  <FeatureBullet label="OCR text extraction" />
                  <FeatureBullet label="Color picker" />
                </div>
              </div>
              <div className="flex-1 flex justify-center">
                <MockScreenshotPreview />
              </div>
            </div>
          </div>
        </section>

        {/* 2. Recording — second hero feature, reversed layout, shaded */}
        <section className="border-t border-[#111]/[0.06] bg-[#111]/[0.015] py-20 sm:py-28">
          <div className="max-w-[960px] mx-auto px-6">
            <div className="flex flex-col md:flex-row-reverse md:items-center gap-12 md:gap-20">
              <div className="flex-1 min-w-0">
                <h2 className="text-[28px] sm:text-[36px] font-bold tracking-[-0.03em] text-[#111] mb-5">
                  Screen recording,<br className="hidden sm:block" /> built right&nbsp;in
                </h2>
                <p className="text-[15px] leading-[1.8] text-[#111]/40 max-w-[400px] mb-8">
                  Record your screen as MP4 with a single shortcut. Pause, resume, restart, or discard — all from a minimal floating pill that stays out of the capture.
                </p>
                <div className="flex flex-wrap gap-x-6 gap-y-3">
                  <FeatureBullet label="MP4 capture" />
                  <FeatureBullet label="Pause & resume" />
                  <FeatureBullet label="Restart recording" />
                  <FeatureBullet label="24 / 30 / 60 fps" />
                  <FeatureBullet label="Cursor toggle" />
                  <FeatureBullet label="Audio capture" />
                </div>
              </div>
              <div className="flex-1 flex justify-center">
                <MockRecordingPill />
              </div>
            </div>
          </div>
        </section>

        {/* 3. Effects — third hero feature, full visual */}
        <section className="border-t border-[#111]/[0.06] py-20 sm:py-28">
          <div className="max-w-[960px] mx-auto px-6">
            <div className="flex flex-col md:flex-row md:items-center gap-12 md:gap-20">
              <div className="flex-1 min-w-0">
                <h2 className="text-[28px] sm:text-[36px] font-bold tracking-[-0.03em] text-[#111] mb-5">
                  Make it look good
                </h2>
                <p className="text-[15px] leading-[1.8] text-[#111]/40 max-w-[400px] mb-8">
                  Add padding, corner radius, and shadows. Pick from solid colors, gradients, macOS wallpapers, or drop in your own image as a background.
                </p>
                <div className="flex flex-wrap gap-x-6 gap-y-3">
                  <FeatureBullet label="Adjustable padding" />
                  <FeatureBullet label="Corner radius" />
                  <FeatureBullet label="Drop shadows" />
                  <FeatureBullet label="Solid colors" />
                  <FeatureBullet label="Gradients" />
                  <FeatureBullet label="macOS wallpapers" />
                  <FeatureBullet label="Custom images" />
                </div>
              </div>
              <div className="flex-1 flex justify-center">
                <MockEffectsPanel />
              </div>
            </div>
          </div>
        </section>

        {/* ─── SECONDARY FEATURES — compact text-only grid, less visual weight ─── */}
        <section className="border-t border-[#111]/[0.06] bg-[#111]/[0.015] py-20 sm:py-24">
          <div className="max-w-[960px] mx-auto px-6">
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-16 gap-y-14">
              <TextFeature
                title="Annotate with purpose"
                description="Arrows, shapes, text, numbered badges, blur, and spotlight. Each tool has a single-key shortcut so you never leave the keyboard."
                features={["Arrows", "Rectangles & circles", "Text with fonts", "Numbered badges", "Blur regions", "Spotlight"]}
              />
              <TextFeature
                title="Crop with precision"
                description="Draggable corner and edge handles with a rule-of-thirds grid. Works on both screenshots and recordings — crop is applied on export so your annotations stay editable."
                features={["Corner & edge handles", "Rule-of-thirds grid", "Non-destructive", "Works on video"]}
              />
              <TextFeature
                title="Edit recordings before you share"
                description="Full video editor with trim timeline, thumbnail strip, and transport controls. Add backgrounds and effects, then export with your look baked in."
                features={["Trim timeline", "Thumbnail strip", "Background picker", "Video effects", "MP4 export"]}
              />
              <TextFeature
                title="Stay in flow"
                description="Drag the floating preview into Figma, Slack, or Finder. Pin screenshots as always-on-top windows. Auto-apply your default effects on every capture."
                features={["Drag into any app", "Pin to screen", "Always-on-top", "Auto-apply defaults"]}
              />
            </div>
          </div>
        </section>

        {/* ─── VALUES — local-first, fast, private ─── */}
        <section className="border-t border-[#111]/[0.06] py-20 sm:py-24">
          <div className="max-w-[960px] mx-auto px-6">
            <div className="grid grid-cols-1 sm:grid-cols-3 gap-12">
              <ValueProp
                icon={<Shield className="h-5 w-5" />}
                title="Local-first"
                description="Everything stays on your Mac. No uploads, no accounts, no telemetry."
              />
              <ValueProp
                icon={<Zap className="h-5 w-5" />}
                title="Fast"
                description="Native Swift app. Launches instantly, captures in milliseconds."
              />
              <ValueProp
                icon={<ArrowUpRight className="h-5 w-5" />}
                title="Private by design"
                description="Screenshots and recordings stay on your Mac."
              />
            </div>
          </div>
        </section>

        {/* Shortcuts */}
        <section className="max-w-[520px] mx-auto px-6 pb-28 pt-4">
          <h2 className="text-[13px] font-semibold text-[#111]/25 tracking-wide uppercase text-center mb-8">
            Keyboard shortcuts
          </h2>
          <div className="divide-y divide-[#111]/[0.06] border border-[#111]/[0.06] rounded-xl overflow-hidden bg-white">
            <Shortcut label="Capture region" keys={["⌘", "⇧", "4"]} />
            <Shortcut label="Capture screen" keys={["⌘", "⇧", "3"]} />
            <Shortcut label="Capture window" keys={["⌘", "⇧", "5"]} />
            <Shortcut label="Record screen" keys={["⌘", "⇧", "2"]} />
            <Shortcut label="OCR text scan" keys={["⌘", "⇧", "O"]} />
            <Shortcut label="Color picker" keys={["⌘", "⇧", "C"]} />
          </div>
        </section>

        {/* CTA */}
        <section className="border-t border-[#111]/[0.06] py-24">
          <div className="text-center px-6">
            <h2 className="text-[24px] sm:text-[28px] font-bold tracking-[-0.03em] text-[#111] mb-3">
              Ready to try it?
            </h2>
            <p className="text-[15px] text-[#111]/35 mb-8 max-w-[340px] mx-auto text-pretty">
              No account. No subscription. Just a better way to capture your screen.
            </p>
            <div className="flex flex-col items-center gap-4">
              <DownloadDropdown release={release} source="cta" />
            </div>
          </div>
        </section>
      </main>

      {/* Footer */}
      <footer className="border-t border-[#111]/[0.04]">
        <div className="max-w-[1080px] mx-auto px-6 py-6 flex flex-col sm:flex-row items-center justify-between gap-4">
          <div className="flex items-center gap-2.5">
            <Image src="/logo.png" alt="" width={16} height={16} className="rounded-[3px] opacity-40" />
            <p className="text-[11px] text-[#111]/20">
              &copy; {new Date().getFullYear()} Rune
            </p>
          </div>
          <nav className="flex items-center gap-5">
            <Link
              href="/changelog"
              className="text-[11px] text-[#111]/20 hover:text-[#111]/45 transition-colors"
            >
              Changelog
            </Link>
            <Link
              href="/privacy"
              className="text-[11px] text-[#111]/20 hover:text-[#111]/45 transition-colors"
            >
              Privacy
            </Link>
            <a
              href="https://github.com/xiixiixixi/rune"
              target="_blank"
              rel="noopener noreferrer"
              className="text-[11px] text-[#111]/20 hover:text-[#111]/45 transition-colors"
            >
              GitHub
            </a>
          </nav>
        </div>
      </footer>
    </div>
  )
}

/* ─── Primary feature mocks — large, varied visual weight ─── */

function MockScreenshotPreview() {
  return (
    <div className="w-full max-w-[360px]">
      <div className="rounded-lg bg-white border border-[#111]/[0.08] shadow-[0_2px_16px_rgba(0,0,0,0.06)] overflow-hidden">
        <div className="h-8 bg-[#fafafa] border-b border-[#111]/[0.06] flex items-center px-3 gap-[6px]">
          <span className="w-2.5 h-2.5 rounded-full bg-[#ff5f57]" />
          <span className="w-2.5 h-2.5 rounded-full bg-[#febc2e]" />
          <span className="w-2.5 h-2.5 rounded-full bg-[#28c840]" />
          <span className="flex-1 text-center text-[10px] text-[#111]/30">Preview</span>
        </div>
        <div className="p-4">
          <div
            className="aspect-[16/10] rounded-md overflow-hidden flex items-center justify-center"
            style={{ background: "linear-gradient(135deg, #ec4899, #8b5cf6, #3b82f6)", padding: "10%" }}
          >
            <div className="w-full h-full rounded bg-[#1a1a2e] flex items-center justify-center">
              <div className="text-center">
                <div className="text-[20px] mb-1">⌘</div>
                <div className="text-[10px] text-white/50">screenshot.png</div>
              </div>
            </div>
          </div>
        </div>
        <div className="px-4 pb-3 flex gap-2">
          <span className="text-[10px] text-[#111]/30 bg-[#111]/[0.04] px-2.5 py-1 rounded">Edit</span>
          <span className="text-[10px] text-[#111]/30 bg-[#111]/[0.04] px-2.5 py-1 rounded">Copy</span>
          <span className="text-[10px] text-[#111]/30 bg-[#111]/[0.04] px-2.5 py-1 rounded">Pin</span>
        </div>
      </div>
    </div>
  )
}

function MockRecordingPill() {
  return (
    <div className="flex flex-col items-center gap-5">
      <div className="inline-flex items-center gap-3 bg-[#1a1a1a] rounded-full px-5 py-3 shadow-[0_8px_32px_rgba(0,0,0,0.25)]">
        <div className="flex items-center gap-2">
          <span className="relative flex h-2.5 w-2.5">
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-400 opacity-75" />
            <span className="relative inline-flex h-2.5 w-2.5 rounded-full bg-red-500" />
          </span>
          <span className="text-[13px] font-mono text-white/80 tabular-nums">02:34</span>
        </div>
        <span className="h-4 w-px bg-white/10" />
        <div className="flex items-center gap-1.5">
          <span className="h-7 w-7 rounded-full bg-white/10 flex items-center justify-center text-[11px] text-white/60">⏸</span>
          <span className="h-7 w-7 rounded-full bg-white/10 flex items-center justify-center text-[11px] text-white/60">■</span>
          <span className="h-7 w-7 rounded-full bg-white/10 flex items-center justify-center text-[11px] text-white/60">↻</span>
          <span className="h-7 w-7 rounded-full bg-white/10 flex items-center justify-center text-[11px] text-white/60">✕</span>
        </div>
      </div>
      <p className="text-[11px] text-[#111]/20">Floating recording controls</p>
    </div>
  )
}

function MockEffectsPanel() {
  const gradients = [
    "linear-gradient(135deg, #a8edea, #fed6e3)",
    "linear-gradient(135deg, #3b82f6, #8b5cf6)",
    "linear-gradient(135deg, #f97316, #ec4899)",
    "linear-gradient(135deg, #ec4899, #8b5cf6, #3b82f6)",
    "linear-gradient(135deg, #22c55e, #06b6d4)",
    "linear-gradient(135deg, #eab308, #f97316)",
  ]
  return (
    <div className="w-full max-w-[260px]">
      <div className="rounded-lg bg-white border border-[#111]/[0.08] shadow-[0_2px_16px_rgba(0,0,0,0.06)] p-5">
        <div className="text-[10px] font-semibold text-[#111]/25 tracking-widest uppercase mb-4">Effects</div>
        <SliderMock label="Padding" value="8%" progress={40} />
        <SliderMock label="Corner Radius" value="18" progress={45} />
        <SliderMock label="Shadow" value="36%" progress={55} />
        <div className="mt-5">
          <div className="text-[10px] font-semibold text-[#111]/25 tracking-widest uppercase mb-3">Background</div>
          <div className="grid grid-cols-6 gap-1.5">
            {gradients.map((g, i) => (
              <div
                key={i}
                className="w-8 h-8 rounded"
                style={{
                  background: g,
                  border: i === 3 ? "2px solid #3b82f6" : "1px solid rgba(0,0,0,0.06)",
                  boxShadow: i === 3 ? "0 0 0 2px rgba(59,130,246,0.2)" : "none",
                }}
              />
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}

function SliderMock({ label, value, progress }: { label: string; value: string; progress: number }) {
  return (
    <div className="mb-3">
      <div className="flex justify-between mb-1.5">
        <span className="text-[11px] text-[#111]/35">{label}</span>
        <span className="text-[11px] text-[#111]/50 font-medium">{value}</span>
      </div>
      <div className="h-1 bg-[#111]/[0.06] rounded-full overflow-hidden">
        <div className="h-full bg-blue-500 rounded-full" style={{ width: `${progress}%` }} />
      </div>
    </div>
  )
}

/* ─── Secondary features — text only, compact, less weight ─── */

function TextFeature({ title, description, features }: { title: string; description: string; features: string[] }) {
  return (
    <div>
      <h3 className="text-[18px] font-bold tracking-[-0.02em] text-[#111] mb-2.5">{title}</h3>
      <p className="text-[14px] leading-[1.7] text-[#111]/35 mb-5">{description}</p>
      <div className="flex flex-wrap gap-x-5 gap-y-2">
        {features.map((f) => (
          <FeatureBullet key={f} label={f} />
        ))}
      </div>
    </div>
  )
}

/* ─── Shared ─── */

function FeatureBullet({ label }: { label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-[13px] text-[#111]/40">
      <span className="h-1 w-1 rounded-full bg-[#e78a53]" />
      {label}
    </span>
  )
}

function ValueProp({ icon, title, description }: { icon: React.ReactNode; title: string; description: string }) {
  return (
    <div className="text-center">
      <div className="h-10 w-10 rounded-lg bg-[#111]/[0.03] flex items-center justify-center text-[#111]/40 mx-auto mb-4">
        {icon}
      </div>
      <h3 className="text-[14px] font-semibold text-[#111]/70 mb-1.5">{title}</h3>
      <p className="text-[13px] leading-[1.6] text-[#111]/35">{description}</p>
    </div>
  )
}

function Shortcut({ label, keys }: { label: string; keys: string[] }) {
  return (
    <div className="flex items-center justify-between px-5 py-3.5">
      <span className="text-[13px] text-[#111]/45">{label}</span>
      <div className="flex items-center gap-1">
        {keys.map((k, i) => (
          <kbd
            key={i}
            className="inline-flex items-center justify-center h-6 min-w-[24px] px-1.5 text-[11px] font-medium text-[#111]/50 bg-[#fafaf9] border border-[#111]/[0.08] rounded-md shadow-[0_1px_0_rgba(0,0,0,0.04)]"
          >
            {k}
          </kbd>
        ))}
      </div>
    </div>
  )
}
