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

(defcustom ai-code-ralph-queue-directory-name "ralph"
  "Subdirectory under `.ai.code.files` used for queued Ralph tasks."
  :type 'string
  :group 'ai-code-ralph)

(defcustom ai-code-ralph-soft-isolation-enabled t
  "When non-nil, prepend a context-boundary instruction per task."
  :type 'boolean
  :group 'ai-code-ralph)

(defvar ai-code-ralph--running nil
  "Non-nil when the Ralph loop is actively running.")

(defconst ai-code-ralph--command-choices
  '("Run queue" "Run once" "Stop")
  "Selectable actions for `ai-code-ralph-command'.")

(defun ai-code-ralph--queue-directory ()
  "Return Ralph queue directory path."
  (expand-file-name ai-code-ralph-queue-directory-name
                    (ai-code--get-files-directory)))

(defun ai-code-ralph--task-files ()
  "Return all org task files under Ralph queue directory."
  (let ((dir (ai-code-ralph--queue-directory)))
    (when (file-directory-p dir)
      (sort (directory-files dir t "\\.org\\'" t) #'string<))))

(defun ai-code-ralph--buffer-has-ralph-keyword-p ()
  "Return non-nil when current buffer includes any Ralph org keyword."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^#\\+RALPH_[A-Z0-9_]+:[ \t]*.*$" nil t)))

(defun ai-code-ralph--current-buffer-task-file ()
  "Return current buffer file when it is an org Ralph task candidate."
  (let ((file (buffer-file-name)))
    (when (and file
               (string-suffix-p ".org" file)
               (ai-code-ralph--buffer-has-ralph-keyword-p))
      file)))

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
  (when-let ((raw (ai-code-ralph--read-keyword file "RALPH_STATUS")))
    (downcase raw)))

(defun ai-code-ralph--next-queued-task ()
  "Return the first queued Ralph task file, or nil."
  (let ((current-file (ai-code-ralph--current-buffer-task-file)))
    (if (and current-file
             (string= (ai-code-ralph--task-status current-file) "queued"))
        current-file
      (cl-find-if (lambda (file)
                    (string= (ai-code-ralph--task-status file) "queued"))
                  (ai-code-ralph--task-files)))))

(defun ai-code-ralph--task-title (file)
  "Return task title read from FILE."
  (or (ai-code-ralph--read-keyword file "TITLE")
      (file-name-base file)))

(defun ai-code-ralph--build-prompt (file)
  "Build minimal Ralph prompt for FILE."
  (let* ((title (ai-code-ralph--task-title file))
         (task-id (file-name-base file))
         (boundary (when ai-code-ralph-soft-isolation-enabled
                     (format "CONTEXT BOUNDARY\nIgnore prior task context. Use only this task file and repo state for decisions.\nTask ID: %s\nCurrent task file: %s\n\n"
                             task-id
                             file))))
    (format "%sExecute task: %s\nTask file: %s\nApply minimal changes and keep tests green."
            (or boundary "")
            title
            file)))

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
          (message "Ralph: no queued task. Add org task files under %s with '#+RALPH_STATUS: queued', or run from current org buffer with Ralph headers."
                   (ai-code-ralph--queue-directory))
          'no-task)
      (message "Ralph: processing task %s" (file-name-nondirectory task))
      (ai-code-ralph--set-keyword task "RALPH_STATUS" "running")
      (ai-code--insert-prompt (ai-code-ralph--build-prompt task))
      (ai-code-ralph--append-log
       task
       (format "TASK ID: %s" (file-name-base task)))
      (ai-code-ralph--append-log task "PROMPT sent to AI")
      (ai-code-ralph--append-log
       task
       (format "VERIFY command: %s"
               (or (ai-code-ralph--read-keyword task "RALPH_VERIFY_CMD")
                   "<none>")))
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
    (unless (eq result 'no-task)
      (message "Ralph stopped after %d iterations" iterations))
    result))

;;;###autoload
(defun ai-code-ralph-stop ()
  "Stop Ralph loop."
  (interactive)
  (setq ai-code-ralph--running nil)
  (message "Ralph stopped"))

;;;###autoload
(defun ai-code-ralph-command ()
  "Run one Ralph action selected via `completing-read'."
  (interactive)
  (let ((choice (completing-read "Ralph action: "
                                 ai-code-ralph--command-choices
                                 nil t nil nil "Run queue")))
    (message "Ralph: %s requested" choice)
    (cond
     ((string= choice "Run queue") (ai-code-ralph-start))
     ((string= choice "Run once") (ai-code-ralph-run-once))
     (t (ai-code-ralph-stop)))))

(provide 'ai-code-ralph)

;;; ai-code-ralph.el ends here
