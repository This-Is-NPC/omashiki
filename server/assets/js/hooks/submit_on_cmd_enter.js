const SubmitOnCmdEnter = {
  mounted() {
    this._handler = (event) => {
      if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault()
        const form = this.el.closest("form")
        if (form) form.requestSubmit()
      }
    }
    this.el.addEventListener("keydown", this._handler)
  },

  destroyed() {
    this.el.removeEventListener("keydown", this._handler)
  },
}

export default SubmitOnCmdEnter
