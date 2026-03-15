;;; ai-code-eca.el --- Extensions for ECA backend in ai-code -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: minimal-emacs.d
;; Version: 0.2
;; Package-Requires: ((emacs "28.1"))
;; Keywords: ai, code, assistant, eca

;;; Commentary:
;; ECA backend bridge for ai-code with:
;;   - Session management (list, switch, create, dashboard)
;;   - Workspace management (list, add, remove, sync projects)
;;   - Context commands (file, cursor, repo-map, clipboard)
;;   - Shared context (cross-session sharing)
;;   - Multi-Project Mode (auto-switch, auto-sync, mode-line)
;;   - ai-code-menu integration (transient)
;;   - Health verification and context synchronization
;;
;; Upstream ECA provides:
;;   - eca-chat-add-workspace-root (interactive workspace folder)
;;   - eca--session-add-workspace-folder (internal)
;;   - eca--session-for-worktree (worktree detection)
;;
;; MULTI-PROJECT WORKFLOWS:
;;
;; Two approaches for working with multiple projects:
;;
;; 1. SINGLE SESSION, MULTIPLE WORKSPACES (recommended):
;;    - All projects in one ECA session
;;    - AI sees context from all projects
;;    - Use: M-x ai-code-eca-multi-project-mode to enable auto-switch/sync
;;    - Use: M-x ai-code-eca-add-workspace-folder to add projects
;;
;; 2. MULTIPLE SESSIONS:
;;    - Separate ECA session per project
;;    - Isolated context per project
;;    - Use: M-x ai-code-eca-switch-session to switch between sessions
;;    - Share common context: M-x ai-code-eca-share-file
;;
;; ai-code-menu Integration (primary UX):
;;   All commands accessible via M-x ai-code-menu (C-c a) when ECA is selected:
;;
;;   ECA Workspace              ECA Context         ECA Shared Context
;;     wm - Multi-Project Mode    cf - File           F - Share file
;;     wa - Add folder            cc - Cursor         R - Share repo map
;;     wA - Add to ALL            cr - Repo map       p - Apply shared
;;     wl - List folders          cy - Clipboard      c - Clear shared
;;     wr - Remove folder         cs - Start sync
;;     ws - Sync projects         cS - Stop sync
;;     wd - Dashboard
;;     wt - Toggle auto-switch
;;
;;   ECA Sessions
;;     s? - Which session?
;;     sl - List sessions
;;     ss - Switch session
;;     sv - Verify health
;;     su - Upgrade ECA
;;
;; Auto-Detection (configurable):
;;   - eca-auto-add-workspace-folder: Add project on file open (default: t)
;;   - eca-auto-switch-session: Switch session by project (default: 'prompt)
;;   - eca-auto-create-session: Create session for new projects (default: nil)
;;   - eca-auto-sync-workspace: Sync workspace on project switch (default: t)
;;   - ai-code-eca-mode-line-indicator: Show session in mode-line (default: t)
;;
;; Usage:
;;   (require 'ai-code-eca-bridge)
;;   M-x ai-code-menu (when ECA is selected)
;;   M-x ai-code-eca-multi-project-mode (enable multi-project workflows)

;;; Code:

(require 'eca-ext nil t)
(require 'transient)

(declare-function eca-session "eca-util" ())
(declare-function eca-chat-open "eca-chat" (session))
(declare-function eca-chat--get-last-buffer "eca-chat" (session))
(declare-function eca-info "eca-util" (format-string &rest args))
(declare-function eca--session-status "eca-util" (session))
(declare-function eca--session-workspace-folders "eca-util" (session))
(declare-function eca-chat-add-workspace-root "eca-chat" ())
(declare-function ai-code-read-string "ai-code-input" (prompt &optional initial-input candidate-list))
(declare-function ai-code--repo-backend-for-root "ai-code-backends" (git-root))
(declare-function ai-code--remember-repo-backend "ai-code-backends" (git-root backend))

(defvar eca--sessions nil)
(defvar ai-code-eca--config-warned nil)

;;; Helpers

(defun ai-code-eca--ensure-chat-buffer (session)
  "Ensure ECA chat buffer for SESSION exists and return it."
  (let ((buf (eca-chat--get-last-buffer session)))
    (unless (and buf (get-buffer-window buf))
      (eca-chat-open session))
    buf))

(defun ai-code-eca--ensure-available ()
  "Ensure ECA package is available."
  (unless (require 'eca nil t)
    (user-error "ECA not available. Install with: M-x package-install RET eca RET"))
  (dolist (fn '(eca eca-session eca-chat-open eca-chat--get-last-buffer))
    (unless (fboundp fn)
      (user-error "ECA missing function: %s" fn)))
  (let ((config-file (expand-file-name "~/.config/eca/config.json")))
    (when (and (not (file-exists-p config-file))
               (not ai-code-eca--config-warned))
      (setq ai-code-eca--config-warned t)
      (message "Note: ECA config not found at %s (optional)" config-file))))

;;; Session Management (via eca-ext)

;;;###autoload
(defun ai-code-eca-get-sessions ()
  "Return list of active ECA sessions for display."
  (require 'eca-ext nil t)
  (when (fboundp 'eca-list-sessions)
    (condition-case err
        (mapcar (lambda (info)
                  (cons (plist-get info :id)
                        (format "Session %d: %s (%d chats)"
                                (plist-get info :id)
                                (mapconcat #'identity (plist-get info :workspace-folders) ", ")
                                (plist-get info :chat-count))))
                (eca-list-sessions))
      (error nil))))

;;;###autoload
(defun ai-code-eca-switch-session (&optional session-id)
  "Switch to ECA session SESSION-ID or prompt for selection."
  (interactive)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-switch-to-session)
    (user-error "Session multiplexing requires eca-ext.el"))
  (eca-switch-to-session session-id)
  (run-at-time 0.5 nil #'ai-code-eca--save-session-affinity))

;;;###autoload
(defun ai-code-eca-list-sessions ()
  "Display list of active ECA sessions."
  (interactive)
  (let ((sessions (ai-code-eca-get-sessions)))
    (if sessions
        (message "ECA Sessions: %s" (string-join (mapcar #'cdr sessions) " | "))
      (message "No active ECA sessions"))))

;;; Context Commands (via eca-ext)

;;;###autoload
(defun ai-code-eca-add-file-context (file-path)
  "Add FILE-PATH as context to current ECA session."
  (interactive "fAdd file context: ")
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
  "Add current cursor position as context to ECA session."
  (interactive)
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
  "Add repository map context to ECA session."
  (interactive)
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
  "Add clipboard contents as context to current ECA session."
  (interactive)
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
                (eca-info "Added clipboard context (%d chars)" (length clip-content)))
            (message "Clipboard is empty")))
      (user-error "No ECA session"))))

;;;###autoload
(defun ai-code-eca-add-workspace-folder ()
  "Add workspace folder using upstream eca-chat-add-workspace-root."
  (interactive)
  (unless (fboundp 'eca-chat-add-workspace-root)
    (user-error "ECA workspace features not available"))
  (eca-chat-add-workspace-root))

;;;###autoload
(defun ai-code-eca-list-workspace-folders ()
  "Display workspace folders for current ECA session."
  (interactive)
  (require 'eca-ext nil t)
  (let ((folders (eca-list-workspace-folders)))
    (if folders
        (message "ECA Workspace: %s" (string-join folders " | "))
      (message "No workspace folders in session"))))

;;;###autoload
(defun ai-code-eca-remove-workspace-folder (folder)
  "Remove FOLDER from current ECA session's workspace."
  (interactive
   (progn
     (require 'eca-ext nil t)
     (let ((folders (eca-list-workspace-folders)))
       (unless folders
         (user-error "No workspace folders in session"))
       (list (completing-read "Remove workspace folder: " folders nil t)))))
  (require 'eca-ext nil t)
  (eca-remove-workspace-folder folder))

;;;###autoload
(defun ai-code-eca-sync-project-workspaces ()
  "Sync current project roots to ECA session workspace.
Adds any project roots not already in the workspace.
Useful when working with multiple projects in one session."
  (interactive)
  (require 'eca-ext nil t)
  (let ((session (eca-session)))
    (unless session
      (user-error "No ECA session active"))
    (let* ((project-roots (or (when (fboundp 'projectile-project-root)
                                (ignore-errors (list (projectile-project-root))))
                              (when (fboundp 'project-roots)
                                (ignore-errors (project-roots (project-current))))
                              (when buffer-file-name
                                (list (file-name-directory buffer-file-name)))))
           (existing (eca-list-workspace-folders session))
           (added 0))
      (dolist (root project-roots)
        (let ((root (expand-file-name root)))
          (unless (member root existing)
            (eca-add-workspace-folder root session)
            (cl-incf added))))
      (if (> added 0)
          (message "Added %d project roots to session %d workspace" added (eca--session-id session))
        (message "All project roots already in session %d workspace" (eca--session-id session))))))

;;;###autoload
(defun ai-code-eca-add-workspace-folder-all-sessions (folder)
  "Add FOLDER to all active ECA sessions.
Useful for shared libraries that should be available in all projects."
  (interactive "DAdd to all sessions: ")
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-add-workspace-folder-all-sessions)
    (user-error "Workspace features require eca-ext.el"))
  (eca-add-workspace-folder-all-sessions folder))

;;; Gap 1: Auto Session-Project Affinity

;;;###autoload
(defun ai-code-eca-toggle-auto-switch ()
  "Toggle auto session switching based on project.
Cycles through: disabled → prompt → auto → disabled."
  (interactive)
  (setq eca-auto-switch-session
        (cond
         ((null eca-auto-switch-session) 'prompt)
         ((eq eca-auto-switch-session 'prompt) t)
         (t nil)))
  (message "ECA auto session switching: %s"
           (pcase eca-auto-switch-session
             ('prompt "prompt (asks before switching)")
             ('t "auto (switches automatically)")
             (_ "disabled"))))

;;; Multi-Project Mode Toggle

;;;###autoload
(defun ai-code-eca-multi-project-mode (&optional arg)
  "Toggle Multi-Project Mode for ECA.
With ARG, turn on if positive, off if negative.

When enabled:
- Auto-switch session when project changes (prompt mode)
- Auto-sync workspace folders
- Auto-add projects to workspace
- Show session info in mode-line"
  (interactive "P")
  (let ((enable (if arg
                    (> (prefix-numeric-value arg) 0)
                  (not (and eca-auto-switch-session
                            eca-auto-sync-workspace
                            eca-auto-add-workspace-folder)))))
    (if enable
        (progn
          (setq eca-auto-switch-session 'prompt)
          (setq eca-auto-sync-workspace t)
          (setq eca-auto-add-workspace-folder t)
          (setq ai-code-eca-mode-line-indicator t)
          (message "ECA Multi-Project Mode enabled"))
      (setq eca-auto-switch-session nil)
      (setq eca-auto-sync-workspace nil)
      (setq eca-auto-add-workspace-folder nil)
      (message "ECA Multi-Project Mode disabled"))))

;;; Gap 3: Cross-Session Context Sharing

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
  "Apply shared context to current ECA session."
  (interactive)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-apply-shared-context)
    (user-error "Shared context requires eca-ext.el"))
  (eca-apply-shared-context (eca-session)))

;;; Gap 4: Session Dashboard

;;;###autoload
(defun ai-code-eca-dashboard ()
  "Open ECA session dashboard for visual session management."
  (interactive)
  (require 'eca-ext nil t)
  (unless (fboundp 'eca-session-dashboard)
    (user-error "Dashboard requires eca-ext.el"))
  (eca-session-dashboard))

;;; Context Synchronization

(defvar ai-code-eca-context-sync-timer nil)

(defcustom ai-code-eca-context-sync-interval 60
  "Seconds between automatic context sync. nil to disable."
  :type '(choice (const :tag "Disabled" nil)
                 (integer :tag "Seconds"))
  :group 'ai-code)

;;;###autoload
(defun ai-code-eca-sync-context ()
  "Sync current buffer context to ECA session."
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
        (error (message "Context sync failed: %s" (error-message-string err)))))))

;;;###autoload
(defun ai-code-eca-context-sync-start ()
  "Start automatic context synchronization."
  (interactive)
  (when ai-code-eca-context-sync-timer
    (cancel-timer ai-code-eca-context-sync-timer))
  (when ai-code-eca-context-sync-interval
    (setq ai-code-eca-context-sync-timer
          (run-at-time t ai-code-eca-context-sync-interval #'ai-code-eca-sync-context))
    (message "ECA context sync started (%ds)" ai-code-eca-context-sync-interval)))

;;;###autoload
(defun ai-code-eca-context-sync-stop ()
  "Stop automatic context synchronization."
  (interactive)
  (when ai-code-eca-context-sync-timer
    (cancel-timer ai-code-eca-context-sync-timer)
    (setq ai-code-eca-context-sync-timer nil)
    (message "ECA context sync stopped")))

;;; Session Affinity

(defun ai-code-eca--project-root ()
  "Return project root for session affinity."
  (or (when (fboundp 'projectile-project-root)
        (ignore-errors (projectile-project-root)))
      (when (fboundp 'project-root)
        (ignore-errors (project-root (project-current))))
      default-directory))

(defun ai-code-eca--save-session-affinity ()
  "Save current ECA session as preferred for current project."
  (when-let* ((root (ai-code-eca--project-root))
              ((fboundp 'ai-code--remember-repo-backend)))
    (ai-code--remember-repo-backend root 'eca)))

;;; Gap 5: Auto Backend Switching

(defcustom ai-code-eca-auto-switch-backend t
  "If non-nil, automatically set ai-code backend to ECA when switching sessions.
When `ai-code-eca-switch-session' or `eca-switch-to-session' is called,
ensure `ai-code-selected-backend' is set to 'eca."
  :type 'boolean
  :group 'ai-code)

(defun ai-code-eca--ensure-backend-selected ()
  "Ensure ai-code backend is set to ECA."
  (when (and ai-code-eca-auto-switch-backend
             (boundp 'ai-code-selected-backend)
             (not (eq ai-code-selected-backend 'eca)))
    (setq ai-code-selected-backend 'eca)
    (when (boundp 'ai-code-mode-line)
      (setq ai-code-mode-line "ECA"))
    (message "Set ai-code backend to ECA")))

(advice-add 'eca-switch-to-session :after
            (lambda (&rest _) (ai-code-eca--ensure-backend-selected)))

;;; Gap 2: Visual Indicator of Active Project Context

(defcustom ai-code-eca-mode-line-indicator t
  "If non-nil, show ECA session info in mode-line.
Displays session ID and folder count when in a project with active session."
  :type 'boolean
  :group 'ai-code)

(defvar ai-code-eca--mode-line-string nil
  "Mode-line string showing current ECA session context.")

(defun ai-code-eca--update-mode-line (&optional _frame)
  "Update mode-line string with current session info.
_FRAME is passed by `window-buffer-change-functions' but ignored."
  (when ai-code-eca-mode-line-indicator
    (let* ((session (when (featurep 'eca) (eca-session)))
           (folders (when session (eca--session-workspace-folders session)))
           (session-id (when session (eca--session-id session)))
           (project (ai-code-eca--project-root)))
      (setq ai-code-eca--mode-line-string
            (if (and session folders)
                (format " ECA:%d[%d]" session-id (length folders))
              "")))))

(defun ai-code-eca-mode-line ()
  "Return mode-line string for ECA context."
  (ai-code-eca--update-mode-line)
  (or ai-code-eca--mode-line-string ""))

;; Add to mode-line
(add-hook 'find-file-hook #'ai-code-eca--update-mode-line)
(add-hook 'window-buffer-change-functions #'ai-code-eca--update-mode-line)

;;;###autoload
(defun ai-code-eca-which-session ()
  "Show which ECA session the current project belongs to.
Displays session ID, status, and workspace folders."
  (interactive)
  (let* ((session (when (featurep 'eca) (eca-session)))
         (project (ai-code-eca--project-root))
         (folders (when session (eca--session-workspace-folders session)))
         (session-id (when session (eca--session-id session)))
         (status (when session (eca--session-status session))))
    (if session
        (message "ECA Session %d (%s) for %s | Workspace: %s"
                 session-id status project
                 (string-join folders ", "))
      (message "No ECA session for %s" project))))

;;; Health Verification

(defcustom ai-code-eca-verify-timeout 5
  "Seconds to wait for ECA server response during verify."
  :type 'integer
  :group 'ai-code)

(defun ai-code-eca-verify ()
  "Verify ECA backend is functional."
  (condition-case nil
      (progn
        (ai-code-eca--ensure-available)
        (let ((session (eca-session)))
          (and session
               (or (not (fboundp 'eca--session-status))
                   (eq (eca--session-status session) 'ready))
               (eca-chat--get-last-buffer session)
               t)))
    (error nil)))

;;;###autoload
(defun ai-code-eca-verify-health ()
  "Verify ECA server is responsive."
  (interactive)
  (ai-code-eca--ensure-available)
  (let* ((session (eca-session))
         (start-time (current-time))
         (responsive nil))
    (if session
        (progn
          (when (fboundp 'eca--session-status)
            (let ((status (eca--session-status session)))
              (setq responsive (memq status '(ready idle)))))
          (when (and responsive (fboundp 'eca--session-workspace-folders))
            (condition-case nil
                (let ((folders (eca--session-workspace-folders session)))
                  (setq responsive (and folders (listp folders))))
              (error (setq responsive nil))))
          (let ((elapsed (float-time (time-subtract (current-time) start-time))))
            (if responsive
                (prog1 t
                  (message "ECA healthy (responded in %.2fs)" elapsed))
              (message "ECA not responding (status: %s)"
                       (if (fboundp 'eca--session-status)
                           (eca--session-status session)
                         "unknown"))
              nil)))
      (message "No ECA session active")
      nil)))

;;; Upgrade

;;;###autoload
(defun ai-code-eca-upgrade ()
  "Upgrade ECA package."
  (interactive)
  (if (package-installed-p 'eca)
      (progn
        (package-refresh-contents)
        (package-install 'eca)
        (message "ECA upgraded. Restart Emacs or re-evaluate."))
    (user-error "ECA is not installed")))

;;; Install Skills

;;;###autoload
(defun ai-code-eca-install-skills ()
  "Install skills for ECA by prompting for a skills repo URL."
  (interactive)
  (require 'ai-code-input nil t)
  (let* ((url (read-string
               "Skills repo URL for ECA: "
               nil nil "https://github.com/obra/superpowers"))
         (default-prompt
          (format
           "Install the skill from %s for this ECA session. Read the repository README to understand the installation instructions and follow them. Set up the skill files under the appropriate directory (e.g. ~/.eca/ or the project .eca/ directory) so they are available in future sessions."
           url))
         (prompt (if (and (called-interactively-p 'interactive)
                          (fboundp 'ai-code-read-string))
                     (ai-code-read-string "Edit install-skills prompt: " default-prompt)
                   default-prompt)))
    (require 'ai-code-eca nil t)
    (when (fboundp 'ai-code-eca-send)
      (ai-code-eca-send prompt))))

;;; Keybindings

(defvar ai-code-eca-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "l") #'ai-code-eca-list-sessions)
    (define-key map (kbd "s") #'ai-code-eca-switch-session)
    (define-key map (kbd "d") #'ai-code-eca-dashboard)
    (define-key map (kbd "?") #'ai-code-eca-which-session)
    (define-key map (kbd "m") #'ai-code-eca-multi-project-mode)
    (define-key map (kbd "f") #'ai-code-eca-add-file-context)
    (define-key map (kbd "F") #'ai-code-eca-share-file)
    (define-key map (kbd "c") #'ai-code-eca-add-cursor-context)
    (define-key map (kbd "r") #'ai-code-eca-add-repo-map-context)
    (define-key map (kbd "R") #'ai-code-eca-share-repo-map)
    (define-key map (kbd "y") #'ai-code-eca-add-clipboard-context)
    (define-key map (kbd "a") #'ai-code-eca-add-workspace-folder)
    (define-key map (kbd "w") #'ai-code-eca-list-workspace-folders)
    (define-key map (kbd "W") #'ai-code-eca-remove-workspace-folder)
    (define-key map (kbd "A") #'ai-code-eca-add-workspace-folder-all-sessions)
    (define-key map (kbd "S") #'ai-code-eca-sync-project-workspaces)
    (define-key map (kbd "p") #'ai-code-eca-apply-shared-context)
    (define-key map (kbd "v") #'ai-code-eca-verify-health)
    (define-key map (kbd "t") #'ai-code-eca-toggle-auto-switch)
    map)
  "Keymap for ECA extension commands.")

;;;###autoload
(defun ai-code-eca-setup-keybindings ()
  "Set up ECA keybindings in relevant maps."
  (interactive)
  (when (boundp 'eca-chat-mode-map)
    (define-key eca-chat-mode-map (kbd "C-c C-f") #'ai-code-eca-add-file-context)
    (define-key eca-chat-mode-map (kbd "C-c C-c") #'ai-code-eca-add-cursor-context)
    (define-key eca-chat-mode-map (kbd "C-c C-m") #'ai-code-eca-add-repo-map-context)
    (define-key eca-chat-mode-map (kbd "C-c C-y") #'ai-code-eca-add-clipboard-context)
    (define-key eca-chat-mode-map (kbd "C-c C-a") #'ai-code-eca-add-workspace-folder)
    (define-key eca-chat-mode-map (kbd "C-c C-w") #'ai-code-eca-list-workspace-folders)
    (define-key eca-chat-mode-map (kbd "C-c C-S-w") #'ai-code-eca-remove-workspace-folder))
  (when (boundp 'ai-code-mode-map)
    (define-key ai-code-mode-map (kbd "C-c e") ai-code-eca-keymap))
  (message "ECA extension keybindings configured"))

;;; Unload

(defun ai-code-eca--unload-function ()
  "Cleanup when unloading ai-code-eca-bridge."
  (when ai-code-eca-context-sync-timer
    (cancel-timer ai-code-eca-context-sync-timer))
  (when (boundp 'eca-chat-mode-map)
    (define-key eca-chat-mode-map (kbd "C-c C-f") nil)
    (define-key eca-chat-mode-map (kbd "C-c C-c") nil)
    (define-key eca-chat-mode-map (kbd "C-c C-m") nil)
    (define-key eca-chat-mode-map (kbd "C-c C-y") nil)
    (define-key eca-chat-mode-map (kbd "C-c C-a") nil)
    (define-key eca-chat-mode-map (kbd "C-c C-w") nil)
    (define-key eca-chat-mode-map (kbd "C-c C-S-w") nil)))

(add-hook 'ai-code-eca-bridge-unload-hook #'ai-code-eca--unload-function)

;;; Auto-setup
;; Keybindings are set up when ECA loads
;; The bridge should be loaded via user config (see init-ai.el)

(with-eval-after-load 'eca
  (ai-code-eca-setup-keybindings))

;;; Gap 1-4: ai-code-menu Integration

(defun ai-code-eca--workspace-status-description ()
  "Dynamic description showing ECA workspace status."
  (let* ((session (when (fboundp 'eca-session) (eca-session)))
         (folders (when session
                    (or (when (fboundp 'eca-list-workspace-folders)
                          (eca-list-workspace-folders session))
                        (when (fboundp 'eca--session-workspace-folders)
                          (eca--session-workspace-folders session))))))
    (if folders
        (format "Workspace (%d folders)" (length folders))
      "Workspace (no session)")))

(defun ai-code-eca--session-status-description ()
  "Dynamic description showing ECA session status."
  (let* ((session (when (fboundp 'eca-session) (eca-session)))
         (session-id (when session
                        (or (when (fboundp 'eca--session-id)
                              (eca--session-id session))
                            "?")))
         (status (when session
                   (or (when (fboundp 'eca--session-status)
                         (eca--session-status session))
                       'unknown))))
    (if session
        (format "Session %d (%s)" session-id status)
      "No session")))

(defvar ai-code-eca--menu-suffixes-added nil
  "Track whether ECA menu suffixes have been added.")

(transient-define-prefix ai-code-eca-menu ()
  "ECA-specific commands menu."
  ["ECA Commands"
   ["Workspace"
    ("m" "Multi-Project Mode" ai-code-eca-multi-project-mode)
    ("a" "Add workspace folder" ai-code-eca-add-workspace-folder)
    ("A" "Add to ALL sessions" ai-code-eca-add-workspace-folder-all-sessions)
    ("l" "List workspace folders" ai-code-eca-list-workspace-folders)
    ("r" "Remove workspace folder" ai-code-eca-remove-workspace-folder)
    ("s" "Sync project roots" ai-code-eca-sync-project-workspaces)
    ("d" "Session dashboard" ai-code-eca-dashboard)
    ("t" "Toggle auto-switch" ai-code-eca-toggle-auto-switch)]
   ["Context"
    ("f" "Add file context" ai-code-eca-add-file-context)
    ("c" "Add cursor context" ai-code-eca-add-cursor-context)
    ("M" "Add repo map" ai-code-eca-add-repo-map-context)
    ("y" "Add clipboard" ai-code-eca-add-clipboard-context)
    ("S" "Start context sync" ai-code-eca-context-sync-start)
    ("X" "Stop context sync" ai-code-eca-context-sync-stop)]
   ["Shared Context"
    ("F" "Share file" ai-code-eca-share-file)
    ("R" "Share repo map" ai-code-eca-share-repo-map)
    ("p" "Apply shared context" ai-code-eca-apply-shared-context)
    ("C" "Clear shared context" eca-clear-shared-context)]
   ["Sessions"
    ("?" "Which session?" ai-code-eca-which-session)
    ("L" "List sessions" ai-code-eca-list-sessions)
    ("w" "Switch session" ai-code-eca-switch-session)
    ("v" "Verify health" ai-code-eca-verify-health)
    ("u" "Upgrade ECA" ai-code-eca-upgrade)]])

(defun ai-code-eca--add-menu-suffixes ()
  "Add ECA submenu to ai-code-menu if ECA backend selected."
  (when (and (boundp 'ai-code-selected-backend)
             (eq ai-code-selected-backend 'eca)
             (not ai-code-eca--menu-suffixes-added)
             (featurep 'transient))
    (condition-case err
        (progn
          (transient-append-suffix 'ai-code-menu "N"
            '("E" "ECA commands" ai-code-eca-menu))
          (setq ai-code-eca--menu-suffixes-added t)
          (message "ECA menu items added to ai-code-menu"))
      (error
       (message "Failed to add ECA menu items: %s" (error-message-string err))))))

(defun ai-code-eca--remove-menu-suffixes ()
  "Remove ECA submenu from ai-code-menu."
  (when (and ai-code-eca--menu-suffixes-added
             (featurep 'transient))
    (condition-case err
        (progn
          (transient-remove-suffix 'ai-code-menu "E")
          (setq ai-code-eca--menu-suffixes-added nil))
      (error
       (message "Failed to remove ECA menu items: %s" (error-message-string err))))))

;; Hook into ai-code-menu to add ECA items conditionally
(with-eval-after-load 'ai-code
  (add-hook 'transient-setup-hook
            (lambda ()
              (when (and (boundp 'ai-code-selected-backend)
                         (eq ai-code-selected-backend 'eca))
                (ai-code-eca--add-menu-suffixes))))
  (advice-add 'ai-code-set-backend :after
              (lambda (backend)
                (when (eq backend 'eca)
                  (ai-code-eca--add-menu-suffixes)))))

(provide 'ai-code-eca)

;;; ai-code-eca.el ends here