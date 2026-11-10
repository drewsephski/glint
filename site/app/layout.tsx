import type { Metadata, Viewport } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";
import { MotionProvider } from "@/components/site/motion-provider";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

const title = "Glint: screen recorder and editor for macOS, built for agents";
const description =
  "Glint is a native macOS screen recorder and editor. It turns a raw take into a product demo with zooms, a smooth cursor, tighter pacing and captions, and every step is available to Claude Code, Codex and other MCP agents.";

export const metadata: Metadata = {
  metadataBase: new URL("https://drewsephski.github.io/glint/"),
  title,
  description,
  icons: { icon: "/glint/icon.svg", apple: "/glint/apple-touch-icon.png" },
  openGraph: {
    type: "website",
    siteName: "Glint",
    title,
    description:
      "Record a take and get a finished product demo. Zooms, smooth cursor, tightened pauses, captions and optional narration, with the same tools available to your AI agents.",
    images: [
      {
        url: "https://drewsephski.github.io/glint/img/og.jpg",
        width: 1200,
        height: 630,
        alt: "The Glint editor with a preview, scene list and timeline lanes for video, zoom, captions and voice",
      },
    ],
  },
  twitter: { card: "summary_large_image" },
};

export const viewport: Viewport = {
  themeColor: "#0e1217",
  colorScheme: "dark",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      className={`${geistSans.variable} ${geistMono.variable} dark h-full antialiased`}
    >
      <body className="flex min-h-full flex-col">
        <MotionProvider>{children}</MotionProvider>
      </body>
    </html>
  );
}
