import { useEffect, useRef, type ReactNode } from "react";
import { useRouterState } from "@tanstack/react-router";

/** Enhances live content without delaying navigation or remounting forms. */
export function SiteMotion({ children }: { children: ReactNode }) {
  const root = useRef<HTMLDivElement>(null);
  const location = useRouterState({ select: (state) => state.resolvedLocation?.href });
  useEffect(() => {
    const el = root.current;
    if (!el) return;
    const preference = window.matchMedia("(prefers-reduced-motion: reduce)");
    const seen = new WeakSet<Element>();
    const animations = new Set<Animation>();
    let observer: IntersectionObserver | undefined;
    let mutations: MutationObserver | undefined;
    const animate = (target: Element, delay = 0) => {
      if (preference.matches || typeof target.animate !== "function") return;
      const animation = target.animate(
        [{ opacity: 0, transform: "translateY(12px)" }, { opacity: 1, transform: "translateY(0)" }],
        { duration: 420, delay, easing: "cubic-bezier(.22,1,.36,1)" },
      );
      animations.add(animation);
      animation.finished.then(() => animations.delete(animation)).catch(() => animations.delete(animation));
    };
    const scan = () => {
      if (!observer) return;
      el.querySelectorAll("main section, main .surface, main form, [role='tabpanel'], .auth-content > *").forEach((target) => {
        if (seen.has(target)) return;
        seen.add(target);
        observer?.observe(target);
      });
    };
    const stop = () => {
      observer?.disconnect();
      mutations?.disconnect();
      animations.forEach((animation) => animation.cancel());
      animations.clear();
    };
    const start = () => {
      stop();
      if (preference.matches || typeof IntersectionObserver === "undefined") return;
      observer = new IntersectionObserver((entries) => {
        let stagger = 0;
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          observer?.unobserve(entry.target);
          animate(entry.target, Math.min(stagger++ * 45, 180));
        });
      }, { threshold: 0.05 });
      scan();
      mutations = new MutationObserver(scan);
      mutations.observe(el, { childList: true, subtree: true });
    };
    start();
    preference.addEventListener("change", start);
    return () => { stop(); preference.removeEventListener("change", start); };
  }, [location]);
  return (
    <div ref={root} className="site-motion">
      {children}
      <div key={location} className="page-wipe" aria-hidden="true">
        <span className="page-wipe-glow" />
      </div>
    </div>
  );
}