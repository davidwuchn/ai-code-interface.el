;;; ai-code-ralph.el --- Ralph loop orchestration for AI Code Interface -*- lexical-binding: t; -*-

;; Author: Kang Tu <tninja@gmail.com>
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;; Lightweight task-loop orchestration for files under .ai.code.files.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function ai-code--get-files-directory "ai-code-prompt-mode" ())
(declare-function ai-code--insert-prompt "ai-code-prompt-mode" (prompt-text))

(defgroup ai-code-ralph nil
  "Ralph loop orchestration for AI Code Interface."
  :group 'ai-code)

(defcustom ai-code-ralph-default-max-attempts 6
  "Default max attempts for a Ralph task when not specified in the file."
  :type 'integer
  :group 'ai-code-ralph)

(defvar ai-code-ralph--running nil
  "Non-nil when the Ralph loop is actively running.")

(defun ai-code-ralph--task-files ()
  "Return all org task files under `ai-code--get-files-directory'."
  (let ((dir (ai-code--get-files-directory)))
    (when (file-directory-p dir)
      (sort (directory-files dir t "\\.org\\'" t) #'string<))))

(defun ai-code-ralph--read-file (file)
  "Return FILE content as a string."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun ai-code-ralph--write-file (file content)
  "Write CONTENT into FILE."
  (with-temp-file file
    (insert content)))

(defun ai-code-ralph--keyword-regexp (keyword)
  "Return regex for org header KEYWORD line."
  (format "^#\\+%s:[ \t]*\\(.*\\)$" (upcase keyword)))

(defun ai-code-ralph--read-keyword (file keyword)
  "Read KEYWORD value from FILE org header."
  (let ((content (ai-code-ralph--read-file file))
        (re (ai-code-ralph--keyword-regexp keyword)))
    (when (string-match re content)
      (string-trim (match-string 1 content)))))

(defun ai-code-ralph--set-keyword (file keyword value)
  "Set KEYWORD to VALUE in FILE org header."
  (let* ((content (ai-code-ralph--read-file file))
         (re (ai-code-ralph--keyword-regexp keyword))
         (line (format "#+%s: %s" (upcase keyword) value)))
    (setq content
          (if (string-match re content)
              (replace-match line t t content)
            (concat line "\n" content)))
    (ai-code-ralph--write-file file content)))

(defun ai-code-ralph--read-int-keyword (file keyword default)
  "Read integer KEYWORD from FILE, or DEFAULT when missing/invalid."
  (let ((raw (ai-code-ralph--read-keyword file keyword)))
    (if (and raw (string-match-p "\\`[0-9]+\\'" raw))
        (string-to-number raw)
      default)))

(defun ai-code-ralph--append-log (file message)
  "Append MESSAGE to FILE's loop log section."
  (let ((content (ai-code-ralph--read-file file)))
    (unless (string-match-p "^\\* Loop Log$" content)
      (setq content (concat (string-trim-right content) "\n\n* Loop Log\n\n")))
    (setq content
          (concat (string-trim-right content)
                  "\n"
                  (format "- [%s] %s"
                          (format-time-string "%Y-%m-%d %H:%M:%S")
                          message)
                  "\n"))
    (ai-code-ralph--write-file file content)))

(defun ai-code-ralph--task-status (file)
  "Return normalized Ralph status for FILE."
  (downcase (or (ai-code-ralph--read-keyword file "RALPH_STATUS") "queued")))

(defun ai-code-ralph--next-queued-task ()
  "Return the first queued Ralph task file, or nil."
  (cl-find-if (lambda (file)
                (string= (ai-code-ralph--task-status file) "queued"))
              (ai-code-ralph--task-files)))

(defun ai-code-ralph--task-title (file)
  "Return task title read from FILE."
  (or (ai-code-ralph--read-keyword file "TITLE")
      (file-name-base file)))

(defun ai-code-ralph--build-prompt (file)
  "Build minimal Ralph prompt for FILE."
  (format "Execute task: %s\nTask file: %s\nApply minimal changes and keep tests green."
          (ai-code-ralph--task-title file)
          file))

(defun ai-code-ralph--verify-task (file)
  "Run verify command for FILE. Return non-nil when command succeeds."
  (let ((cmd (ai-code-ralph--read-keyword file "RALPH_VERIFY_CMD")))
    (if (string-empty-p (or cmd ""))
        t
      (let ((default-directory (file-name-directory file)))
        (= 0 (shell-command cmd))))))

;;;###autoload
(defun ai-code-ralph-run-once ()
  "Run one Ralph loop iteration over the next queued task.
Return one of: `no-task', `done', `queued', `blocked'."
  (interactive)
  (let ((task (ai-code-ralph--next-queued-task)))
    (if (not task)
        (progn
          (message "Ralph: no queued task")
          'no-task)
      (ai-code-ralph--set-keyword task "RALPH_STATUS" "running")
      (ai-code--insert-prompt (ai-code-ralph--build-prompt task))
      (if (ai-code-ralph--verify-task task)
          (progn
            (ai-code-ralph--set-keyword task "RALPH_STATUS" "done")
            (ai-code-ralph--append-log task "PASS verification succeeded")
            'done)
        (let* ((attempts (1+ (ai-code-ralph--read-int-keyword task "RALPH_ATTEMPTS" 0)))
               (max-attempts (ai-code-ralph--read-int-keyword task "RALPH_MAX_ATTEMPTS"
                                                              ai-code-ralph-default-max-attempts)))
          (ai-code-ralph--set-keyword task "RALPH_ATTEMPTS" (number-to-string attempts))
          (if (>= attempts max-attempts)
              (progn
                (ai-code-ralph--set-keyword task "RALPH_STATUS" "blocked")
                (ai-code-ralph--append-log task "FAIL verification failed, max attempts reached")
                'blocked)
            (ai-code-ralph--set-keyword task "RALPH_STATUS" "queued")
            (ai-code-ralph--append-log task
                                       (format "FAIL verification failed, retry %d/%d"
                                               attempts
                                               max-attempts))
            'queued))))))

;;;###autoload
(defun ai-code-ralph-start ()
  "Run Ralph loop continuously until no queued tasks remain or stopped."
  (interactive)
  (setq ai-code-ralph--running t)
  (let ((iterations 0)
        (result nil))
    (while (and ai-code-ralph--running (< iterations 1000))
      (setq result (ai-code-ralph-run-once))
      (setq iterations (1+ iterations))
      (when (eq result 'no-task)
        (setq ai-code-ralph--running nil)))
    (message "Ralph stopped after %d iterations" iterations)
    result))

;;;###autoload
(defun ai-code-ralph-stop ()
  "Stop Ralph loop."
  (interactive)
  (setq ai-code-ralph--running nil)
  (message "Ralph stopped"))

(provide 'ai-code-ralph)

;;; ai-code-ralph.el ends here
