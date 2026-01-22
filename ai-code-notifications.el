;;; ai-code-notifications.el --- Desktop notifications for AI Code sessions  -*- lexical-binding: t; -*-

;; Author: Yoav Orot, Kang Tu, GitHub Copilot
;; SPDX-License-Identifier: Apache-2.0

;; Keywords: ai, notifications

;;; Commentary:
;; This module provides desktop notification support for AI Code sessions.
;; Notifications can alert users when AI responses are complete, useful when
;; working with multiple AI sessions or when switching between tasks.
;;
;; The module integrates with the `notifications' package (available on
;; GNU/Linux and other systems with D-Bus support) and falls back to
;; message display on systems without notification support.

;;; Code:

(require 'cl-lib)

;; Silence byte-compiler warnings
(declare-function notifications-notify "notifications" (&rest params))

;;; Customization

(defgroup ai-code-notifications nil
  "Desktop notifications for AI Code sessions."
  :group 'ai-code-backends-infra)

(defcustom ai-code-notifications-enabled t
  "Enable desktop notifications for AI Code sessions.
When non-nil, desktop notifications will be shown for various events
such as AI response completion, errors, and session state changes."
  :type 'boolean
  :group 'ai-code-notifications)

(defcustom ai-code-notifications-on-response-complete t
  "Show notification when AI completes a response.
This is useful when working with multiple sessions or when the AI
session is not in the current window."
  :type 'boolean
  :group 'ai-code-notifications)

(defcustom ai-code-notifications-on-error t
  "Show notification when an error occurs in the AI session."
  :type 'boolean
  :group 'ai-code-notifications)

(defcustom ai-code-notifications-on-session-end t
  "Show notification when an AI session terminates."
  :type 'boolean
  :group 'ai-code-notifications)

(defcustom ai-code-notifications-urgency 'normal
  "Urgency level for desktop notifications.
Can be one of `low', `normal', or `critical'."
  :type '(choice (const :tag "Low" low)
                 (const :tag "Normal" normal)
                 (const :tag "Critical" critical))
  :group 'ai-code-notifications)

(defcustom ai-code-notifications-timeout 5000
  "Timeout in milliseconds for notifications.
Set to 0 for no timeout (notification persists until dismissed).
Set to -1 to use the system default timeout."
  :type 'integer
  :group 'ai-code-notifications)

(defcustom ai-code-notifications-only-when-not-focused t
  "Only show notifications when the AI session buffer is not focused.
When non-nil, notifications are suppressed if the AI session buffer
is currently visible in the selected window."
  :type 'boolean
  :group 'ai-code-notifications)

;;; Variables

(defvar ai-code-notifications--capabilities nil
  "Cached notification system capabilities.")

;;; Helper Functions

(defun ai-code-notifications--available-p ()
  "Check if desktop notifications are available."
  (and (or (featurep 'dbusbind)
           (featurep 'notifications))
       (or (require 'notifications nil t)
           nil)))

(defun ai-code-notifications--should-notify-p (buffer)
  "Check if we should show a notification for BUFFER.
Returns non-nil if notifications are enabled and the buffer is not focused."
  (and ai-code-notifications-enabled
       buffer
       (buffer-live-p buffer)
       (or (not ai-code-notifications-only-when-not-focused)
           (not (eq buffer (window-buffer (selected-window)))))))

(defun ai-code-notifications--extract-backend-name (buffer-name)
  "Extract the backend name from BUFFER-NAME.
For example, \"*codex[my-project]*\" -> \"Codex\"."
  (when (string-match "\\*\\([^[]+\\)\\[" buffer-name)
    (let ((backend (match-string 1 buffer-name)))
      (capitalize backend))))

(defun ai-code-notifications--extract-project-name (buffer-name)
  "Extract the project name from BUFFER-NAME.
For example, \"*codex[my-project]*\" -> \"my-project\"."
  (when (string-match "\\[\\([^]]+\\)\\]" buffer-name)
    (match-string 1 buffer-name)))

;;; Notification Functions

(defun ai-code-notifications--send (title body &optional buffer)
  "Send a desktop notification with TITLE and BODY.
BUFFER is the associated AI session buffer, used for focus detection."
  (when (ai-code-notifications--should-notify-p buffer)
    (if (ai-code-notifications--available-p)
        (condition-case err
            (notifications-notify
             :title title
             :body body
             :urgency ai-code-notifications-urgency
             :timeout ai-code-notifications-timeout
             :app-name "AI Code Interface"
             :app-icon "emacs")
          (error
           (message "AI Code notification failed: %s" (error-message-string err))))
      ;; Fallback to message when notifications are not available
      (message "%s: %s" title body))))

;;;###autoload
(defun ai-code-notifications-response-complete (buffer)
  "Send notification that AI response is complete in BUFFER."
  (when (and ai-code-notifications-on-response-complete
             (buffer-live-p buffer))
    (let* ((buffer-name (buffer-name buffer))
           (backend (or (ai-code-notifications--extract-backend-name buffer-name)
                       "AI"))
           (project (or (ai-code-notifications--extract-project-name buffer-name)
                       "session")))
      (ai-code-notifications--send
       backend
       (format "Response complete in %s" project)
       buffer))))

;;;###autoload
(defun ai-code-notifications-error (buffer error-message)
  "Send notification about an error in BUFFER with ERROR-MESSAGE."
  (when (and ai-code-notifications-on-error
             (buffer-live-p buffer))
    (let* ((buffer-name (buffer-name buffer))
           (backend (or (ai-code-notifications--extract-backend-name buffer-name)
                       "AI")))
      (ai-code-notifications--send
       (format "%s Error" backend)
       error-message
       buffer))))

;;;###autoload
(defun ai-code-notifications-session-end (buffer)
  "Send notification that AI session in BUFFER has ended."
  (when (and ai-code-notifications-on-session-end
             (buffer-live-p buffer))
    (let* ((buffer-name (buffer-name buffer))
           (backend (or (ai-code-notifications--extract-backend-name buffer-name)
                       "AI"))
           (project (or (ai-code-notifications--extract-project-name buffer-name)
                       "session")))
      (ai-code-notifications--send
       backend
       (format "Session ended in %s" project)
       buffer))))

(provide 'ai-code-notifications)
;;; ai-code-notifications.el ends here
