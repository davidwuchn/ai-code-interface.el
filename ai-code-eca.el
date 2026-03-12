;;; ai-code-eca.el --- ECA backend bridge for ai-code -*- lexical-binding: t; -*-

;; Author: Kang Tu <tninja@gmail.com>
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;;
;; Bridge ai-code backend contracts (:start/:switch/:send/:resume)
;; to the external eca package.  See https://eca.dev/ for details.
;;
;;; Code:

(require 'ai-code-backends)

(declare-function eca "eca" (&optional arg))
(declare-function eca-session "eca-util" ())
(declare-function eca-chat-open "eca-chat" (session))
(declare-function eca-chat-send-prompt "eca-chat" (session message))
(declare-function eca-chat--get-last-buffer "eca-chat" (session))

(defgroup ai-code-eca nil
  "ECA backend bridge for ai-code."
  :group 'tools
  :prefix "ai-code-eca-")

(defun ai-code-eca--ensure-available ()
  "Ensure `eca' package and required functions are available."
  (unless (require 'eca nil t)
    (user-error "ECA backend not available.  Please install the eca package"))
  (dolist (fn '(eca eca-session eca-chat-open eca-chat-send-prompt eca-chat--get-last-buffer))
    (unless (fboundp fn)
      (user-error "ECA backend missing required function: %s" fn))))

;;;###autoload
(defun ai-code-eca-start (&optional arg)
  "Start or reuse an ECA session.
With prefix ARG, forward the prefix to `eca'."
  (interactive "P")
  (ai-code-eca--ensure-available)
  (let ((current-prefix-arg arg))
    (call-interactively #'eca)))

;;;###autoload
(defun ai-code-eca-switch (&optional force-prompt)
  "Switch to the ECA chat buffer.
When FORCE-PROMPT is non-nil, force a new session before switching."
  (interactive "P")
  (ai-code-eca--ensure-available)
  (if force-prompt
      (let ((current-prefix-arg '(16)))
        (call-interactively #'eca))
    (let ((session (eca-session)))
      (if session
          (progn
            (eca-chat-open session)
            (pop-to-buffer (eca-chat--get-last-buffer session)))
        (user-error "No ECA session.  Run M-x ai-code-eca-start first")))))

;;;###autoload
(defun ai-code-eca-send (line)
  "Send LINE to ECA chat."
  (interactive "sECA> ")
  (ai-code-eca--ensure-available)
  (let ((session (eca-session)))
    (if session
        (progn
          (eca-chat-open session)
          (eca-chat-send-prompt session line))
      (user-error "No ECA session.  Run M-x ai-code-eca-start first"))))

;;;###autoload
(defun ai-code-eca-resume (&optional arg)
  "Resume an ECA session.
With prefix ARG, forward the prefix to `eca'."
  (interactive "P")
  (ai-code-eca--ensure-available)
  (let ((current-prefix-arg arg))
    (call-interactively #'eca)))

(provide 'ai-code-eca)

;;; ai-code-eca.el ends here
