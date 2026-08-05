;;; funcs.el --- markdown-it layer functions for Spacemacs.
;;
;; Functions that wire `markdown-mode' to the Node `markdown-it' engine
;; (the same one VS Code uses). The renderer script lives next to this file
;; as `render.cjs'; `markdown-it' and `highlight.js' are installed on the
;; system via `npm install -g markdown-it highlight.js'.
;;
;;; License: GPLv3

;;; Code:

;; Absolute path to this layer's directory (resolved from funcs.el's path).
(defvar markdown-it--dir
  (file-name-directory (or load-file-name buffer-file-name)))

(defun markdown-it--global-node-modules ()
  "Return the global node_modules directory (output of `npm root -g')."
  (condition-case nil
      (string-trim (shell-command-to-string "npm root -g"))
    (error "/opt/homebrew/lib/node_modules")))

(defun markdown-it/setup ()
  "Configure `markdown-mode' to render previews using the markdown-it engine."
  (let* ((render (expand-file-name "render.cjs" markdown-it--dir))
         (node-modules (markdown-it--global-node-modules)))
    ;; Run:  env NODE_PATH=<global node_modules> node render.cjs
    ;; `markdown-command' is split on spaces and invoked via
    ;; `call-process-region', which executes `env' directly with these args,
    ;; so NODE_PATH is set before node runs and CJS `require' resolves the
    ;; globally-installed packages.
    (setq markdown-command
          (mapconcat #'identity
                     (list "env"
                           (format "NODE_PATH=%s" node-modules)
                           "node"
                           (shell-quote-argument render))
                     " "))
    ;; markdown-it reads from stdin (like pandoc / the `markdown` binary),
    ;; so it works on unsaved buffers too.
    (setq markdown-command-needs-filename nil)))

(defun markdown-it/set-css (url-or-path)
  "Set `markdown-css-paths' to a single URL or local path for preview styling."
  (interactive "sCSS URL or file path: ")
  (setq markdown-css-paths (list url-or-path)))

;;; funcs.el ends here
