;;; test_ai-code-ralph.el --- Tests for ai-code-ralph.el -*- lexical-binding: t; -*-

;; Author: Kang Tu <tninja@gmail.com>
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Tests for ai-code-ralph.el behavior.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
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

(defun ai-code-ralph-test--ralph-dir (task-dir)
  "Return Ralph queue directory under TASK-DIR."
  (let ((dir (expand-file-name "ralph" task-dir)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    dir))

(ert-deftest ai-code-ralph-test-run-once-no-task ()
  "Return `no-task' when no queued Ralph task exists."
  (let ((task-dir (make-temp-file "ai-code-ralph-test-" t))
        (messages nil))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "task_done.org" task-dir)
            (insert "#+RALPH_STATUS: done\n"))
          (cl-letf (((symbol-function 'ai-code--get-files-directory)
                     (lambda () task-dir))
                    ((symbol-function 'message)
                     (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages))))
            (should (eq (ai-code-ralph-run-once) 'no-task))
            (should (seq-some (lambda (m) (string-match-p "no queued task" m)) messages))
            (should (seq-some (lambda (m) (string-match-p "RALPH_STATUS: queued" m)) messages))
            (should (seq-some (lambda (m) (string-match-p "/ralph" m)) messages))))
      (delete-directory task-dir t))))

(ert-deftest ai-code-ralph-test-run-once-ignores-file-without-ralph-status ()
  "Ignore org files that do not explicitly declare `#+RALPH_STATUS: queued'."
  (let* ((task-dir (make-temp-file "ai-code-ralph-test-" t))
         (task-file (expand-file-name "notes.org" task-dir))
         (original-content "#+TITLE: Notes\n\n* Scratch\n\nDo not run this file.\n"))
    (unwind-protect
        (progn
          (with-temp-file task-file
            (insert original-content))
          (cl-letf (((symbol-function 'ai-code--get-files-directory)
                     (lambda () task-dir)))
            (should (eq (ai-code-ralph-run-once) 'no-task)))
          (should (string= (ai-code-ralph-test--read-file task-file)
                           original-content)))
      (delete-directory task-dir t))))

(ert-deftest ai-code-ralph-test-run-once-success-marks-done ()
  "Mark task done and append success log when verification passes."
  (let* ((task-dir (make-temp-file "ai-code-ralph-test-" t))
         (task-file (expand-file-name "task_demo.org" (ai-code-ralph-test--ralph-dir task-dir)))
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
         (task-file (expand-file-name "task_demo.org" (ai-code-ralph-test--ralph-dir task-dir))))
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
         (task-file (expand-file-name "task_demo.org" (ai-code-ralph-test--ralph-dir task-dir))))
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

(ert-deftest ai-code-ralph-test-run-once-ignores-queued-file-outside-ralph-directory ()
  "Ignore queued task files outside `.ai.code.files/ralph`."
  (let* ((task-dir (make-temp-file "ai-code-ralph-test-" t))
         (task-file (expand-file-name "task_outside.org" task-dir)))
    (unwind-protect
        (progn
          (ai-code-ralph-test--write-task-file task-file "queued" 0 2)
          (cl-letf (((symbol-function 'ai-code--get-files-directory)
                     (lambda () task-dir)))
            (should (eq (ai-code-ralph-run-once) 'no-task)))
          (let ((content (ai-code-ralph-test--read-file task-file)))
            (should (string-match-p (regexp-quote "#+RALPH_STATUS: queued") content))
            (should-not (string-match-p "\\* Loop Log" content))))
      (delete-directory task-dir t))))

(ert-deftest ai-code-ralph-test-run-once-can-run-current-org-buffer-with-ralph-keyword ()
  "Allow running current org buffer task when it has Ralph headers."
  (let* ((task-dir (make-temp-file "ai-code-ralph-test-" t))
         (task-file (expand-file-name "task_current.org" task-dir)))
    (unwind-protect
        (progn
          (ai-code-ralph-test--write-task-file task-file "queued" 0 2)
          (with-temp-buffer
            (setq-local buffer-file-name task-file)
            (insert-file-contents task-file)
            (org-mode)
            (cl-letf (((symbol-function 'ai-code--get-files-directory)
                       (lambda () task-dir))
                      ((symbol-function 'ai-code--insert-prompt)
                       (lambda (_prompt) nil))
                      ((symbol-function 'ai-code-ralph--verify-task)
                       (lambda (_file) t)))
              (should (eq (ai-code-ralph-run-once) 'done))))
          (let ((content (ai-code-ralph-test--read-file task-file)))
            (should (string-match-p (regexp-quote "#+RALPH_STATUS: done") content))))
      (delete-directory task-dir t))))

(ert-deftest ai-code-ralph-test-command-dispatch-via-completing-read ()
  "Dispatch Ralph actions through a single completing-read command."
  (let ((start-called 0)
        (once-called 0)
        (stop-called 0)
        (messages nil))
    (cl-letf (((symbol-function 'ai-code-ralph-start)
               (lambda ()
                 (setq start-called (1+ start-called))
                 'started))
              ((symbol-function 'ai-code-ralph-run-once)
               (lambda ()
                 (setq once-called (1+ once-called))
                 'once))
              ((symbol-function 'ai-code-ralph-stop)
               (lambda ()
                 (setq stop-called (1+ stop-called))
                 'stopped))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages)))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args)
                 "Run queue")))
      (should (eq (ai-code-ralph-command) 'started))
      (should (= start-called 1))
      (should (= once-called 0))
      (should (= stop-called 0))
      (should (seq-some (lambda (m) (string-match-p "Ralph:" m)) messages)))
    (cl-letf (((symbol-function 'ai-code-ralph-start)
               (lambda ()
                 (setq start-called (1+ start-called))
                 'started))
              ((symbol-function 'ai-code-ralph-run-once)
               (lambda ()
                 (setq once-called (1+ once-called))
                 'once))
              ((symbol-function 'ai-code-ralph-stop)
               (lambda ()
                 (setq stop-called (1+ stop-called))
                 'stopped))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages)))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args)
                 "Run once")))
      (should (eq (ai-code-ralph-command) 'once))
      (should (= start-called 1))
      (should (= once-called 1))
      (should (= stop-called 0))
      (should (seq-some (lambda (m) (string-match-p "Ralph:" m)) messages)))
    (cl-letf (((symbol-function 'ai-code-ralph-start)
               (lambda ()
                 (setq start-called (1+ start-called))
                 'started))
              ((symbol-function 'ai-code-ralph-run-once)
               (lambda ()
                 (setq once-called (1+ once-called))
                 'once))
              ((symbol-function 'ai-code-ralph-stop)
               (lambda ()
                 (setq stop-called (1+ stop-called))
                 'stopped))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages)))
              ((symbol-function 'completing-read)
               (lambda (_prompt _collection &rest _args)
                 "Stop")))
      (should (eq (ai-code-ralph-command) 'stopped))
      (should (= start-called 1))
      (should (= once-called 1))
      (should (= stop-called 1))
      (should (seq-some (lambda (m) (string-match-p "Ralph:" m)) messages)))))

(ert-deftest ai-code-ralph-test-start-keeps-no-task-message-visible ()
  "When queue is empty, `ai-code-ralph-start' should not overwrite no-task guidance."
  (let ((messages nil))
    (cl-letf (((symbol-function 'ai-code--get-files-directory)
               (lambda ()
                 (make-temp-file "ai-code-ralph-empty-" t)))
              ((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) messages))))
      (should (eq (ai-code-ralph-start) 'no-task))
      (should (car messages))
      (should (string-match-p "no queued task" (car messages))))))

(provide 'test_ai-code-ralph)

;;; test_ai-code-ralph.el ends here
