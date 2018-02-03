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

(defun spacemacs//javacomp-bazel-sentinel (process state)
  (message "javacomp build: %s" state)
  (when (equal state "finished\n")
    (let ((dest-jar (expand-file-name "~/.emacs.d/javacomp/javacomp.jar")))
      (unless (file-directory-p (file-name-directory dest-jar))
        (make-directory (file-name-directory dest-jar)))
      (copy-file (expand-file-name "~/code/JavaComp/bazel-bin/src/main/java/org/javacomp/server/JavaComp_deploy.jar")
                 dest-jar
                 t)
      (chmod dest-jar #o644)
      (when (functionp 'javacomp-restart-server)
        (javacomp-restart-server))
      (message "JavaComp is successfully installed"))))

(defun spacemacs/build-javacomp ()
  "Rebuild JavaComp server."
  (interactive "*")

  (let ((default-directory (expand-file-name "~/code/JavaComp/")))
    (compile "bazel build src/main/java/org/javacomp/server/JavaComp_deploy.jar")
    (with-current-buffer "*compilation*"
      (when (get-buffer "*javacomp-rebuild*")
        (kill-buffer "*javacomp-rebuild*"))
      (rename-buffer "*javacomp-rebuild*")
      (set-process-sentinel (get-buffer-process (current-buffer)) #'spacemacs//javacomp-bazel-sentinel))))
