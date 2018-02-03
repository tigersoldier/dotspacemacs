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
    (javacomp :location local)
    (company-lsp)
    (lsp-javacomp :requires lsp-mode)
    (lsp-mode)
    (company-mode)))

(defun javacomp/post-init-company-mode ()
  (when (configuration-layer/package-usedp 'lsp-javacomp)
    (spacemacs|add-company-backends
      :backends company-capf
      :modes java-mode
      :hooks nil)))


(defun javacomp/init-lsp-mode ())

(defun javacomp/init-lsp-javacomp ()
  (use-package lsp-mode
    :defer t
    :config (require 'lsp-javacomp))

  (use-package lsp-javacomp
    :defer t
    :init
    (progn
      (add-hook 'java-mode-hook
                (lambda ()
                  (require 'lsp-javacomp)
                  (lsp-javacomp-enable)
                  (set (make-variable-buffer-local 'company-idle-delay) 0)
                  (set (make-variable-buffer-local 'company-minimum-prefix-length) 1)
                  )))
    :config (lsp-javacomp-install-server)))

(defun javacomp/init-company-lsp ()
  (use-package company-lsp
    :defer t
    :commands (company-lsp)
    :init
    (add-hook 'java-mode-hook
              (lambda ()
                (set (make-variable-buffer-local 'company-backends)
                     '(company-lsp))))))

(defun javacomp/init-javacomp ()
  (use-package javacomp
    :defer t
    :commands (javacomp-mode company-javacomp javacomp-jump-to-definition)
    :init
    (progn
      (evilified-state-evilify javacomp-references-mode javacomp-references-mode-map
        (kbd "C-k") 'javacomp-find-previous-location
        (kbd "C-j") 'javacomp-find-next-location
        (kbd "C-l") 'javacomp-goto-location)
      (add-hook 'java-mode-hook 'javacomp-mode)
      ;; (add-hook 'java-mode-hook 'eldoc-mode)

      (add-to-list 'spacemacs-jump-handlers-java-mode 'javacomp-jump-to-definition)

      (add-hook 'java-mode-hook
                (lambda ()
                  (set (make-variable-buffer-local 'company-backends)
                       `((company-javacomp company-dabbrev-code company-yasnippet)))
                  (set (make-variable-buffer-local 'company-idle-delay) 0)
                  (set (make-variable-buffer-local 'company-minimum-prefix-length) 1)
                  (company-mode t)
                  )))
    :config
    (progn
      (setq javacomp-options-log-path "/tmp/javacomp.log"
            javacomp-options-log-level "fine"
            javacomp-options-ignore-paths `("openjdk_src/test"
                                            "openjdk_src"
                                            "testdata"
                                            "typeindeces"
                                            "bazel-JavaComp"
                                            "bazel-bin"
                                            "bazel-out"
                                            ".*")
            javacomp-options-type-index-files `("typeindeces/guava.json"
                                                "typeindeces/javac.json"
                                                "typeindeces/truth.json")
            javacomp-java-options '("-agentlib:jdwp=transport=dt_socket,address=javacomp,server=y,suspend=n")
            javacomp-log-debug-message t
            javacomp-log-request-response t))
      (spacemacs/declare-prefix-for-mode 'java-mode "mg" "goto")
      ;; (spacemacs/declare-prefix-for-mode 'java-mode "mh" "help")
      ;; (spacemacs/declare-prefix-for-mode 'java-mode "mn" "name")
      ;; (spacemacs/declare-prefix-for-mode 'java-mode "mr" "rename")
      (spacemacs/declare-prefix-for-mode 'java-mode "mS" "server")
      ;; (spacemacs/declare-prefix-for-mode 'java-mode "ms" "send")

      (spacemacs/set-leader-keys-for-major-mode 'java-mode
        ;; "gb" 'javacomp-jump-back
        "gt" 'javacomp-jump-to-definition
        ;; "gu" 'javacomp-references
        ;; "hh" 'javacomp-documentation-at-point
        ;; "rr" 'javacomp-rename-symbol
        "Sr" 'javacomp-restart-server
        )
      )
    )
;;; packages.el ends here
