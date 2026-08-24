// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration
//
// Colours, spacing and type are pulled from the design tokens in
// `assets/css/tokens.css` (copied from foll-components — do not import that
// package). Never hard-code a hex / px literal here for values that already
// exist as tokens — utilities must resolve to `var(--…)` so themes and the
// foundation scale stay single-sourced.
//
// The `<alpha-value>` placeholder lets Tailwind keep the `bg-primary/10` /
// `text-status-failed/40` opacity syntax working — it's substituted with the
// numeric alpha at compile time, then `rgb(from var(--token) r g b / <alpha>)`
// is resolved by the browser at paint time.

const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

const cssVar = (name) => `rgb(from var(${name}) r g b / <alpha-value>)`

module.exports = {
  content: [
    "./js/**/*.js",
    "../lib/omashiki_web.ex",
    "../lib/omashiki_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        // ---- MD3 surface family (existing keys preserved) ----
        surface: {
          DEFAULT: cssVar("--md-sys-color-surface"),
          "container-lowest": cssVar("--md-sys-color-surface-container-lowest"),
          "container-low": cssVar("--md-sys-color-surface-container-low"),
          container: cssVar("--md-sys-color-surface-container"),
          "container-high": cssVar("--md-sys-color-surface-container-high"),
          "container-highest": cssVar("--md-sys-color-surface-container-highest"),
        },
        "surface-variant": cssVar("--md-sys-color-surface-variant"),
        "on-surface": cssVar("--md-sys-color-on-surface"),
        "on-surface-variant": cssVar("--md-sys-color-on-surface-variant"),
        "surface-tint": cssVar("--md-sys-color-surface-tint"),

        // ---- MD3 primary family ----
        primary: cssVar("--md-sys-color-primary"),
        "on-primary": cssVar("--md-sys-color-on-primary"),
        "primary-container": cssVar("--md-sys-color-primary-container"),
        "on-primary-container": cssVar("--md-sys-color-on-primary-container"),
        "primary-fixed-dim": cssVar("--md-sys-color-primary-fixed-dim"),

        // ---- MD3 secondary family ----
        secondary: {
          DEFAULT: cssVar("--md-sys-color-secondary"),
          container: cssVar("--md-sys-color-secondary-container"),
        },
        "on-secondary": cssVar("--md-sys-color-on-secondary"),
        "on-secondary-container": cssVar("--md-sys-color-on-secondary-container"),

        // ---- MD3 tertiary family ----
        tertiary: {
          DEFAULT: cssVar("--md-sys-color-tertiary"),
          container: cssVar("--md-sys-color-tertiary-container"),
        },
        "on-tertiary": cssVar("--md-sys-color-on-tertiary"),
        "on-tertiary-container": cssVar("--md-sys-color-on-tertiary-container"),

        // ---- MD3 error family ----
        error: cssVar("--md-sys-color-error"),
        "on-error": cssVar("--md-sys-color-on-error"),
        "error-container": cssVar("--md-sys-color-error-container"),
        "on-error-container": cssVar("--md-sys-color-on-error-container"),

        // ---- MD3 inverse + utility ----
        "inverse-surface": cssVar("--md-sys-color-inverse-surface"),
        "inverse-on-surface": cssVar("--md-sys-color-inverse-on-surface"),
        "inverse-primary": cssVar("--md-sys-color-inverse-primary"),
        scrim: cssVar("--md-sys-color-scrim"),
        shadow: cssVar("--md-sys-color-shadow"),

        outline: cssVar("--md-sys-color-outline"),
        "outline-variant": cssVar("--md-sys-color-outline-variant"),

        // ---- Omashiki extensions (status + categorical accents) ----
        // Not part of MD3. Status hues are picked for ≥4.5:1 contrast on
        // surface (#121212 baseline). Pull from this palette whenever the UI
        // needs to communicate state — never use raw red/yellow/amber utilities.
        status: {
          success: cssVar("--app-color-status-success"),
          failed: cssVar("--app-color-status-failed"),
          cancelled: cssVar("--app-color-status-cancelled"),
          awaiting: cssVar("--app-color-status-awaiting"),
          running: cssVar("--app-color-status-running"),
        },
        accent: {
          sky: cssVar("--app-color-accent-sky"),
          amber: cssVar("--app-color-accent-amber"),
          magenta: cssVar("--app-color-accent-magenta"),
          violet: cssVar("--app-color-accent-violet"),
        },
      },
      // Spacing → tokens. `p-4` resolves to `var(--space-4)` (16px), not a
      // parallel rem scale. Steps without a token (1.5, 2.5, 7, …) keep
      // Tailwind defaults until the foundation absorbs them.
      spacing: {
        0: "var(--space-0)",
        0.5: "var(--space-05)",
        1: "var(--space-1)",
        2: "var(--space-2)",
        3: "var(--space-3)",
        4: "var(--space-4)",
        5: "var(--space-5)",
        6: "var(--space-6)",
        8: "var(--space-8)",
        10: "var(--space-10)",
        12: "var(--space-12)",
      },
      fontFamily: {
        headline: ["var(--font-headline)"],
        body: ["var(--font-body)"],
        label: ["var(--font-label)"],
        mono: ["var(--font-mono)"],
      },
      // Label keys keep the Omashiki class names used across HEEx. foll
      // collapsed five label steps into two; where a token matches the old
      // pixel size we bind to it. Orphans (xs/sm/lg) stay literal until
      // Etapa 6 migrates call sites onto `.type-*` / the two-step scale.
      fontSize: {
        "label-xs": ["8px", { lineHeight: "12px" }],
        "label-sm": ["9px", { lineHeight: "14px" }],
        "label-md": ["var(--text-label-sm)", { lineHeight: "var(--leading-label-sm)" }],
        "label-lg": ["11px", { lineHeight: "16px" }],
        "label-xl": ["var(--text-label-md)", { lineHeight: "var(--leading-label-md)" }],
        "body-xs": ["var(--text-body-xs)", { lineHeight: "var(--leading-body-xs)" }],
        "body-sm": ["var(--text-body-sm)", { lineHeight: "var(--leading-body-sm)" }],
        "body-md": ["var(--text-body-md)", { lineHeight: "var(--leading-body-md)" }],
        "headline-sm": ["var(--text-headline-sm)", { lineHeight: "var(--leading-headline-sm)" }],
        "headline-md": ["var(--text-headline-md)", { lineHeight: "var(--leading-headline-md)" }],
        "headline-lg": ["var(--text-headline-lg)", { lineHeight: "var(--leading-headline-md)" }],
      },
      borderRadius: {
        DEFAULT: "0px",
        none: "0px",
        sm: "0px",
        md: "0px",
        lg: "0px",
        xl: "0px",
        "2xl": "0px",
        "3xl": "0px",
        full: "9999px",
      },
      keyframes: {
        "agent-pulse": {
          "0%, 100%": { borderLeftColor: "rgba(57, 255, 20, 0.4)" },
          "50%": { borderLeftColor: "rgba(57, 255, 20, 1)" },
        },
        "needs-context-pulse": {
          "0%, 100%": { borderLeftColor: "rgba(160, 232, 122, 0.5)" },
          "50%": { borderLeftColor: "rgba(160, 232, 122, 1)" },
        },
        "status-pulse": {
          "0%, 100%": { opacity: "0.6" },
          "50%": { opacity: "1" },
        },
        "status-flash": {
          "0%": { backgroundColor: "rgba(57, 255, 20, 0.25)" },
          "100%": { backgroundColor: "transparent" },
        },
      },
      animation: {
        "agent-pulse": "agent-pulse 2s ease-in-out infinite",
        "needs-context-pulse": "needs-context-pulse 2.4s ease-in-out infinite",
        "status-pulse": "status-pulse 1.6s ease-in-out infinite",
        "status-flash": "status-flash 900ms ease-out 1",
      },
    },
  },
  plugins: [
    require("@tailwindcss/forms"),
    // Allows prefixing tailwind classes with LiveView classes to add rules
    // only when LiveView classes are applied, for example:
    //
    //     <div class="phx-click-loading:animate-ping">
    //
    plugin(({addVariant}) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({addVariant}) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({addVariant}) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"])),

    // Embeds Heroicons (https://heroicons.com) into your app.css bundle
    // See your `CoreComponents.icon/1` for more information.
    //
    plugin(function({matchComponents, theme}) {
      let iconsDir = path.join(__dirname, "../deps/heroicons/optimized")
      let values = {}
      let icons = [
        ["", "/24/outline"],
        ["-solid", "/24/solid"],
        ["-mini", "/20/solid"],
        ["-micro", "/16/solid"]
      ]
      icons.forEach(([suffix, dir]) => {
        fs.readdirSync(path.join(iconsDir, dir)).forEach(file => {
          let name = path.basename(file, ".svg") + suffix
          values[name] = {name, fullPath: path.join(iconsDir, dir, file)}
        })
      })
      matchComponents({
        "hero": ({name, fullPath}) => {
          let content = fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, "")
          let size = theme("spacing.6")
          if (name.endsWith("-mini")) {
            size = theme("spacing.5")
          } else if (name.endsWith("-micro")) {
            size = theme("spacing.4")
          }
          return {
            [`--hero-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
            "-webkit-mask": `var(--hero-${name})`,
            "mask": `var(--hero-${name})`,
            "mask-repeat": "no-repeat",
            "background-color": "currentColor",
            "vertical-align": "middle",
            "display": "inline-block",
            "width": size,
            "height": size
          }
        }
      }, {values})
    })
  ]
}
