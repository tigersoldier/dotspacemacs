;;; packages.el --- lsp-mode layer packages file for Spacemacs.  -*- lexical-binding: t -*-
;;
;; Copyright (c) 2018 Caibin Chen
;;
;; Author: Caibin Chen <tigersoldi@gmail.com>
;;
;; This file is not part of GNU Emacs.
;;
;;; License: GPLv3

;;; Commentary:

;;; Code:

(defconst lsp-mode-packages
  '((lsp-mode)
    (company-lsp)))

(defun lsp-mode/post-init-lsp-mode ()
  (add-hook 'php-mode-hook
            (lambda ()
              (require 'lsp-mode)
              (require 'company-lsp)
              (setq-local company-backends '(company-lsp))
              (company-mode t)
              (lsp))))

(defun lsp-mode/post-init-company-lsp ()
  (setq company-lsp-cache-candidates 'auto)
  (setq company-transformers nil)
  (spacemacs|add-company-backends
    :backends company-lsp
    :modes php-mode))

;;; packages.el ends here
