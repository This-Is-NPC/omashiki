// BoardHeight — LiveView JS hook that makes a board fill the viewport below
// its own top edge, so each column scrolls inside itself instead of the page.
//
// Attach to the board container and size it from the measured offset:
//   <div id="task-board" phx-hook="BoardHeight"
//        class="h-[calc(100dvh_-_var(--board-top,16rem)_-_2.5rem)]">
//
// The offset is written to a CSS variable on <html>, outside the LiveView
// container, so a server patch never resets it. Banners and summary blocks
// above the board move its top edge; a ResizeObserver on <body> catches them.
// Only the top edge is measured, so resizing the board cannot feed back.

const BoardHeight = {
  mounted() {
    this._measure = () => {
      const top = this.el.getBoundingClientRect().top + window.scrollY;
      document.documentElement.style.setProperty("--board-top", `${Math.round(top)}px`);
    };

    this._measure();
    this._observer = new ResizeObserver(this._measure);
    this._observer.observe(document.body);
    window.addEventListener("resize", this._measure);
  },

  updated() {
    this._measure();
  },

  destroyed() {
    this._observer.disconnect();
    window.removeEventListener("resize", this._measure);
    document.documentElement.style.removeProperty("--board-top");
  },
};

export default BoardHeight;
