// Overview task ticker — port of TickerView (V2) from IslandViewContent.swift.
// Three rows: completed (A), current → completed (B), incoming (C).

import { h, svg } from "./dom";
import { ICONS } from "./icons";
import type { AgentTask } from "../core/state";

const COMPLETED_SCALE = 11.5 / 13; // 0.885
const CURVE = "cubic-bezier(0.4, 0, 0.2, 1)";

interface Row {
  el: HTMLElement;
  chevron: SVGElement;
  check: SVGElement;
  shimmer: HTMLElement;
  dim: HTMLElement;
}

function makeRow(): Row {
  const chevron = svg(ICONS.chevronRight, 9, { stroke: 2.4 });
  const check = svg(ICONS.check, 8, { stroke: 2.2 });
  check.style.opacity = "0";
  const shimmer = h("span", { class: "tick-text shimmer" });
  const dim = h("span", {
    class: "tick-text",
    style: "position:absolute;left:0;right:0;color:#6b7079;opacity:0",
  });
  const textWrap = h("span", { style: "position:relative;flex:1 1 auto;min-width:0" }, shimmer, dim);
  const el = h(
    "div",
    { class: "ticker-row" },
    h("span", { class: "tick-icon", style: "position:relative" }, chevron, check),
    textWrap,
  );
  return { el, chevron, check, shimmer, dim };
}

function setText(row: Row, text: string) {
  row.shimmer.textContent = text;
  row.dim.textContent = text;
}

/** phase 0 = current (shimmering, full size), 1 = completed (dim, shifted up-left). */
function setPhase(row: Row, phase: number, y: number, durationMs: number) {
  const scale = 1 - phase * (1 - COMPLETED_SCALE);
  const x = -phase * 10;
  const t = durationMs > 0 ? `transform ${durationMs}ms ${CURVE}` : "none";
  row.el.style.transition = t;
  row.el.style.transform = `translate(${x}px, ${y}px) scale(${scale})`;

  const half = durationMs / 2;
  row.chevron.style.transition = durationMs > 0 ? `opacity ${half}ms linear` : "none";
  row.chevron.style.opacity = phase >= 0.5 ? "0" : "1";
  row.check.style.transition = durationMs > 0 ? `opacity ${half}ms linear ${half}ms` : "none";
  row.check.style.opacity = phase >= 0.5 ? "1" : "0";
  row.shimmer.style.transition =
    durationMs > 0 ? `opacity ${Math.round(durationMs * 0.625)}ms linear` : "none";
  row.shimmer.style.opacity = phase > 0.5 ? "0" : "1";
  row.dim.style.transition =
    durationMs > 0 ? `opacity ${half}ms linear ${Math.round(durationMs * 0.2)}ms` : "none";
  row.dim.style.opacity = phase > 0.5 ? "1" : "0";
}

export class Ticker {
  readonly el: HTMLElement;
  private a = makeRow();
  private b = makeRow();
  private c = makeRow();
  private displayIndex = -1;
  private transitioning = false;
  private resetTimer: number | null = null;

  constructor() {
    this.el = h("div", { class: "ticker" }, this.a.el, this.b.el, this.c.el);
    this.reset();
  }

  private reset() {
    setPhase(this.a, 1, 0, 0);
    this.a.el.style.opacity = "1";
    this.a.el.style.transition = "none";
    setPhase(this.b, 0, 22, 0);
    setPhase(this.c, 0, 44, 0);
    this.c.el.style.opacity = "0";
  }

  sync(task: AgentTask | null) {
    const steps = task && task.steps.length > 0 ? task.steps : ["…"];
    const idx = task ? task.stepIndex : -1;

    if (this.displayIndex < 0) {
      this.displayIndex = idx;
      setText(this.a, idx > 0 ? steps[Math.max(0, idx - 1)] : "…");
      setText(this.b, steps[Math.min(Math.max(idx, 0), steps.length - 1)]);
      return;
    }
    if (this.transitioning || idx === this.displayIndex) return;
    this.animateTo(idx, steps);
  }

  private animateTo(newIdx: number, steps: string[]) {
    this.transitioning = true;
    setText(this.c, steps[Math.min(newIdx, steps.length - 1)]);
    setPhase(this.c, 0, 44, 0);
    this.c.el.style.opacity = "0";

    // Force a layout flush so the transitions below actually run.
    void this.c.el.offsetHeight;

    this.a.el.style.transition = "transform 280ms ease-out, opacity 280ms ease-out";
    this.a.el.style.transform = `translate(-10px, -22px) scale(${COMPLETED_SCALE})`;
    this.a.el.style.opacity = "0";

    setPhase(this.b, 1, 0, 380);

    this.c.el.style.transition = `transform 380ms ${CURVE}, opacity 380ms ${CURVE}`;
    this.c.el.style.transform = "translate(0px, 22px) scale(1)";
    this.c.el.style.opacity = "1";

    if (this.resetTimer != null) window.clearTimeout(this.resetTimer);
    this.resetTimer = window.setTimeout(() => {
      this.displayIndex = newIdx;
      setText(this.a, this.b.shimmer.textContent ?? "");
      setText(this.b, this.c.shimmer.textContent ?? "");
      this.reset();
      this.transitioning = false;
    }, 500);
  }
}
