;;; funcs.el --- markdown-it layer functions for Spacemacs. -*- lexical-binding: t; -*-
;;
;; Functions that wire `markdown-mode' to the Node `markdown-it' engine
;; (the same one VS Code uses). The renderer script lives next to this file
;; as `render.cjs'; `markdown-it' and `highlight.js' are installed on the
;; system via `npm install -g markdown-it highlight.js'.
;;
;; Besides rendering, the command copies every local image the document
;; references into a per-document temporary asset directory (preserving the
;; relative directory structure) and rewrites the HTML references to
;; absolute file:// URLs.  This is needed because `markdown-preview' writes
;; its HTML to a random temp file in `temporary-file-directory', where the
;; document's relative image paths cannot resolve.  Rewriting happens on the
;; rendered HTML, so Markdown `![...](path)' and raw HTML `<img src=...>'
;; (as well as `srcset' and `poster') are all handled uniformly.
;;
;;; License: GPLv3

;;; Code:

(require 'url-util)

;; Absolute path to this layer's directory (resolved from funcs.el's path).
(defvar markdown-it--dir
  (file-name-directory (or load-file-name buffer-file-name)))

;; Cached output of `npm root -g' (spawning npm on every preview is slow).
(defvar markdown-it--node-modules nil)

;; Temp directory holding copies of referenced local assets for this Emacs
;; session.  Created lazily by `markdown-it//asset-subdir'.
(defvar markdown-it--asset-root nil)

(defun markdown-it--global-node-modules ()
  "Return the global node_modules directory (output of `npm root -g')."
  (or markdown-it--node-modules
      (setq markdown-it--node-modules
            (condition-case nil
                (string-trim (shell-command-to-string "npm root -g"))
              (error "/opt/homebrew/lib/node_modules")))))

(defun markdown-it//asset-subdir (base)
  "Return the per-BASE asset directory inside the session's temp asset root.
Copies are namespaced by a hash of BASE so that different documents reusing
the same relative paths (e.g. `images/logo.png') never collide."
  (unless markdown-it--asset-root
    (setq markdown-it--asset-root
          (file-name-as-directory (make-temp-file "markdown-it-assets-" t))))
  (expand-file-name (substring (secure-hash 'md5 base) 0 12)
                    markdown-it--asset-root))

(defun markdown-it//file-url (path)
  "Return a file:// URL for absolute local PATH, percent-encoding components."
  (concat "file://"
          (mapconcat #'url-hexify-string (split-string path "/") "/")))

(defun markdown-it//local-file (url base)
  "Return the absolute local file named by URL relative to BASE, or nil.
Returns nil for remote/scheme URLs, fragments, and files that do not exist,
so those references are left untouched."
  (when (and (stringp url)
             (not (string-empty-p url))
             (not (string-match-p
                   "\\`\\(?:[a-zA-Z][a-zA-Z0-9+.-]*:\\|//\\|#\\)" url)))
    (let* ((path (car (split-string url "[?#]")))
           (abs (expand-file-name (url-unhex-string path) base)))
      (and (file-regular-p abs) abs))))

(defun markdown-it//copy-asset (url base)
  "Copy the local file referenced by URL (relative to BASE) into the temp
asset root, returning a file:// URL to the copy.  Relative directory
structure is preserved; `..' segments become `__parent__' so copies stay
inside the temp root.  Non-local or missing references are returned as-is."
  (let ((abs (markdown-it//local-file url base)))
    (if (null abs)
        url
      (let* ((rel (file-relative-name abs base))
             (safe (mapconcat (lambda (component)
                                (if (equal component "..") "__parent__" component))
                              (split-string rel "/") "/"))
             (dest (expand-file-name safe (markdown-it//asset-subdir base))))
        (make-directory (file-name-directory dest) t)
        (copy-file abs dest t)
        (markdown-it//file-url dest)))))

(defun markdown-it//rewrite-srcset (value base)
  "Rewrite every URL in the srcset VALUE relative to BASE, keeping descriptors."
  (mapconcat
   (lambda (candidate)
     (let ((parts (split-string (string-trim candidate) "[ \t\n]+" t)))
       (if (null parts)
           candidate
         (concat (markdown-it//copy-asset (car parts) base)
                 (when (cdr parts)
                   (concat " " (mapconcat #'identity (cdr parts) " ")))))))
   (split-string value ",")
   ", "))

(defun markdown-it//rewrite-asset-references (html base)
  "Copy and rewrite local asset references in HTML, relative to BASE.
By the time the document is HTML, Markdown image syntax and raw HTML image
tags both appear as attributes, so this covers `src', `srcset' and `poster'
regardless of which syntax produced them."
  (with-temp-buffer
    (insert html)
    (goto-char (point-min))
    (while (re-search-forward
            "\\(src\\|srcset\\|poster\\)=\\([\"']\\)\\([^\"']*\\)\\2" nil t)
      ;; `match-data' is clobbered by the string/file operations inside
      ;; `markdown-it//copy-asset', so save it before and restore it before
      ;; `replace-match' (which would otherwise edit the wrong region).
      (let* ((data (match-data))
             (attr (match-string 1))
             (quote-char (match-string 2))
             (value (match-string 3))
             (new (if (equal attr "srcset")
                      (markdown-it//rewrite-srcset value base)
                    (markdown-it//copy-asset value base))))
        (unless (equal value new)
          (set-match-data data)
          (replace-match (concat attr "=" quote-char new quote-char) t t))))
    (buffer-string)))

(defun markdown-it--render (begin end buf)
  "Render region BEGIN..END as Markdown and insert the HTML into BUF.
Used as `markdown-command'.  Local images referenced by the document are
copied into a temporary asset directory (relative structure preserved) and
rewritten to absolute file:// URLs, so the preview can find them even though
`markdown-preview' writes its HTML to an unrelated temporary file.  Reading
from the region/stdin keeps previews working on unsaved buffers."
  (let* ((base (or (and buffer-file-name
                        (file-name-directory buffer-file-name))
                   default-directory))
         (render (expand-file-name "render.cjs" markdown-it--dir))
         (node-modules (markdown-it--global-node-modules))
         ;; `call-process-region' reads the region of the *current* buffer, so
         ;; it must stay the source buffer while the HTML goes to OUT.
         (out (generate-new-buffer " *markdown-it*"))
         (html (unwind-protect
                   (progn
                     (let ((exit (apply #'call-process-region
                                        begin end "env" nil out nil
                                        (list (format "NODE_PATH=%s" node-modules)
                                              "node" render))))
                       (unless (eq exit 0)
                         (error "markdown-it renderer failed with exit code %s" exit)))
                     (with-current-buffer out (buffer-string)))
                 (kill-buffer out))))
    (with-current-buffer buf
      (erase-buffer)
      (insert (markdown-it//rewrite-asset-references html base)))))

(defun markdown-it/setup ()
  "Configure `markdown-mode' to render previews using the markdown-it engine."
  ;; A function form (rather than a command string) lets the renderer see the
  ;; source buffer and copy its images before the HTML is handed off.
  (setq markdown-command #'markdown-it--render)
  ;; render.cjs reads from stdin (like pandoc / the `markdown` binary), so
  ;; previews work on unsaved buffers too.  The function form ignores this.
  (setq markdown-command-needs-filename nil))

(defun markdown-it/set-css (url-or-path)
  "Set `markdown-css-paths' to a single URL or local path for preview styling."
  (interactive "sCSS URL or file path: ")
  (setq markdown-css-paths (list url-or-path)))

;;; funcs.el ends here
