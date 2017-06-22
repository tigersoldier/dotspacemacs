;;; packages.el --- javacomp layer packages file for Spacemacs.
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
    ))

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

      (push 'company-javacomp company-backends-java-mode))
    :config
    (progn
      (setq javacomp-options-log-path "/tmp/javacomp.log"
            javacomp-options-log-level "fine"
            javacomp-options-ignore-paths `("openjdk_src/test"
                                            "openjdk_src"
                                            "testdata"
                                            "typeindeces"
                                            "bazel-javacomp"
                                            "bazel-bin"
                                            "bazel-out")
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
