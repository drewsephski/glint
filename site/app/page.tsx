import { Agents } from "@/components/site/agents";
import { Closing, Header } from "@/components/site/chrome";
import { Features } from "@/components/site/features";
import { Hero } from "@/components/site/hero";
import { Faq, GetStarted, Privacy, SourceBuilds } from "@/components/site/info";
import { Lanes } from "@/components/site/lanes";
import { ScrollProgress } from "@/components/ui/scroll-progress";

export default function Home() {
  return (
    <>
      <ScrollProgress />
      <Header />
      <main id="main" className="flex-1">
        <Hero />
        <Lanes />
        <Features />
        <Agents />
        <Privacy />
        <GetStarted />
        <SourceBuilds />
        <Faq />
      </main>
      <Closing />
    </>
  );
}
