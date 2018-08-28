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
    (spacemacs|add-company-backends
      :backends company-lsp
      :modes java-mode
      :append-hooks nil
      :call-hooks t)))

;;; packages.el ends here
