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

  (let ((default-directory (expand-file-name "~/code/JavaComp/"))
        (dest-jar (expand-file-name "~/.emacs.d/javacomp/javacomp.jar")))
    (if (= 0 (call-process "bazel" nil "*javacomp-rebuild*" nil
                           "build"
                           "src/main/java/org/javacomp/server/JavaComp_deploy.jar"))
        (progn
          (copy-file "bazel-bin/src/main/java/org/javacomp/server/JavaComp_deploy.jar"
                     dest-jar
                     t)
          (chmod dest-jar #o644)
          (when (functionp 'javacomp-restart-server)
            (javacomp-restart-server))
          (message "JavaComp is successfully built"))
      (message "Fail to build JavaComp. Switch to *javacomp-rebuild* buffer to see the build results."))))
