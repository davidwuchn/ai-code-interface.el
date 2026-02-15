;;; test_ai-code-ralph.el --- Tests for ai-code-ralph.el -*- lexical-binding: t; -*-

;; Author: Kang Tu <tninja@gmail.com>
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Tests for ai-code-ralph.el behavior.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'ai-code-ralph)

(defun ai-code-ralph-test--read-file (file)
  "Return FILE contents as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun ai-code-ralph-test--write-task-file (file status attempts max-attempts)
  "Write a simple Ralph task FILE with STATUS, ATTEMPTS and MAX-ATTEMPTS."
  (with-temp-file file
    (insert "#+TITLE: Demo Task\n")
    (insert (format "#+RALPH_STATUS: %s\n" status))
    (insert (format "#+RALPH_ATTEMPTS: %d\n" attempts))
    (insert (format "#+RALPH_MAX_ATTEMPTS: %d\n" max-attempts))
    (insert "#+RALPH_VERIFY_CMD: exit 0\n\n")
    (insert "* Task Description\n\n")
    (insert "Demo task body\n")))

(ert-deftest ai-code-ralph-test-run-once-no-task ()
  "Return `no-task' when no queued Ralph task exists."
  (let ((task-dir (make-temp-file "ai-code-ralph-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "task_done.org" task-dir)
            (insert "#+RALPH_STATUS: done\n"))
          (cl-letf (((symbol-function 'ai-code--get-files-directory)
                     (lambda () task-dir)))
            (should (eq (ai-code-ralph-run-once) 'no-task))))
      (delete-directory task-dir t))))

(ert-deftest ai-code-ralph-test-run-once-success-marks-done ()
  "Mark task done and append success log when verification passes."
  (let* ((task-dir (make-temp-file "ai-code-ralph-test-" t))
         (task-file (expand-file-name "task_demo.org" task-dir))
         (sent-prompt nil))
    (unwind-protect
        (progn
          (ai-code-ralph-test--write-task-file task-file "queued" 0 3)
          (cl-letf (((symbol-function 'ai-code--get-files-directory)
                     (lambda () task-dir))
                    ((symbol-function 'ai-code--insert-prompt)
                     (lambda (prompt)
                       (setq sent-prompt prompt)))
                    ((symbol-function 'ai-code-ralph--verify-task)
                     (lambda (_file) t)))
            (should (eq (ai-code-ralph-run-once) 'done))
            (should (stringp sent-prompt))
            (let ((content (ai-code-ralph-test--read-file task-file)))
              (should (string-match-p (regexp-quote "#+RALPH_STATUS: done") content))
              (should (string-match-p "\\* Loop Log" content))
              (should (string-match-p "PASS" content)))))
      (delete-directory task-dir t))))

(ert-deftest ai-code-ralph-test-run-once-failure-requeues-before-max ()
  "Requeue task and increment attempts when verification fails below max."
  (let* ((task-dir (make-temp-file "ai-code-ralph-test-" t))
         (task-file (expand-file-name "task_demo.org" task-dir)))
    (unwind-protect
        (progn
          (ai-code-ralph-test--write-task-file task-file "queued" 0 3)
          (cl-letf (((symbol-function 'ai-code--get-files-directory)
                     (lambda () task-dir))
                    ((symbol-function 'ai-code--insert-prompt)
                     (lambda (_prompt) nil))
                    ((symbol-function 'ai-code-ralph--verify-task)
                     (lambda (_file) nil)))
            (should (eq (ai-code-ralph-run-once) 'queued))
            (let ((content (ai-code-ralph-test--read-file task-file)))
              (should (string-match-p (regexp-quote "#+RALPH_STATUS: queued") content))
              (should (string-match-p (regexp-quote "#+RALPH_ATTEMPTS: 1") content))
              (should (string-match-p "FAIL" content)))))
      (delete-directory task-dir t))))

(ert-deftest ai-code-ralph-test-run-once-failure-blocks-at-max ()
  "Block task when verification keeps failing and max attempts is reached."
  (let* ((task-dir (make-temp-file "ai-code-ralph-test-" t))
         (task-file (expand-file-name "task_demo.org" task-dir)))
    (unwind-protect
        (progn
          (ai-code-ralph-test--write-task-file task-file "queued" 2 3)
          (cl-letf (((symbol-function 'ai-code--get-files-directory)
                     (lambda () task-dir))
                    ((symbol-function 'ai-code--insert-prompt)
                     (lambda (_prompt) nil))
                    ((symbol-function 'ai-code-ralph--verify-task)
                     (lambda (_file) nil)))
            (should (eq (ai-code-ralph-run-once) 'blocked))
            (let ((content (ai-code-ralph-test--read-file task-file)))
              (should (string-match-p (regexp-quote "#+RALPH_STATUS: blocked") content))
              (should (string-match-p (regexp-quote "#+RALPH_ATTEMPTS: 3") content)))))
      (delete-directory task-dir t))))

(provide 'test_ai-code-ralph)

;;; test_ai-code-ralph.el ends here
