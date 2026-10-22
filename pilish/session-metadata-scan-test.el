;;; session-metadata-scan-test.el --- Pilish metadata scan tests. -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(defvar spacemacs-cache-directory temporary-file-directory)

(load (expand-file-name
       "funcs.el"
       (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(defun pilish-test--metadata-record (path first-message)
  "Build a scanner result for PATH with FIRST-MESSAGE."
  (let ((record (make-hash-table :test 'equal)))
    (puthash "path" path record)
    (puthash "valid" t record)
    (puthash "stable" t record)
    (puthash "cwd" "/tmp/pilish-metadata-test" record)
    (puthash "name" "cache regression" record)
    (puthash "firstMessage" first-message record)
    (puthash "messageCount" 1 record)
    record))

(ert-deftest pilish-local-session-scan-recurses-and-reuses-cache ()
  "Recursive local discovery scans misses once and invalidates by file size."
  (let* ((root (make-temp-file "pilish-session-root-" t))
         (nested (expand-file-name "project/deep" root))
         (file (expand-file-name "session.jsonl" nested))
         (pilish//session-cache (make-hash-table :test 'equal))
         (calls 0)
         (seen-files nil))
    (unwind-protect
        (progn
          (make-directory nested t)
          (with-temp-file file (insert "fixture"))
          (cl-letf (((symbol-function 'pilish//opened-session-files)
                     (lambda () nil))
                    ((symbol-function 'pilish--remote-prefix-for-path)
                     (lambda (_path) nil))
                    ((symbol-function 'pilish//entry-cwd)
                     (lambda (_file cwd) cwd))
                    ((symbol-function 'pilish//local-pi-run)
                     (lambda (files)
                       (setq calls (1+ calls)
                             seen-files files)
                       (let ((payload (make-hash-table :test 'equal)))
                         (puthash "sessions"
                                  (mapcar (lambda (path)
                                            (pilish-test--metadata-record
                                             path (format "scan %d" calls)))
                                          files)
                                  payload)
                         payload))))
            (let* ((first (pilish//local-session-entries nil root))
                   (entry (car (cdr first))))
              (should (equal (car first) t))
              (should (equal seen-files (list file)))
              (should (equal (plist-get entry :first-message) "scan 1"))
              (should (equal (plist-get entry :cwd)
                             "/tmp/pilish-metadata-test"))
              ;; An unchanged warm listing must not start Pi/Node again.
              (should (equal (plist-get
                              (car (cdr (pilish//local-session-entries nil root)))
                              :first-message)
                             "scan 1"))
              (should (= calls 1))
              ;; Size participates in the signature, even when mtime is coarse.
              (with-temp-file file (insert "fixture with changed size"))
              (let ((updated (pilish//local-session-entries nil root)))
                (should (= calls 2))
                (should (equal (plist-get (car (cdr updated)) :first-message)
                               "scan 2"))))))
      (delete-directory root t))))

(ert-deftest pilish-local-session-scan-falls-back-to-elisp ()
  "A failed Node scan retains the canonical per-file metadata fallback."
  (let* ((root (make-temp-file "pilish-session-fallback-" t))
         (file (expand-file-name "session.jsonl" root))
         (pilish//session-cache (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "fixture"))
          (cl-letf (((symbol-function 'pilish//opened-session-files)
                     (lambda () nil))
                    ((symbol-function 'pilish--remote-prefix-for-path)
                     (lambda (_path) nil))
                    ((symbol-function 'pilish//entry-cwd)
                     (lambda (_file cwd) cwd))
                    ((symbol-function 'pilish//local-pi-run)
                     (lambda (_files) nil))
                    ((symbol-function 'pilish//session-scan-info)
                     (lambda (_file)
                       (list :first-message "Elisp fallback"
                             :message-count 2
                             :session-name "fallback"
                             :cwd "/tmp/fallback"))))
            (let* ((entries (pilish//session-entries root))
                   (entry (car entries)))
              (should (= (length entries) 1))
              (should (equal (plist-get entry :first-message)
                             "Elisp fallback"))
              (should (equal (plist-get entry :name) "fallback")))))
      (delete-directory root t))))

(provide 'pilish-session-metadata-scan-test)
;;; session-metadata-scan-test.el ends here
