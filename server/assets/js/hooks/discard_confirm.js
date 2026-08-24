// Toggles the destructive button's disabled state based on whether the
// input value matches the required confirmation text exactly. Escape blurs
// the field so the user can back out without committing keystrokes.
const DiscardConfirm = {
  mounted() {
    this._sync()
    this._onInput = () => this._sync()
    this._onKey = (e) => {
      if (e.key === "Escape") this.el.blur()
    }
    this.el.addEventListener("input", this._onInput)
    this.el.addEventListener("keydown", this._onKey)
  },

  updated() {
    this._sync()
  },

  destroyed() {
    if (this._onInput) this.el.removeEventListener("input", this._onInput)
    if (this._onKey) this.el.removeEventListener("keydown", this._onKey)
  },

  _sync() {
    const required = this.el.dataset.requiredText || ""
    const buttonId = this.el.dataset.buttonId
    if (!buttonId) return

    const btn = document.getElementById(buttonId)
    if (!btn) return

    btn.disabled = this.el.value !== required
  },
}

export default DiscardConfirm
