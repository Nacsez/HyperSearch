import { Component, ReactNode } from "react";

interface AppErrorBoundaryProps {
  children: ReactNode;
}

interface AppErrorBoundaryState {
  error: string | null;
}

export class AppErrorBoundary extends Component<AppErrorBoundaryProps, AppErrorBoundaryState> {
  state: AppErrorBoundaryState = { error: null };

  static getDerivedStateFromError(error: unknown): AppErrorBoundaryState {
    return { error: error instanceof Error ? error.message : String(error) };
  }

  render() {
    if (this.state.error) {
      return (
        <main className="app-crash-panel">
          <section>
            <p className="section-card__eyebrow">Interface recovery</p>
            <h1>HyperSearch caught a UI rendering error</h1>
            <p>
              The last transaction returned data the interface could not render safely. The backend is still running.
              Refresh this session or open a new session to continue.
            </p>
            <pre>{this.state.error}</pre>
            <button type="button" className="button button--primary" onClick={() => window.location.reload()}>
              Reload Session
            </button>
          </section>
        </main>
      );
    }
    return this.props.children;
  }
}
