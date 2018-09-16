;;; packages.el --- javacomp layer packages file for Spacemacs.  -*- lexical-binding: t -*-
;;
;; Copyright (c) 2017 Caibin Chen
;;
;; Author: Caibin Chen <tigersoldi@gmail.com>
;;
;; This file is not part of GNU Emacs.
;;
;;; License: GPLv3

;;; Commentary:

;;; Code:

(defconst javacomp-packages
  '(
    (lsp-javacomp :requires lsp-mode lsp-ui company-lsp)))

(defun javacomp/init-lsp-javacomp ()
  (use-package lsp-javacomp
    :commands lsp-javacomp-enable
    :init
    (add-hook 'java-mode-hook
              (lambda ()
                (require 'lsp-javacomp)
                (require 'company-lsp)
                (lsp-javacomp-enable)
                (company-mode)
                (set (make-variable-buffer-local 'lsp-ui-imenu-enable) nil)
                (set (make-variable-buffer-local 'company-backends) '(company-lsp))
                (set (make-variable-buffer-local 'company-idle-delay) 0.1)
                (set (make-variable-buffer-local 'company-minimum-prefix-length) 1)))
    :config
    (lsp-javacomp-install-server)
    (setq lsp-javacomp-server-log-path "/tmp/javacomp.log"
          lsp-javacomp-server-log-level "fine")
    (spacemacs|add-company-backends
      :backends company-lsp
      :modes java-mode
      :append-hooks nil
      :call-hooks t)
    (spacemacs/set-leader-keys-for-major-mode 'java-mode
      "gg"  'lsp-ui-peek-find-definitions
      "gr"  'xref-find-references
      "gR"  'lsp-ui-peek-find-references
      "ga"  'xref-find-apropos
      "gA"  'lsp-ui-peek-find-workspace-symbol
      "gd"  'lsp-goto-type-definition
      "hh"  'lsp-describe-thing-at-point
      "el"  'lsp-ui-flycheck-list
      "pu"  'lsp-java-update-user-settings
      "ea"  'lsp-execute-code-action
      "qr"  'lsp-restart-workspace
      "roi" 'lsp-java-organize-imports
      "rr" 'lsp-rename
      "rai" 'lsp-java-add-import
      "ram" 'lsp-java-add-unimplemented-methods
      "rcp" 'lsp-java-create-parameter
      "rcf" 'lsp-java-create-field
      "rec" 'lsp-java-extract-to-constant
      "rel" 'lsp-java-extract-to-local-variable
      "rem" 'lsp-java-extract-method
      "cc"  'lsp-java-build-project
      "an"  'lsp-java-actionable-notifications
      "="   'lsp-format-buffer)))

;;; packages.el ends here
