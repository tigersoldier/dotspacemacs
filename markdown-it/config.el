;;; config.el --- markdown-it layer configuration for Spacemacs.
;;
;; Styles the markdown preview with Water.css, following the system color
;; scheme (light/dark) automatically via `prefers-color-scheme` media queries.
;; Code blocks are colored by a matching highlight.js theme in each mode.
;;
;; Stylesheets are loaded from CDNs (requires internet) and injected through
;; `markdown-xhtml-header-content' rather than `markdown-css-paths', because
;; the four <link> tags each carry a `media' attribute that scopes them to the
;; matching color scheme — `markdown-mode's `markdown-stylesheet-link-string'
;; does not emit a `media' attribute, so we build the tags by hand here.
;;
;; The same header also loads mermaid.js (CDN) so that fenced ```mermaid
;; blocks, emitted by render.cjs as `<pre class="mermaid">`, are rendered
;; into SVG diagrams in the browser.
;;
;;; License: GPLv3

;;; Code:

(defvar markdown-it--water-light
  "https://cdn.jsdelivr.net/npm/water.css@2/out/light.css")
(defvar markdown-it--water-dark
  "https://cdn.jsdelivr.net/npm/water.css@2/out/dark.css")
(defvar markdown-it--hljs-light
  "https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github.min.css")
(defvar markdown-it--hljs-dark
  "https://cdn.jsdelivr.net/npm/highlight.js@11/styles/github-dark.min.css")
(defvar markdown-it--mermaid-cdn
  "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js")

(defun markdown-it//stylesheet (href media)
  "Return a <link> tag for HREF scoped to MEDIA (a CSS media-query string)."
  (format "<link rel=\"stylesheet\" href=\"%s\" media=\"%s\">" href media))

(defun markdown-it//mermaid-script ()
  "Return <script> tags loading mermaid.js and rendering `.mermaid' elements.
The diagram theme follows the system color scheme, like the stylesheets."
  (format (concat "<script src=\"%s\"></script>\n"
                  "<script>mermaid.initialize({startOnLoad:true,"
                  "theme:(matchMedia('(prefers-color-scheme: dark)').matches"
                  "?'dark':'default')});</script>")
          markdown-it--mermaid-cdn))

(defun markdown-it//build-header ()
  "Build `markdown-xhtml-header-content' with system-following stylesheets."
  (mapconcat
   #'identity
   (list
    (markdown-it//stylesheet markdown-it--water-light "(prefers-color-scheme: light)")
    (markdown-it//stylesheet markdown-it--water-dark  "(prefers-color-scheme: dark)")
    (markdown-it//stylesheet markdown-it--hljs-light  "(prefers-color-scheme: light)")
    (markdown-it//stylesheet markdown-it--hljs-dark   "(prefers-color-scheme: dark)")
    (markdown-it//mermaid-script)
    "<style>body{max-width:820px;margin:40px auto;padding:0 24px}</style>")
   "\n"))

(defun markdown-it/init-styling ()
  "Install the system-following Water.css styling for markdown previews."
  (setq markdown-css-paths nil)
  (setq markdown-xhtml-header-content (markdown-it//build-header)))

(markdown-it/init-styling)

;;; config.el ends here
