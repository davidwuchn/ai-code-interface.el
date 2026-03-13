;;; ai-code-eca.el --- ECA backend bridge for ai-code -*- lexical-binding: t; -*-

;; Author: davidwuchn
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;;
;; Bridge ai-code backend contracts (:start/:switch/:send/:resume)
;; to the external eca package.  See https://eca.dev/ for details.
;;
;; Optional: load eca-ext.el for session multiplexing and context management:
;;   (require 'eca-ext nil t)
;;
;;; Code:

(require 'ai-code-backends)
(require 'ai-code-input)
(require 'eca-ext nil t)

(declare-function eca "eca" (&optional arg))
(declare-function eca-session "eca-util" ())
(declare-function eca-chat-open "eca-chat" (session))
(declare-function eca-chat-send-prompt "eca-chat" (session message))
(declare-function eca-chat--get-last-buffer "eca-chat" (session))
;; eca-ext.el declarations (optional)
(declare-function eca-list-sessions "eca-ext" ())
(declare-function eca-switch-to-session "eca-ext" (&optional session-id))
(declare-function eca-chat-add-file-context "eca-ext" (session file-path))
(declare-function eca-chat-add-repo-map-context "eca-ext" (session))
(declare-function eca-chat-add-cursor-context "eca-ext" (session file-path position))
(declare-function eca-chat-add-clipboard-context "eca-ext" (session content))
(declare-function eca-info "eca-util" (format-string &rest args))
(declare-function ai-code-read-string "ai-code-input" (prompt &optional initial-input candidate-list))

(defgroup ai-code-eca nil
  "ECA backend bridge for ai-code."
  :group 'tools
  :prefix "ai-code-eca-")

(defun ai-code-eca--ensure-available ()
  "Ensure `eca' package and required functions are available."
  (unless (require 'eca nil t)
    (user-error "ECA backend not available.  Install with: M-x package-install RET eca RET"))
  (dolist (fn '(eca eca-session eca-chat-open eca-chat-send-prompt eca-chat--get-last-buffer))
    (unless (fboundp fn)
      (user-error "ECA backend incomplete: function '%s' missing.  Reinstall eca package" fn))))

(defun ai-code-eca--ensure-chat-buffer (session)
  "Ensure ECA chat buffer for SESSION exists and return it.
Only calls `eca-chat-open' if the buffer is not already visible."
  (let ((buf (eca-chat--get-last-buffer session)))
    (unless (and buf (get-buffer-window buf))
      (eca-chat-open session))
    buf))

;;;###autoload
(defun ai-code-eca-start (&optional arg)
  "Start or reuse an ECA session.
With prefix ARG, forward the prefix to `eca'."
  (interactive "P")
  (ai-code-eca--ensure-available)
  (let ((current-prefix-arg arg))
    (call-interactively #'eca))
  (message "ECA session started"))

;;;###autoload
(defun ai-code-eca-switch (&optional force-prompt)
  "Switch to the ECA chat buffer.
When FORCE-PROMPT is non-nil, start a new session before switching."
  (interactive "P")
  (ai-code-eca--ensure-available)
  (when force-prompt
    (ai-code-eca-start force-prompt)
    (message "Started new ECA session"))
  (let ((session (eca-session)))
    (if session
        (pop-to-buffer (ai-code-eca--ensure-chat-buffer session))
      (user-error "No ECA session (M-x ai-code-eca-start to create one)"))))

;;;###autoload
(defun ai-code-eca-send (line)
  "Send LINE to ECA chat."
  (interactive "sECA> ")
  (ai-code-eca--ensure-available)
  (let ((session (eca-session)))
    (if session
        (progn
          (ai-code-eca--ensure-chat-buffer session)
          (eca-chat-send-prompt session line))
      (user-error "No ECA session (M-x ai-code-eca-start to create one)"))))

;;;###autoload
(defun ai-code-eca-resume (&optional arg)
  "Resume an existing ECA session, or start a new one if none exists.
With prefix ARG, force a new session."
  (interactive "P")
  (ai-code-eca--ensure-available)
  (if arg
      (ai-code-eca-start arg)
    (let ((session (eca-session)))
      (if session
          (progn
            (pop-to-buffer (ai-code-eca--ensure-chat-buffer session))
            (message "Resumed ECA session"))
        (ai-code-eca-start)
        (message "Started new ECA session")))))

;;;###autoload
(defun ai-code-eca-verify ()
  "Return non-nil if ECA is available and has an active session."
  (condition-case nil
      (progn
        (ai-code-eca--ensure-available)
        (let ((session (eca-session)))
          (and session (eca-chat--get-last-buffer session) t)))
    (error nil)))

;;;###autoload
(defun ai-code-eca-upgrade ()
  "Upgrade ECA package via package.el."
  (interactive)
  (ai-code-eca--ensure-available)
  (if (y-or-n-p "Refresh package archives and upgrade ECA? ")
      (progn
        (package-refresh-contents)
        (package-install 'eca)
        (message "ECA upgraded successfully"))
    (message "Upgrade cancelled")))

;;;###autoload
(defun ai-code-eca-install-skills ()
  "Install skills for ECA by prompting for a skills repo URL."
  (interactive)
  (ai-code-eca--ensure-available)
  (let* ((url (read-string "Skills repo URL for ECA: "
                            "https://github.com/obra/superpowers"))
         (default-prompt
          (format "Install the skill from %s for this ECA session.  Read the repository README to understand the installation instructions and follow them.  Set up the skill files under the appropriate directory (e.g. ~/.eca/ or the project .eca/ directory) so they are available in future sessions." url))
         (prompt (if (called-interactively-p 'interactive)
                     (ai-code-read-string "Edit install-skills prompt for ECA: " default-prompt)
                   default-prompt)))
    (ai-code-eca-send prompt)))

;;; Context management (requires eca-ext.el)

;;;###autoload
(defun ai-code-eca-add-file-context (file-path)
  "Add FILE-PATH as context to the current ECA session."
  (interactive "fAdd file context: ")
  (ai-code-eca--ensure-available)
  (unless (fboundp 'eca-chat-add-file-context)
    (user-error "Context features require eca-ext.el (add to load-path)"))
  (let ((session (eca-session)))
    (if session
        (progn
          (ai-code-eca--ensure-chat-buffer session)
          (eca-chat-add-file-context session file-path)
          (eca-info "Added file context: %s" file-path))
      (user-error "No ECA session (M-x ai-code-eca-start to create one)"))))

;;;###autoload
(defun ai-code-eca-add-clipboard-context ()
  "Add clipboard contents as context to the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (unless (fboundp 'eca-chat-add-clipboard-context)
    (user-error "Context features require eca-ext.el (add to load-path)"))
  (let ((session (eca-session)))
    (if session
        (let ((clip-content (current-kill 0 t)))
          (if (and clip-content (not (string-empty-p clip-content)))
              (progn
                (ai-code-eca--ensure-chat-buffer session)
                (eca-chat-add-clipboard-context session clip-content)
                (eca-info "Added clipboard context (%d chars)" (length clip-content)))
            (message "Clipboard is empty")))
      (user-error "No ECA session (M-x ai-code-eca-start to create one)"))))

;;;###autoload
(defun ai-code-eca-add-cursor-context ()
  "Add current cursor position as context to the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (unless (fboundp 'eca-chat-add-cursor-context)
    (user-error "Context features require eca-ext.el (add to load-path)"))
  (let ((session (eca-session)))
    (if session
        (if buffer-file-name
            (progn
              (ai-code-eca--ensure-chat-buffer session)
              (eca-chat-add-cursor-context session buffer-file-name (point))
              (eca-info "Added cursor context: %s:%d" buffer-file-name (point)))
          (message "No buffer file associated with current buffer"))
      (user-error "No ECA session (M-x ai-code-eca-start to create one)"))))

;;;###autoload
(defun ai-code-eca-add-repo-map-context ()
  "Add repository map context to the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (unless (fboundp 'eca-chat-add-repo-map-context)
    (user-error "Context features require eca-ext.el (add to load-path)"))
  (let ((session (eca-session)))
    (if session
        (progn
          (ai-code-eca--ensure-chat-buffer session)
          (eca-chat-add-repo-map-context session)
          (eca-info "Added repo map context"))
      (user-error "No ECA session (M-x ai-code-eca-start to create one)"))))

;;; Session multiplexing (requires eca-ext.el)

;;;###autoload
(defun ai-code-eca-switch-session (&optional session-id)
  "Switch to ECA session SESSION-ID or prompt for selection.
Requires eca-ext.el."
  (interactive)
  (ai-code-eca--ensure-available)
  (unless (fboundp 'eca-switch-to-session)
    (user-error "Session multiplexing requires eca-ext.el (add to load-path)"))
  (eca-switch-to-session session-id))

(provide 'ai-code-eca)

;;; ai-code-eca.el ends here
