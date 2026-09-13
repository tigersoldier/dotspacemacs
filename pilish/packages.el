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
;; This layer wraps the `pilish' Emacs frontend (the renamed
;; `pi-coding-agent' package, https://github.com/dnouri/pilish) for the
;; pi coding agent (https://pi.dev). It provides a two-window interface
;; for AI-assisted coding: a chat buffer with rendered markdown and a
;; separate prompt composition buffer, backed by a `pi --mode rpc'
;; subprocess.
;;
;; The package is loaded from a local checkout when one is symlinked
;; into `local/pilish' (see `pilish-packages' below); otherwise the
;; released package is used.  Because local packages do not get
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

(defun pilish//local-checkout-directory ()
  "Return the local pilish checkout symlinked into `local/pilish', or nil.
The symlink is gitignored and created per device.  This is the single
place that decides whether Emacs runs the in-tree checkout: when the
checkout is present the layer loads it with `:location local', otherwise
it falls back to the released package."
  (let ((dir (expand-file-name "local/pilish" pilish--packages-layer-dir)))
    (when (file-exists-p (expand-file-name "pilish.el" dir))
      dir)))

(defconst pilish-packages
  (append
   (if (pilish//local-checkout-directory)
       ;; Development setup: load the checkout symlinked into `local/pilish'.
       '((pilish :location local))
     ;; Fallback for devices without a checkout: use the released package.
     ;; Warn rather than silently running a different pilish than the one
     ;; being edited.
     (progn
       (display-warning
        'pilish
        (format (concat "No local pilish checkout at %s; "
                        "falling back to the released package")
                (expand-file-name "local/pilish" pilish--packages-layer-dir))
        :warning)
       '(pilish)))
   ;; Hard dependencies the local checkout requires.  `pilish' is not
   ;; installed through package.el here, so its `Package-Requires' do not
   ;; activate these; declaring them keeps Spacemacs from treating them as
   ;; unused and puts their directories on `load-path'.  When the fallback
   ;; above is used, package.el would activate them anyway.
   '(md-ts-mode markdown-table-wrap))
  "Packages declared by the pilish layer.
The checkout symlinked into `local/pilish' wins (see
`pilish//local-checkout-directory'); otherwise the released package is
used and a warning is emitted, so the config keeps working on devices
where the checkout does not exist without silently losing the local
one.")

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

When `pilish-packages' selected the local checkout, Spacemacs does not
generate autoloads for it, so this init function explicitly requires
the package after setting options.  It also makes this layer the owner
of the package (a package declared without an init function is treated
as unused by Spacemacs and removed under `used-only' install policy)."
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
