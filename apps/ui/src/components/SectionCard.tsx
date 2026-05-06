import type { PropsWithChildren, ReactNode } from "react";

interface SectionCardProps extends PropsWithChildren {
  title: string;
  subtitle?: string;
  actions?: ReactNode;
}

export function SectionCard({ title, subtitle, actions, children }: SectionCardProps) {
  return (
    <section className="section-card">
      <header className="section-card__header">
        <div>
          <p className="section-card__eyebrow">{subtitle ?? "Console"}</p>
          <h2>{title}</h2>
        </div>
        <div>{actions}</div>
      </header>
      <div className="section-card__body">{children}</div>
    </section>
  );
}
