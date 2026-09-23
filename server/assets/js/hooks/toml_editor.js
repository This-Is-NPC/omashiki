// TomlEditor — LiveView JS hook that mounts a CodeMirror 6 TOML editor.
//
// Attach to an element LiveView must never patch:
//   <div id="toml-editor" phx-hook="TomlEditor" phx-update="ignore"
//        data-content={@content} data-readonly={to_string(@readonly?)}></div>
//
// Pushes:
//   "editor_changed" %{"content" => ...}  debounced edits
//   "editor_save"    %{"content" => ...}  Ctrl/Cmd-S (pending edits go first)
// Handles:
//   "editor_set"         %{content, readonly}   replaces the document silently
//   "editor_diagnostics" %{items: [%{line, message}]}  1-based lines; [] clears
//
// Colours and fonts resolve through the design tokens in `css/tokens.css`, so
// the editor follows the active `data-theme`.

import {Compartment, EditorState, Transaction} from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import {defaultKeymap, history, historyKeymap} from "@codemirror/commands";
import {HighlightStyle, StreamLanguage, bracketMatching, syntaxHighlighting} from "@codemirror/language";
import {toml} from "@codemirror/legacy-modes/mode/toml";
import {highlightSelectionMatches, search, searchKeymap} from "@codemirror/search";
import {lintGutter, setDiagnostics} from "@codemirror/lint";
import {tags} from "@lezer/highlight";

const CHANGE_DEBOUNCE_MS = 300;

const theme = EditorView.theme(
  {
    "&": {
      height: "100%",
      color: "var(--md-sys-color-on-surface)",
      backgroundColor: "var(--md-sys-color-surface-container-lowest)",
      fontSize: "var(--text-body-sm)",
    },
    ".cm-scroller": {
      fontFamily: "ui-monospace, 'SFMono-Regular', 'Menlo', monospace",
      lineHeight: "var(--leading-body-sm)",
    },
    ".cm-content": {caretColor: "var(--md-sys-color-primary)"},
    ".cm-cursor, .cm-dropCursor": {borderLeftColor: "var(--md-sys-color-primary)"},
    "&.cm-focused": {outline: "var(--border-hairline) solid var(--md-sys-color-outline-variant)"},
    "&.cm-focused > .cm-scroller > .cm-selectionLayer .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection":
      {backgroundColor: "color-mix(in srgb, var(--md-sys-color-primary) 25%, transparent)"},
    ".cm-activeLine": {backgroundColor: "color-mix(in srgb, var(--md-sys-color-surface-container-high) 60%, transparent)"},
    ".cm-selectionMatch": {backgroundColor: "color-mix(in srgb, var(--md-sys-color-primary) 12%, transparent)"},
    "&.cm-focused .cm-matchingBracket": {
      backgroundColor: "transparent",
      outline: "var(--border-hairline) solid var(--md-sys-color-primary)",
    },
    "&.cm-focused .cm-nonmatchingBracket": {outline: "var(--border-hairline) solid var(--md-sys-color-error)"},
    ".cm-gutters": {
      color: "var(--md-sys-color-outline)",
      backgroundColor: "var(--md-sys-color-surface-container-lowest)",
      borderRight: "var(--border-hairline) solid var(--md-sys-color-outline-variant)",
    },
    ".cm-activeLineGutter": {
      color: "var(--md-sys-color-on-surface)",
      backgroundColor: "var(--md-sys-color-surface-container-high)",
    },
    ".cm-searchMatch": {
      backgroundColor: "color-mix(in srgb, var(--app-color-accent-amber) 25%, transparent)",
      outline: "var(--border-hairline) solid var(--app-color-accent-amber)",
    },
    ".cm-searchMatch.cm-searchMatch-selected": {
      backgroundColor: "color-mix(in srgb, var(--app-color-accent-amber) 50%, transparent)",
    },
    ".cm-panels": {
      color: "var(--md-sys-color-on-surface)",
      backgroundColor: "var(--md-sys-color-surface-container)",
      fontFamily: "var(--font-label)",
    },
    ".cm-panels.cm-panels-top": {borderBottom: "var(--border-hairline) solid var(--md-sys-color-outline-variant)"},
    ".cm-panel input, .cm-panel button": {
      color: "var(--md-sys-color-on-surface)",
      backgroundColor: "var(--md-sys-color-surface-container-high)",
      backgroundImage: "none",
      border: "var(--border-hairline) solid var(--md-sys-color-outline-variant)",
      borderRadius: "var(--radius-none)",
    },
    ".cm-lintRange-error": {
      backgroundImage: "none",
      textDecoration: "underline wavy var(--md-sys-color-error)",
      textUnderlineOffset: "3px",
    },
    ".cm-tooltip": {
      color: "var(--md-sys-color-on-surface)",
      backgroundColor: "var(--md-sys-color-surface-container-high)",
      border: "var(--border-hairline) solid var(--md-sys-color-outline-variant)",
    },
    ".cm-diagnostic-error": {borderLeftColor: "var(--md-sys-color-error)"},
  },
  {dark: true}
);

const highlighting = HighlightStyle.define([
  {tag: tags.propertyName, color: "var(--app-color-accent-sky)"},
  {tag: tags.string, color: "var(--md-sys-color-primary-fixed-dim)"},
  {tag: tags.number, color: "var(--app-color-accent-amber)"},
  {tag: tags.atom, color: "var(--md-sys-color-primary)"},
  {tag: tags.bracket, color: "var(--md-sys-color-on-surface-variant)"},
  {tag: tags.comment, color: "var(--md-sys-color-outline)", fontStyle: "italic"},
]);

// Maps server diagnostics onto whole lines. A line past the end of the
// document lands on the last line instead of disappearing.
const lineDiagnostics = (doc, items) =>
  items.map(({line, message}) => {
    const {from, to} = doc.line(Math.min(Math.max(line, 1), doc.lines));
    return {from, to, severity: "error", message};
  });

const readOnlyState = (readonly) => EditorState.readOnly.of(readonly);

const TomlEditor = {
  mounted() {
    this._readonly = new Compartment();
    this._pending = null;

    this.view = new EditorView({
      parent: this.el,
      state: EditorState.create({
        doc: this.el.dataset.content,
        extensions: [
          lineNumbers(),
          highlightActiveLineGutter(),
          highlightActiveLine(),
          drawSelection(),
          history(),
          bracketMatching(),
          highlightSelectionMatches(),
          search({top: true}),
          lintGutter(),
          StreamLanguage.define(toml),
          syntaxHighlighting(highlighting),
          theme,
          this._readonly.of(readOnlyState(this.el.dataset.readonly === "true")),
          keymap.of([
            {key: "Mod-s", preventDefault: true, run: (view) => this._save(view)},
            ...defaultKeymap,
            ...historyKeymap,
            ...searchKeymap,
          ]),
          EditorView.updateListener.of((update) => {
            const local = update.transactions.some((tr) => tr.docChanged && !tr.annotation(Transaction.remote));
            if (local) this._scheduleChange();
          }),
        ],
      }),
    });

    this.handleEvent("editor_set", ({content, readonly}) => {
      this._cancelChange();
      const {state} = this.view;
      this.view.dispatch(
        {
          changes: {from: 0, to: state.doc.length, insert: content},
          effects: this._readonly.reconfigure(readOnlyState(readonly)),
          annotations: Transaction.remote.of(true),
        },
        setDiagnostics(state, [])
      );
    });

    this.handleEvent("editor_diagnostics", ({items}) => {
      const {state} = this.view;
      this.view.dispatch(setDiagnostics(state, lineDiagnostics(state.doc, items)));
    });
  },

  destroyed() {
    this._cancelChange();
    this.view.destroy();
  },

  _content() {
    return this.view.state.doc.toString();
  },

  _scheduleChange() {
    this._cancelChange();
    this._pending = setTimeout(() => this._flushChange(), CHANGE_DEBOUNCE_MS);
  },

  _cancelChange() {
    clearTimeout(this._pending);
    this._pending = null;
  },

  _flushChange() {
    if (this._pending === null) return;
    this._cancelChange();
    this.pushEvent("editor_changed", {content: this._content()});
  },

  _save(view) {
    if (view.state.readOnly) return true;
    this._flushChange();
    this.pushEvent("editor_save", {content: this._content()});
    return true;
  },
};

export default TomlEditor;
