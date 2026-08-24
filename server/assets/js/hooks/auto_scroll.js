// AutoScroll — LiveView JS hook that keeps a scrollable log container pinned
// to the bottom as new content is appended.
//
// Attach to the scrollable log container:
//   <div id="log-viewer-..." phx-hook="AutoScroll" class="overflow-y-auto ...">
//
// Scrolls to the bottom on mount, on every LiveView update, and whenever
// child nodes are added via a MutationObserver (covers streaming log lines).

const AutoScroll = {
  mounted() {
    this._scrollToBottom();
    this._observer = new MutationObserver(() => this._scrollToBottom());
    this._observer.observe(this.el, { childList: true, subtree: true });
  },

  updated() {
    this._scrollToBottom();
  },

  destroyed() {
    if (this._observer) this._observer.disconnect();
  },

  _scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight;
  },
};

export default AutoScroll;
