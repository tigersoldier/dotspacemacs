;;; packages.el --- pilish layer packages file for Spacemacs. -*- lexical-binding: t; -*-
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
;; This layer wraps the `pilish' Emacs frontend — the renamed
;; `pi-coding-agent' package, https://github.com/dnouri/pilish — for the
;; pi coding agent (https://pi.dev). It provides a two-window interface
;; for AI-assisted coding: a chat buffer with rendered markdown and a
;; separate prompt composition buffer, backed by a `pi --mode rpc'
;; subprocess.
;;
;; The package is installed with `quelpa' from this config's fork
;; (https://github.com/tigersoldier/pi-coding-agent, branch
;; `downstream'), which carries fixes not yet released upstream.  A
;; device can opt into a local checkout instead by setting
;; `pilish/use-local-checkout' in the gitignored `local/config.el' (see
;; `pilish-packages' below).  Because local packages do not get
;; generated autoloads, `pilish/init-pilish' explicitly requires the
;; package.
;;
;; The package is self-contained: it auto-loads its Evil integration
;; when Evil is present, checks for the `pi' binary and tree-sitter
;; grammars at session start, and manages its own keymaps. This layer
;; only declares the package and adds Spacemacs-style leader
;; keybindings.
;;
;; Requirements:
;;   - Emacs 29.1 or later (tree-sitter support required)
;;   - pi coding agent @earendil-works/pi-coding-agent 0.81.0 or later,
;;     installed and in PATH (see the `pi' executable check)
;;
;;; Code:

(defconst pilish--packages-layer-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory containing this layer's `packages.el'.")

(defconst pilish--local-config-file
  (expand-file-name "local/config.el" pilish--packages-layer-dir)
  "Path of this layer's gitignored per-device config file.
Unlike the tracked dotfile it can differ on every machine; packages.el
loads it to pick up `pilish/use-local-checkout'.")

(defconst pilish--local-checkout-directory
  (expand-file-name "local/pilish" pilish--packages-layer-dir)
  "Path of the optional local pilish checkout, symlinked per device.")

;; `pilish/use-local-checkout' is defined with `defcustom' in config.el,
;; but packages.el runs first.  Declare it here so this file can read it,
;; and load the local config before doing so — a flag set there could not
;; influence the declaration below otherwise.
(defvar pilish/use-local-checkout)

(when (file-exists-p pilish--local-config-file)
  (load pilish--local-config-file nil 'nomessage))

(defconst pilish--source-recipe
  '(recipe :fetcher github
           :repo "tigersoldier/pi-coding-agent"
           :branch "downstream"
           ;; Mirror the MELPA recipe's file selection: the package is
           ;; multi-file and reads `assets/pilish-logo.svg' at runtime.
           :files (:defaults ("assets" "assets/pilish-logo.svg")))
  "Quelpa recipe for the pilish fork this config tracks.
The fork (https://github.com/tigersoldier/pi-coding-agent) carries
fixes that are not released on MELPA yet; its `downstream' branch is
the integration branch of those fixes.  Used unless
`pilish/use-local-checkout' selects the local checkout.")

(defun pilish//local-checkout-p ()
  "Return non-nil when the local pilish checkout should be used.
Both `pilish/use-local-checkout' (set in the gitignored `local/config.el')
and an actual checkout at `local/pilish' are required."
  (and (bound-and-true-p pilish/use-local-checkout)
       (file-exists-p (expand-file-name "pilish.el"
                                        pilish--local-checkout-directory))))

(when (and (bound-and-true-p pilish/use-local-checkout)
           (not (pilish//local-checkout-p)))
  (display-warning
   'pilish
   (format (concat "pilish/use-local-checkout is set but no checkout "
                   "exists at %s; installing %s (branch %s) instead")
           pilish--local-checkout-directory
           (plist-get (cdr pilish--source-recipe) :repo)
           (plist-get (cdr pilish--source-recipe) :branch))
   :warning))

(defconst pilish-packages
  (append
   (if (pilish//local-checkout-p)
       ;; Development setup: load the checkout symlinked into `local/pilish'.
       '((pilish :location local))
     ;; Default: install the fork's `downstream' branch via quelpa.
     `((pilish :location ,pilish--source-recipe)))
   ;; Hard dependencies the package requires, whether it comes from the
   ;; local checkout or the recipe above.  A local checkout is not
   ;; installed through package.el, so its `Package-Requires' do not
   ;; activate these; declaring them keeps Spacemacs from treating them as
   ;; unused and puts their directories on `load-path'.  Quelpa installs
   ;; the recipe through package.el and would activate them anyway, but
   ;; declaring them keeps both sources equivalent.
   '(md-ts-mode markdown-table-wrap))
  "Packages declared by the pilish layer.
When `pilish/use-local-checkout' is set (gitignored `local/config.el')
and `local/pilish' is a checkout, that checkout is loaded; otherwise
`pilish--source-recipe' installs the fork's `downstream' branch.")

(defun pilish/init-md-ts-mode ()
  "Keep md-ts-mode activated as a pilish dependency.
Nothing to configure; the mode is used by `pilish-chat-mode'."
  nil)

(defun pilish/init-markdown-table-wrap ()
  "Keep markdown-table-wrap activated as a pilish dependency.
Nothing to configure; it is used by the table renderer."
  nil)

(defun pilish/init-pilish ()
  "Initialize pilish.

Local packages get no generated autoloads, so this init function
explicitly requires the package after setting options (idempotent for
the quelpa fallback, whose autoloads already exist).  It also makes
this layer the owner of the package (a package declared without an
init function is treated as unused by Spacemacs and removed under
`used-only' install policy)."
  ;; Evil integration: Spacemacs uses the Vim editing style, so load
  ;; the package's Evil keybindings automatically on session setup
  ;; (this is the package default; made explicit here for clarity).
  (setq pilish-evil-integration t)
  ;; RPC mode has no interactive trust prompt, so the frontend passes
  ;; `--approve' by default to make project-local `.pi' prompts,
  ;; skills, settings, themes, and extensions available. Alternatives:
  ;;   'default     let pi use trust.json / defaultProjectTrust
  ;;   'no-approve  pass `--no-approve' (ignore project-local files)
  (setq pilish-project-trust-policy 'approve)
  ;; Emacs bridge: load the pi bridge extension into every session so
  ;; pi tools can drive the hosting Emacs (e.g. `emacs_new_session'
  ;; opens a new session in another directory with its own
  ;; perspective).  The extension file lives in this layer directory.
  ;; Guarded so layer reloads do not append it twice.
  (unless (boundp 'pilish-extra-args)
    (defvar pilish-extra-args nil
      "Extra arguments to pass to the pi command."))
  (when (bound-and-true-p pilish/enable-bridge)
    (let ((bridge (expand-file-name "pi-bridge-extension.ts"
                                    pilish--dir)))
      (when (and (file-exists-p bridge)
                 (not (member bridge pilish-extra-args)))
        (setq pilish-extra-args
              (append pilish-extra-args (list "-e" bridge))))))
  ;; Local packages get no generated autoloads, so load the package
  ;; explicitly after the options above are in place.  `require' is
  ;; idempotent, so a reload via `SPC f e R' stays cheap.
  (require 'pilish))

;;; packages.el ends here
