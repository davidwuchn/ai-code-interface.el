;;; ai-code-eca.el --- ECA backend bridge for ai-code -*- lexical-binding: t; -*-

;; Author: davidwuchn
;; SPDX-License-Identifier: Apache-2.0

;;; Commentary:
;;
;; Bridge ai-code backend contracts (:start/:switch/:send/:resume) to the
;; external ECA package.  This file also exposes optional helpers for session
;; switching, workspace management, shared context, and health checks when the
;; bundled eca-ext.el companion is available.
;;
;;; Code:

(require 'cl-lib)
(require 'package)
(require 'subr-x)
(require 'ai-code-backends)
(require 'ai-code-input nil t)
(require 'eca-ext nil t)

(declare-function eca "eca" (&optional arg))
(declare-function eca-session "eca-util" ())
(declare-function eca-chat-open "eca-chat" (session))
(declare-function eca-chat-send-prompt "eca-chat" (session message))
(declare-function eca-chat--get-last-buffer "eca-chat" (session))
(declare-function eca-info "eca-util" (format-string &rest args))
(declare-function eca--session-id "eca-util" (session))
(declare-function eca--session-status "eca-util" (session))
(declare-function eca--session-workspace-folders "eca-util" (session))
(declare-function eca-chat-add-workspace-root "eca-chat" ())
(declare-function ai-code-read-string "ai-code-input" (prompt &optional initial-input candidate-list))
(declare-function ai-code-set-backend "ai-code-backends" (new-backend))
(declare-function ai-code--remember-repo-backend "ai-code-backends" (git-root backend))
(declare-function projectile-project-root "projectile" ())
(declare-function project-current "project" (&optional maybe-prompt dir))
(declare-function project-roots "project" (project))
(declare-function project-root "project" (project))
(declare-function package-vc-upgrade "package-vc" (package))

;; Optional eca-ext.el declarations
(declare-function eca-list-sessions "eca-ext" ())
(declare-function eca-switch-to-session "eca-ext" (&optional session-id))
(declare-function eca-list-workspace-folders "eca-ext" (&optional session))
(declare-function eca-add-workspace-folder "eca-ext" (folder &optional session))
(declare-function eca-add-workspace-folder-all-sessions "eca-ext" (folder))
(declare-function eca-remove-workspace-folder "eca-ext" (folder &optional session))
(declare-function eca-chat-add-file-context "eca-ext" (session file-path))
(declare-function eca-chat-add-repo-map-context "eca-ext" (session))
(declare-function eca-chat-add-cursor-context "eca-ext" (session file-path position))
(declare-function eca-chat-add-clipboard-context "eca-ext" (session content))
(declare-function eca-share-file-context "eca-ext" (file-path))
(declare-function eca-share-repo-map-context "eca-ext" (project-root))
(declare-function eca-apply-shared-context "eca-ext" (session))
(declare-function eca-clear-shared-context "eca-ext" ())
(declare-function eca-session-dashboard "eca-ext" ())
(declare-function transient-append-suffix "transient" (prefix loc suffix &optional face))
(declare-function transient-remove-suffix "transient" (prefix suffix))

(defgroup ai-code-eca nil
  "ECA backend bridge for ai-code."
  :group 'tools
  :prefix "ai-code-eca-")

(defcustom ai-code-eca-context-sync-interval 60
  "Seconds between automatic ECA context sync operations.
Set to nil to disable periodic syncing."
  :type '(choice (const :tag "Disabled" nil)
                 (integer :tag "Seconds"))
  :group 'ai-code-eca)

(defcustom ai-code-eca-auto-switch-backend t
  "If non-nil, keep ai-code's selected backend in sync with ECA session switches."
  :type 'boolean
  :group 'ai-code-eca)

(defcustom ai-code-eca-verify-timeout 5
  "Seconds to wait for ECA health checks.
Currently informational only."
  :type 'integer
  :group 'ai-code-eca)

(defvar ai-code-eca-context-sync-timer nil
  "Timer used for automatic ECA context synchronization.")

(defvar ai-code-eca--config-warned nil
  "Track whether the optional ECA config path warning has been shown.")

(defvar ai-code-eca--menu-suffixes-added nil
  "Track whether ECA menu entries have been added to `ai-code-menu'.")

(defconst ai-code-eca--menu-group-order
  '("ECA Workspace" "ECA Context" "ECA Shared Context" "ECA Sessions")
  "Ordered ECA transient group names added to `ai-code-menu'.")

(defconst ai-code-eca--menu-workspace-group "ECA Workspace"
  "Transient group name for ECA workspace commands.")

(defconst ai-code-eca--menu-context-group "ECA Context"
  "Transient group name for ECA context commands.")

(defconst ai-code-eca--menu-shared-context-group "ECA Shared Context"
  "Transient group name for ECA shared-context commands.")

(defun ai-code-eca--ensure-available ()
  "Ensure `eca' package and required functions are available."
  (unless (require 'eca nil t)
    (user-error "ECA backend not available.  Install with: M-x package-install RET eca RET"))
  (dolist (fn '(eca eca-session eca-chat-open eca-chat-send-prompt eca-chat--get-last-buffer))
    (unless (fboundp fn)
      (user-error "ECA backend incomplete: function '%s' missing.  Reinstall eca package" fn)))
  (let ((config-file (expand-file-name "~/.config/eca/config.json")))
    (when (and (not (file-exists-p config-file))
               (not ai-code-eca--config-warned))
      (setq ai-code-eca--config-warned t)
      (message "Note: ECA config not found at %s (optional)" config-file))))

(defun ai-code-eca--ensure-chat-buffer (session)
  "Ensure ECA chat buffer for SESSION exists and return it."
  (let ((buf (eca-chat--get-last-buffer session)))
    (unless (and buf (get-buffer-window buf))
      (eca-chat-open session))
    buf))

(defun ai-code-eca--project-root ()
  "Return a project root for the current buffer or directory."
  (or (and (fboundp 'projectile-project-root)
           (ignore-errors (projectile-project-root)))
      (and (fboundp 'project-current)
           (ignore-errors
             (when-let ((project (project-current nil default-directory)))
               (project-root project))))
      default-directory))

(defun ai-code-eca--normalize-folder-path (path)
  "Return PATH as an expanded directory path without a trailing slash."
  (directory-file-name (expand-file-name path)))

(defun ai-code-eca--save-session-affinity ()
  "Remember ECA as the preferred ai-code backend for the current project."
  (when-let* ((root (ai-code-eca--project-root))
              ((fboundp 'ai-code--remember-repo-backend)))
    (ai-code--remember-repo-backend root 'eca)))

(defun ai-code-eca--ensure-backend-selected (&rest _args)
  "Ensure ai-code is currently using the ECA backend."
  (when (and ai-code-eca-auto-switch-backend
             (boundp 'ai-code-selected-backend)
             (not (eq ai-code-selected-backend 'eca))
             (fboundp 'ai-code-set-backend))
    (ai-code-set-backend 'eca)))

(defun ai-code-eca--workspace-status-description ()
  "Return a short description of current ECA workspace state."
  (let* ((session (when (fboundp 'eca-session) (eca-session)))
         (folders (cond
                   ((not session) nil)
                   ((fboundp 'eca-list-workspace-folders)
                    (eca-list-workspace-folders session))
                   ((fboundp 'eca--session-workspace-folders)
                    (eca--session-workspace-folders session)))))
    (if folders
        (format "Workspace (%d folders)" (length folders))
      "Workspace (no session)")))

(defun ai-code-eca--session-id-safe (session)
  "Return SESSION id when available, otherwise nil."
  (when (and session (fboundp 'eca--session-id))
    (eca--session-id session)))

(defun ai-code-eca--session-status-safe (session)
  "Return SESSION status when available, otherwise nil."
  (when (and session (fboundp 'eca--session-status))
    (eca--session-status session)))

(defun ai-code-eca--session-status-description ()
  "Return a short description of current ECA session state."
  (let* ((session (when (fboundp 'eca-session) (eca-session)))
         (session-id (or (ai-code-eca--session-id-safe session) "?"))
         (status (or (ai-code-eca--session-status-safe session) 'unknown)))
    (if session
        (format "Session %s (%s)" session-id status)
      "No session")))

(defun ai-code-eca--add-menu-suffixes ()
  "Add ECA-specific sections to `ai-code-menu' when ECA is selected."
  (when (and (boundp 'ai-code-selected-backend)
             (eq ai-code-selected-backend 'eca)
             (not ai-code-eca--menu-suffixes-added)
             (featurep 'transient)
             (fboundp 'ai-code-menu))
    (condition-case err
        (progn
          (transient-append-suffix 'ai-code-menu "Other Tools"
            ["ECA Workspace"
             (:info #'ai-code-eca--session-status-description)
             (:info #'ai-code-eca--workspace-status-description)
             ("wm" "Multi-Project Mode" ai-code-eca-multi-project-mode)
             ("wa" "Add workspace folder" ai-code-eca-add-workspace-folder)
             ("wA" "Add to ALL sessions" ai-code-eca-add-workspace-folder-all-sessions)
             ("wl" "List workspace folders" ai-code-eca-list-workspace-folders)
             ("wr" "Remove workspace folder" ai-code-eca-remove-workspace-folder)
             ("ws" "Sync project roots" ai-code-eca-sync-project-workspaces)
             ("wd" "Session dashboard" ai-code-eca-dashboard)
             ("wt" "Toggle auto-switch" ai-code-eca-toggle-auto-switch)])
          (transient-append-suffix 'ai-code-menu ai-code-eca--menu-workspace-group
            ["ECA Context"
             ("cf" "Add file context" ai-code-eca-add-file-context)
             ("cc" "Add cursor context" ai-code-eca-add-cursor-context)
             ("cr" "Add repo map" ai-code-eca-add-repo-map-context)
             ("cy" "Add clipboard" ai-code-eca-add-clipboard-context)
             ("cs" "Start context sync" ai-code-eca-context-sync-start)
             ("cS" "Stop context sync" ai-code-eca-context-sync-stop)])
          (transient-append-suffix 'ai-code-menu ai-code-eca--menu-context-group
            ["ECA Shared Context"
             ("F" "Share file" ai-code-eca-share-file)
             ("R" "Share repo map" ai-code-eca-share-repo-map)
             ("p" "Apply shared context" ai-code-eca-apply-shared-context)
             ("c" "Clear shared context" eca-clear-shared-context)])
          (transient-append-suffix 'ai-code-menu ai-code-eca--menu-shared-context-group
            ["ECA Sessions"
             ("s?" "Which session?" ai-code-eca-which-session)
             ("sl" "List sessions" ai-code-eca-list-sessions)
             ("ss" "Switch session" ai-code-eca-switch-session)
             ("sv" "Verify health" ai-code-eca-verify-health)
             ("su" "Upgrade ECA" ai-code-eca-upgrade-vc)])
          (setq ai-code-eca--menu-suffixes-added t))
      (error
       (message "Failed to add ECA menu items: %s" (error-message-string err))))))

(defun ai-code-eca--remove-menu-suffixes ()
  "Remove ECA-specific sections from `ai-code-menu'."
  (when (and ai-code-eca--menu-suffixes-added
             (featurep 'transient)
             (fboundp 'ai-code-menu))
    (condition-case err
        (progn
          (dolist (group ai-code-eca--menu-group-order)
            (transient-remove-suffix 'ai-code-menu group))
          (setq ai-code-eca--menu-suffixes-added nil))
      (error
       (message "Failed to remove ECA menu items: %s" (error-message-string err))))))

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
          (and session
               (eca-chat--get-last-buffer session)
               (or (not (fboundp 'eca--session-status))
                   (memq (eca--session-status session) '(ready idle running)))
               t)))
    (error nil)))

;;;###autoload
(defun ai-code-eca-verify-health ()
  "Verify that the current ECA session appears healthy."
  (interactive)
  (ai-code-eca--ensure-available)
  (let* ((session (eca-session))
         (start-time (current-time)))
    (if session
        (let* ((status (when (fboundp 'eca--session-status)
                         (eca--session-status session)))
               (folders-ok (or (not (fboundp 'eca--session-workspace-folders))
                               (listp (eca--session-workspace-folders session))))
               (responsive (and folders-ok
                                (or (null status)
                                    (memq status '(ready idle running))))))
          (if (called-interactively-p 'interactive)
              (if responsive
                  (message "ECA healthy (responded in %.2fs)"
                           (float-time (time-subtract (current-time) start-time)))
                (message "ECA not responding (status: %s)" (or status 'unknown)))
            responsive))
      (if (called-interactively-p 'interactive)
          (message "No ECA session active")
        nil))))

;;;###autoload
(defun ai-code-eca-upgrade-vc ()
  "Upgrade ECA, preferring package-vc when available."
  (interactive)
  (cond
   ((and (featurep 'package-vc)
         (boundp 'package-vc-selected-packages)
         (alist-get 'eca package-vc-selected-packages))
    (message "Upgrading ECA via package-vc...")
    (package-vc-upgrade 'eca)
    (message "ECA upgraded.  Restart Emacs or re-evaluate the package."))
   ((package-installed-p 'eca)
    (package-refresh-contents)
    (package-install 'eca)
    (message "ECA upgraded via package.el"))
   (t
    (user-error "ECA is not installed"))))

;;;###autoload
(defun ai-code-eca-upgrade ()
  "Upgrade ECA using the available package manager."
  (interactive)
  (ai-code-eca-upgrade-vc))

;;;###autoload
(defun ai-code-eca-install-skills ()
  "Install skills for ECA by prompting for a skills repository URL."
  (interactive)
  (let* ((url (read-string "Skills repo URL for ECA: "
                           nil nil "https://github.com/obra/superpowers"))
         (default-prompt
          (format
           "Install the skill from %s for this ECA session. Read the repository README to understand the installation instructions and follow them. Set up the skill files under the appropriate directory (e.g. ~/.eca/ or the project .eca/ directory) so they are available in future sessions."
           url))
         (prompt (if (and (called-interactively-p 'interactive)
                          (fboundp 'ai-code-read-string))
                     (ai-code-read-string "Edit install-skills prompt for ECA: "
                                          default-prompt)
                   default-prompt)))
    (ai-code-eca-send prompt)))

;;; Session helpers

;;;###autoload
(defun ai-code-eca-get-sessions ()
  "Return active ECA sessions as an alist suitable for display."
  (require 'eca-ext nil t)
  (when (fboundp 'eca-list-sessions)
    (condition-case nil
        (mapcar (lambda (info)
                  (cons (plist-get info :id)
                        (format "Session %d: %s (%d chats)"
                                (plist-get info :id)
                                (mapconcat #'identity
                                           (plist-get info :workspace-folders)
                                           ", ")
                                (plist-get info :chat-count))))
                (eca-list-sessions))
      (error nil))))

;;;###autoload
(defun ai-code-eca-switch-session (&optional session-id)
  "Switch to ECA session SESSION-ID or prompt for selection."
  (interactive)
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-switch-to-session)
    (user-error "Session multiplexing requires eca-ext.el"))
  (eca-switch-to-session session-id)
  (run-at-time 0.5 nil #'ai-code-eca--save-session-affinity))

;;;###autoload
(defun ai-code-eca-list-sessions ()
  "Display active ECA sessions in the echo area."
  (interactive)
  (let ((sessions (ai-code-eca-get-sessions)))
    (if sessions
        (message "ECA Sessions: %s" (string-join (mapcar #'cdr sessions) " | "))
      (message "No active ECA sessions"))))

;;; Context helpers

;;;###autoload
(defun ai-code-eca-add-file-context (file-path)
  "Add FILE-PATH as context to the current ECA session."
  (interactive "fAdd file context: ")
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-chat-add-file-context)
    (user-error "Context features require eca-ext.el"))
  (let ((session (eca-session)))
    (if session
        (progn
          (ai-code-eca--ensure-chat-buffer session)
          (eca-chat-add-file-context session file-path)
          (eca-info "Added file context: %s" file-path))
      (user-error "No ECA session"))))

;;;###autoload
(defun ai-code-eca-add-cursor-context ()
  "Add the current cursor position as context to the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-chat-add-cursor-context)
    (user-error "Context features require eca-ext.el"))
  (let ((session (eca-session)))
    (if session
        (if buffer-file-name
            (progn
              (ai-code-eca--ensure-chat-buffer session)
              (eca-chat-add-cursor-context session buffer-file-name (point))
              (eca-info "Added cursor context: %s:%d" buffer-file-name (point)))
          (message "No buffer file"))
      (user-error "No ECA session"))))

;;;###autoload
(defun ai-code-eca-add-repo-map-context ()
  "Add repository map context to the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-chat-add-repo-map-context)
    (user-error "Context features require eca-ext.el"))
  (let ((session (eca-session)))
    (if session
        (progn
          (ai-code-eca--ensure-chat-buffer session)
          (eca-chat-add-repo-map-context session)
          (eca-info "Added repo map context"))
      (user-error "No ECA session"))))

;;;###autoload
(defun ai-code-eca-add-clipboard-context ()
  "Add current clipboard contents as context to the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-chat-add-clipboard-context)
    (user-error "Context features require eca-ext.el"))
  (let ((session (eca-session)))
    (if session
        (let ((clip-content (current-kill 0 t)))
          (if (and clip-content (not (string-empty-p clip-content)))
              (progn
                (ai-code-eca--ensure-chat-buffer session)
                (eca-chat-add-clipboard-context session clip-content)
                (eca-info "Added clipboard context (%d chars)"
                          (length clip-content)))
            (message "Clipboard is empty")))
      (user-error "No ECA session"))))

;;; Workspace helpers

;;;###autoload
(defun ai-code-eca-add-workspace-folder ()
  "Add a workspace folder to the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (if (fboundp 'eca-chat-add-workspace-root)
      (eca-chat-add-workspace-root)
    (user-error "ECA workspace features are not available")))

;;;###autoload
(defun ai-code-eca-list-workspace-folders ()
  "Display workspace folders for the current ECA session."
  (interactive)
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-list-workspace-folders)
    (user-error "Workspace features require eca-ext.el"))
  (let ((folders (eca-list-workspace-folders)))
    (if folders
        (message "ECA Workspace: %s" (string-join folders " | "))
      (message "No workspace folders in session"))))

;;;###autoload
(defun ai-code-eca-remove-workspace-folder (folder)
  "Remove FOLDER from the current ECA session workspace."
  (interactive
   (progn
     (require 'eca-ext nil t)
     (let ((folders (and (fboundp 'eca-list-workspace-folders)
                         (eca-list-workspace-folders))))
       (unless folders
         (user-error "No workspace folders in session"))
       (list (completing-read "Remove workspace folder: " folders nil t)))))
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-remove-workspace-folder)
    (user-error "Workspace features require eca-ext.el"))
  (eca-remove-workspace-folder folder))

;;;###autoload
(defun ai-code-eca-sync-project-workspaces ()
  "Sync visible project roots into the current ECA session workspace."
  (interactive)
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (let ((session (eca-session)))
    (unless session
      (user-error "No ECA session active"))
    (let* ((project-dir (or (and buffer-file-name
                                 (file-name-directory buffer-file-name))
                            default-directory))
           (project-roots-raw
            (delq nil
                  (append
                   (when (fboundp 'projectile-project-root)
                     (list (ignore-errors (projectile-project-root))))
                   (when (fboundp 'project-current)
                     (ignore-errors
                       (when-let ((project (project-current nil project-dir)))
                         (or (when (fboundp 'project-roots)
                               (project-roots project))
                             (list (project-root project))))))
                   (list project-dir))))
           (project-roots
            (delete-dups
             (mapcar (lambda (root)
                       (ai-code-eca--normalize-folder-path root))
                     project-roots-raw)))
           (existing
            (mapcar (lambda (root)
                      (ai-code-eca--normalize-folder-path root))
                    (or (when (fboundp 'eca-list-workspace-folders)
                          (eca-list-workspace-folders session))
                        (when (fboundp 'eca--session-workspace-folders)
                          (eca--session-workspace-folders session))
                        '())))
           (added 0))
      (dolist (root project-roots)
        (unless (member root existing)
          (eca-add-workspace-folder root session)
          (setq existing (cons root existing))
          (cl-incf added)))
      (if (> added 0)
          (message "Added %d project roots to session %d workspace"
                   added (eca--session-id session))
        (message "All project roots already in session %d workspace"
                 (eca--session-id session))))))

;;;###autoload
(defun ai-code-eca-add-workspace-folder-all-sessions (folder)
  "Add FOLDER to all active ECA sessions."
  (interactive "DAdd to all sessions: ")
  (ai-code-eca--ensure-available)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-add-workspace-folder-all-sessions)
    (user-error "Workspace features require eca-ext.el"))
  (eca-add-workspace-folder-all-sessions folder))

;;; Shared context helpers

;;;###autoload
(defun ai-code-eca-share-file (file-path)
  "Share FILE-PATH context across all ECA sessions."
  (interactive "fShare file: ")
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-share-file-context)
    (user-error "Shared context requires eca-ext.el"))
  (eca-share-file-context file-path))

;;;###autoload
(defun ai-code-eca-share-repo-map (project-root)
  "Share PROJECT-ROOT repo map across all ECA sessions."
  (interactive "DShare repo map: ")
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-share-repo-map-context)
    (user-error "Shared context requires eca-ext.el"))
  (eca-share-repo-map-context project-root))

;;;###autoload
(defun ai-code-eca-apply-shared-context ()
  "Apply shared context to the current ECA session."
  (interactive)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-apply-shared-context)
    (user-error "Shared context requires eca-ext.el"))
  (eca-apply-shared-context (eca-session)))

;;;###autoload
(defun ai-code-eca-dashboard ()
  "Open the optional ECA session dashboard."
  (interactive)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-session-dashboard)
    (user-error "Dashboard requires eca-ext.el"))
  (eca-session-dashboard))

;;;###autoload
(defun ai-code-eca-toggle-auto-switch ()
  "Cycle automatic ECA session switching between disabled, prompt, and auto."
  (interactive)
  (require 'eca-ext nil t)
  (unless (boundp 'eca-auto-switch-session)
    (user-error "Auto-switch support requires eca-ext.el"))
  (setq eca-auto-switch-session
        (cond
         ((null eca-auto-switch-session) 'prompt)
         ((eq eca-auto-switch-session 'prompt) t)
         (t nil)))
  (message "ECA auto session switching: %s"
           (pcase eca-auto-switch-session
             ('prompt "prompt")
             ('t "auto")
             (_ "disabled"))))

;;;###autoload
(defun ai-code-eca-multi-project-mode (&optional arg)
  "Toggle ECA multi-project mode.
With ARG, enable when positive and disable otherwise."
  (interactive "P")
  (require 'eca-ext nil t)
  (unless (and (boundp 'eca-auto-switch-session)
               (boundp 'eca-auto-sync-workspace)
               (boundp 'eca-auto-add-workspace-folder))
    (user-error "Multi-project support requires eca-ext.el"))
  (let ((enable (if arg
                    (> (prefix-numeric-value arg) 0)
                  (not (and eca-auto-switch-session
                            eca-auto-sync-workspace
                            eca-auto-add-workspace-folder)))))
    (if enable
        (progn
          (setq eca-auto-switch-session 'prompt
                eca-auto-sync-workspace t
                eca-auto-add-workspace-folder t)
          (message "ECA Multi-Project Mode enabled"))
      (setq eca-auto-switch-session nil
            eca-auto-sync-workspace nil
            eca-auto-add-workspace-folder nil)
      (message "ECA Multi-Project Mode disabled"))))

;;; Automatic context sync

;;;###autoload
(defun ai-code-eca-sync-context ()
  "Sync the current buffer context to the active ECA session."
  (interactive)
  (require 'eca-ext nil t)
  (let ((session (eca-session)))
    (when (and session buffer-file-name (fboundp 'eca-chat-add-file-context))
      (condition-case err
          (progn
            (eca-chat-add-file-context session buffer-file-name)
            (when (fboundp 'eca-chat-add-cursor-context)
              (eca-chat-add-cursor-context session buffer-file-name (point)))
            (when (called-interactively-p 'interactive)
              (message "Synced context: %s:%d" buffer-file-name (point))))
        (error
         (message "Context sync failed: %s" (error-message-string err)))))))

;;;###autoload
(defun ai-code-eca-context-sync-start ()
  "Start periodic ECA context synchronization."
  (interactive)
  (when ai-code-eca-context-sync-timer
    (cancel-timer ai-code-eca-context-sync-timer))
  (when ai-code-eca-context-sync-interval
    (setq ai-code-eca-context-sync-timer
          (run-at-time t ai-code-eca-context-sync-interval
                       #'ai-code-eca-sync-context))
    (message "ECA context sync started (%ds)" ai-code-eca-context-sync-interval)))

;;;###autoload
(defun ai-code-eca-context-sync-stop ()
  "Stop periodic ECA context synchronization."
  (interactive)
  (when ai-code-eca-context-sync-timer
    (cancel-timer ai-code-eca-context-sync-timer)
    (setq ai-code-eca-context-sync-timer nil)
    (message "ECA context sync stopped")))

;;;###autoload
(defun ai-code-eca-which-session ()
  "Display the current ECA session, status, and workspace folders."
  (interactive)
  (let* ((session (when (featurep 'eca) (eca-session)))
         (project (ai-code-eca--project-root))
         (folders (when (and session (fboundp 'eca--session-workspace-folders))
                    (eca--session-workspace-folders session)))
         (session-id (when (and session (fboundp 'eca--session-id))
                       (eca--session-id session)))
         (status (when (and session (fboundp 'eca--session-status))
                   (eca--session-status session))))
    (if session
        (message "ECA Session %d (%s) for %s | Workspace: %s"
                 session-id status project
                 (string-join folders ", "))
      (message "No ECA session for %s" project))))

(with-eval-after-load 'eca-ext
  (advice-add 'eca-switch-to-session :after #'ai-code-eca--ensure-backend-selected))

(with-eval-after-load 'ai-code
  (add-hook 'transient-setup-hook
            (lambda ()
              (when (and (boundp 'ai-code-selected-backend)
                         (eq ai-code-selected-backend 'eca))
                (ai-code-eca--add-menu-suffixes))))
  (advice-add 'ai-code-set-backend :after
              (lambda (backend)
                (if (eq backend 'eca)
                    (ai-code-eca--add-menu-suffixes)
                  (ai-code-eca--remove-menu-suffixes)))))

(provide 'ai-code-eca)

;;; ai-code-eca.el ends here
