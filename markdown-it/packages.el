;;; packages.el --- markdown-it layer packages file for Spacemacs.
;;
;; Copyright (c) 2012-2016 Sylvain Benner & Contributors
;;
;; Author: Tiger Chen
;; URL: https://github.com/syl20bnr/spacemacs
;;
;; This file is not part of GNU Emacs.
;;
;;; License: GPLv3

;;; Commentary:
;;
;; This layer configures `markdown-mode' (provided by the built-in `markdown'
;; layer) to use the Node `markdown-it' library as its HTML processor — the
;; same engine VS Code's markdown preview uses. `markdown-it' and
;; `highlight.js' must be installed on the system:
;;
;;   npm install -g markdown-it highlight.js
;;
;; The renderer script lives in this layer as `render.cjs'. Fenced `mermaid'
;; blocks are emitted as `<pre class="mermaid">' and rendered client-side by
;; mermaid.js, which config.el loads from a CDN into the preview header.
;;
;;; Code:

(defconst markdown-it-packages
  '(
    ;; `markdown-mode' is owned by the built-in `markdown' layer; we only
    ;; contribute a `post-init-markdown-mode' to configure its processor.
    markdown-mode
    ))

(defun markdown-it/post-init-markdown-mode ()
  "Point `markdown-command' at the markdown-it renderer."
  (markdown-it/setup))

;;; packages.el ends here
