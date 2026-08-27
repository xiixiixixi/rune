import type React from "react"
import type { Metadata } from "next"
import "./globals.css"

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL ?? "https://github.com/xiixiixixi/rune"

export const metadata: Metadata = {
  title: "Rune — Screenshots & screen recording for macOS",
  description:
    "Local-first screen capture tool for macOS. Screenshots, recordings, annotations, and effects — all in one private app. No account needed.",
  metadataBase: new URL(siteUrl),
  alternates: {
    canonical: "/",
  },
  keywords: [
    "screenshot",
    "screen recording",
    "macOS",
    "screen capture",
    "local-first",
    "CleanShot alternative",
    "annotation",
    "private screenshot tool",
    "video editor",
    "MP4 recording",
  ],
  openGraph: {
    title: "Rune — Screenshots & screen recording for macOS",
    description:
      "Local-first screen capture tool for macOS. Screenshots, recordings, annotations, and effects — all in one private app.",
    url: siteUrl,
    siteName: "Rune",
    locale: "en_US",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "Rune — Screenshots & screen recording for macOS",
    description:
      "Local-first screen capture tool for macOS. Screenshots, recordings, annotations, and effects — all in one private app.",
  },
  robots: {
    index: true,
    follow: true,
    googleBot: {
      index: true,
      follow: true,
      "max-video-preview": -1,
      "max-image-preview": "large",
      "max-snippet": -1,
    },
  },
}

const jsonLd = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Rune",
  applicationCategory: "UtilitiesApplication",
  operatingSystem: "macOS",
  description:
    "Local-first screen capture tool for macOS. Screenshots, recordings, annotations, and effects — all in one private app.",
  url: siteUrl,
  downloadUrl: "https://github.com/xiixiixixi/rune/releases",
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en">
      <head>
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
        />
      </head>
      <body className="antialiased">{children}</body>
    </html>
  )
}
