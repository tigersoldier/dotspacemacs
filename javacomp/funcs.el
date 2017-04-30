;;; funcs.el --- JavaComp functions File for Spacemacs
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

(defun spacemacs/build-javacomp ()
  "Rebuild JavaComp server."
  (interactive "*")

  (let ((default-directory (expand-file-name "~/code/JavaComp/")))
    (if (= 0 (call-process "bazel" nil "*javacomp-rebuild*" nil
                           "build"
                           "src/main/java/org/javacomp/server/JavaComp_deploy.jar"))
        (progn
          (call-process "cp" nil "*javacomp-rebuild*" nil
                        "-f"
                        "bazel-bin/src/main/java/org/javacomp/server/JavaComp_deploy.jar"
                        (expand-file-name "~/bin/"))
          (javacomp-restart-server)
          (message "JavaComp successfully built."))
      (message "Fail to build JavaComp. Switch to *javacomp-rebuild* buffer to see the build results."))))
