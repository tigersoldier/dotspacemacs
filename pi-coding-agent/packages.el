;;; packages.el --- pi-coding-agent layer packages file for Spacemacs.
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
;; This layer wraps the official `pi-coding-agent' Emacs frontend
;; (https://github.com/dnouri/pi-coding-agent, MELPA) for the pi coding
;; agent (https://pi.dev). It provides a two-window interface for
;; AI-assisted coding: a chat buffer with rendered markdown and a
;; separate prompt composition buffer, backed by a `pi --mode rpc'
;; subprocess.
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

(defconst pi-coding-agent-packages
  '(
    ;; Official Emacs frontend for the pi coding agent (MELPA).
    pi-coding-agent
    ))

(defun pi-coding-agent/init-pi-coding-agent ()
  "Initialize pi-coding-agent.

The package ships autoloads for all interactive entry points and
lazy-loads its Evil integration on first session setup, so no loading
is needed here — this init function only sets package options and,
importantly, makes this layer the owner of the package (a package
declared without an init function is treated as unused by Spacemacs
and removed under `used-only' install policy)."
  ;; Evil integration: Spacemacs uses the Vim editing style, so load
  ;; the package's Evil keybindings automatically on session setup
  ;; (this is the package default; made explicit here for clarity).
  (setq pi-coding-agent-evil-integration t)
  ;; RPC mode has no interactive trust prompt, so the frontend passes
  ;; `--approve' by default to make project-local `.pi' prompts,
  ;; skills, settings, themes, and extensions available. Alternatives:
  ;;   'default     let pi use trust.json / defaultProjectTrust
  ;;   'no-approve  pass `--no-approve' (ignore project-local files)
  (setq pi-coding-agent-project-trust-policy 'approve)
  ;; Emacs bridge: load the pi bridge extension into every session so
  ;; pi tools can drive the hosting Emacs (e.g. `emacs_new_session'
  ;; opens a new session in another directory with its own
  ;; perspective).  The extension file lives in this layer directory.
  ;; Guarded so layer reloads do not append it twice.
  (unless (boundp 'pi-coding-agent-extra-args)
    (defvar pi-coding-agent-extra-args nil
      "Extra arguments to pass to the pi command."))
  (when (bound-and-true-p pi-coding-agent/enable-bridge)
    (let ((bridge (expand-file-name "pi-bridge-extension.ts"
                                    pi-coding-agent--dir)))
      (when (and (file-exists-p bridge)
                 (not (member bridge pi-coding-agent-extra-args)))
        (setq pi-coding-agent-extra-args
              (append pi-coding-agent-extra-args (list "-e" bridge)))))))

;;; packages.el ends here
