;;; emacs-kit-conductor.el --- Orchestrate parallel agent-shell workspaces  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Author: Kyle Bolton
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Conductor-like workflow for Emacs: create isolated git worktree
;; workspaces, launch agent-shell sessions in them, and send diff
;; feedback from magit to running agents.

;;; Code:

(eval-when-compile
  (require 'magit-section)
  (require 'transient))

(defcustom emacs-kit-conductor-default-agent nil
  "Agent to start automatically for new or resumed conductor workspaces.

When nil, conductor defers to `agent-shell' and prompts for the agent."
  :type '(choice (const :tag "Claude" claude)
                 (const :tag "Codex" codex)
                 (const :tag "Ask Every Time" nil))
  :group 'emacs-kit)

(declare-function agent-shell "agent-shell")
(declare-function agent-shell-anthropic-start-claude-code "agent-shell-anthropic")
(declare-function agent-shell-get-config "agent-shell")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-openai-start-codex "agent-shell-openai")
(declare-function shell-maker-busy "shell-maker")
(declare-function magit-current-section "magit-section")
(declare-function magit-file-at-point "magit-git")
(declare-function magit-run-git "magit-process")
(declare-function persp-switch "perspective")

(use-package emacs-kit-conductor
  :ensure nil
  :no-require t
  :init
  (defun emacs-kit/conductor--require-agent-shell (&optional agent)
    "Load `agent-shell' support for AGENT.
AGENT should be `claude', `codex', or nil."
    (require 'agent-shell)
    (pcase agent
      ('claude (require 'agent-shell-anthropic))
      ('codex (require 'agent-shell-openai))))

  (defun emacs-kit/conductor--normalize-dir (dir)
    "Return DIR as an expanded directory name without a trailing slash."
    (directory-file-name (expand-file-name dir)))

  (defun emacs-kit/conductor--worktree-repo-name (&optional dir)
    "Return the repo name for worktree DIR under `~/.worktrees', or nil."
    (let* ((dir (emacs-kit/conductor--normalize-dir (or dir default-directory)))
           (base (file-name-as-directory (expand-file-name "~/.worktrees/"))))
      (when (string-prefix-p base (file-name-as-directory dir))
        (car (split-string (string-remove-prefix base
                                                 (file-name-as-directory dir))
                           "/" t)))))

  (defun emacs-kit/conductor--remember-project (dir)
    "Remember the project rooted at DIR."
    (let ((default-directory dir))
      (when-let* ((project (project-current nil dir)))
        (project-remember-project project))))

  (defun emacs-kit/conductor--agent-shell-buffer-for-dir (dir)
    "Return the live `agent-shell' buffer for DIR, or nil."
    (let ((dir (emacs-kit/conductor--normalize-dir dir)))
      (seq-find
       (lambda (buffer)
         (and (buffer-live-p buffer)
              (with-current-buffer buffer
                (and (derived-mode-p 'agent-shell-mode)
                     (string=
                      (emacs-kit/conductor--normalize-dir default-directory)
                      dir)
                     (get-buffer-process buffer)))))
       (buffer-list))))

  (defun emacs-kit/conductor--agent-label (buffer)
    "Return a human-friendly label for agent BUFFER."
    (let ((identifier (map-elt (agent-shell-get-config buffer) :identifier)))
      (pcase identifier
        ('claude-code "Claude")
        ('codex "Codex")
        ((pred symbolp) (capitalize (symbol-name identifier)))
        (_ "Agent"))))

  (defun emacs-kit/conductor--section-text (section)
    "Return SECTION text without text properties, or nil."
    (when section
      ;; `slot-value' avoids byte-compiler slot resolution issues here while
      ;; still reading Magit's `start' and `end' markers directly.
      (buffer-substring-no-properties
       (slot-value section 'start)
       (slot-value section 'end))))

  (defun emacs-kit/conductor--start-agent (&optional agent dir)
    "Start AGENT in DIR and return its shell buffer.
AGENT should be `claude', `codex', or nil to use the default."
    (let ((agent (or agent emacs-kit-conductor-default-agent)))
      (emacs-kit/conductor--require-agent-shell agent)
      (let ((default-directory (or dir default-directory)))
        (pcase agent
          ('claude (agent-shell-anthropic-start-claude-code))
          ('codex (agent-shell-openai-start-codex))
          (_ (agent-shell))))))

  (defun emacs-kit/conductor--send-to-agent (message &optional dir shell-buffer)
    "Send MESSAGE to an `agent-shell' session.
Use SHELL-BUFFER when provided, otherwise resolve the session from DIR."
    (emacs-kit/conductor--require-agent-shell)
    (let* ((default-directory (or dir default-directory))
           (shell-buffer (or shell-buffer
                             (emacs-kit/conductor--agent-shell-buffer-for-dir
                              default-directory))))
      (unless shell-buffer
        (user-error "No agent-shell session found for %s"
                    (abbreviate-file-name default-directory)))
      (agent-shell-insert :shell-buffer shell-buffer
                          :text message
                          :submit t
                          :no-focus t)))

  (defun emacs-kit/conductor--setup-workspace (worktree-dir branch task)
    "Common setup for a conductor workspace.
Opens perspective, magit, an agent session, and optionally sends TASK."
    (emacs-kit/conductor--remember-project worktree-dir)
    (persp-switch branch)
    (require 'magit)
    (let ((default-directory worktree-dir))
      (magit-status-setup-buffer worktree-dir))
    (let ((shell-buffer (emacs-kit/conductor--start-agent
                         emacs-kit-conductor-default-agent
                         worktree-dir)))
      (when (and task (not (string-empty-p task)))
        (emacs-kit/conductor--send-to-agent task worktree-dir shell-buffer))))

  (defun emacs-kit/conductor-new-workspace (branch task)
    "Create an isolated workspace from a new branch off main.
BRANCH is the new branch name.  TASK is the initial prompt for the agent."
    (interactive "sBranch name: \nsTask description: ")
    (let* ((repo-root (or (vc-root-dir)
                          (user-error "Not in a git repository")))
           (repo-name (file-name-nondirectory (directory-file-name repo-root)))
           (worktree-dir (expand-file-name
                          (format "~/.worktrees/%s/%s" repo-name branch))))
      (let ((default-directory repo-root))
        (unless (zerop (call-process "git" nil nil nil
                                     "worktree" "add" "-b" branch worktree-dir "main"))
          (user-error "Failed to create worktree at %s" worktree-dir)))
      (emacs-kit/conductor--setup-workspace worktree-dir branch task)))

  (defun emacs-kit/conductor-open-branch (branch task)
    "Create a workspace from an existing branch.
BRANCH is an existing branch name.  TASK is the initial prompt for the agent."
    (interactive
     (let* ((repo-root (or (vc-root-dir)
                           (user-error "Not in a git repository")))
            (default-directory repo-root)
            (branches (split-string
                       (shell-command-to-string
                        "git branch --format='%(refname:short)' --sort=-committerdate")
                       "\n" t)))
       (list (completing-read "Branch: " branches nil t)
             (read-string "Task description: "))))
    (let* ((repo-root (or (vc-root-dir)
                          (user-error "Not in a git repository")))
           (repo-name (file-name-nondirectory (directory-file-name repo-root)))
           (worktree-dir (expand-file-name
                          (format "~/.worktrees/%s/%s" repo-name branch))))
      (let ((default-directory repo-root))
        (unless (zerop (call-process "git" nil nil nil
                                     "worktree" "add" worktree-dir branch))
          (user-error "Failed to create worktree for branch %s" branch)))
      (emacs-kit/conductor--setup-workspace worktree-dir branch task)))

  (defun emacs-kit/conductor-comment-on-diff ()
    "From a magit diff, send the hunk at point with feedback to the agent.
If a region is active, send only the selected lines with the full
hunk as context."
    (interactive)
    (unless (derived-mode-p 'magit-diff-mode 'magit-status-mode)
      (user-error "Not in a magit diff buffer"))
    (let* ((section (magit-current-section))
           (hunk-text (emacs-kit/conductor--section-text section))
           (selection (when (use-region-p)
                        (buffer-substring-no-properties
                         (region-beginning) (region-end))))
           (file (magit-file-at-point))
           (feedback (read-string "Feedback: "))
           (message (if selection
                        (format "In %s, regarding these specific lines:\n\n```diff\n%s\n```\n\nFull hunk for context:\n\n```diff\n%s\n```\n\n%s"
                                (or file "unknown file") selection hunk-text feedback)
                      (format "In %s, regarding this change:\n\n```diff\n%s\n```\n\n%s"
                              (or file "unknown file") hunk-text feedback))))
      (unless hunk-text
        (user-error "No diff hunk at point"))
      (emacs-kit/conductor--send-to-agent message)))

  (defun emacs-kit/conductor--current-worktree-dir ()
    "Return the worktree directory for the current perspective, or nil."
    (let ((persp (persp-current-name)))
      (cdr (assoc persp (emacs-kit/conductor--worktree-dirs)))))

  (defun emacs-kit/conductor--find-worktree-in (dir)
    "Find the first git worktree directory under DIR."
    (catch 'found
      (dolist (entry (directory-files dir t "\\`[^.]"))
        (when (file-directory-p entry)
          (if (file-exists-p (expand-file-name ".git" entry))
              (throw 'found entry)
            ;; Check one level deeper for slash-branched worktrees
            (dolist (sub (directory-files entry t "\\`[^.]"))
              (when (and (file-directory-p sub)
                         (file-exists-p (expand-file-name ".git" sub)))
                (throw 'found sub))))))))

  (defun emacs-kit/conductor--worktree-dirs ()
    "Return alist of (BRANCH . DIR) for all worktrees under ~/.worktrees.
Uses `git worktree list' to find worktrees, filtering to those in ~/.worktrees."
    (let ((base (expand-file-name "~/.worktrees/"))
          results)
      (when (file-directory-p base)
        (dolist (repo-dir (directory-files base t "\\`[^.]"))
          (when (file-directory-p repo-dir)
            ;; Find any worktree to run git from
            (when-let* ((sample-wt (emacs-kit/conductor--find-worktree-in repo-dir)))
              (with-temp-buffer
                (let ((default-directory sample-wt))
                  (when (zerop (call-process "git" nil t nil
                                             "worktree" "list" "--porcelain"))
                    (goto-char (point-min))
                    (let (wt-path wt-branch)
                      (while (not (eobp))
                        (let ((line (buffer-substring-no-properties
                                     (line-beginning-position) (line-end-position))))
                          (cond
                           ((string-prefix-p "worktree " line)
                            (setq wt-path (substring line 9)))
                           ((string-prefix-p "branch refs/heads/" line)
                            (setq wt-branch (substring line 18)))
                           ((string-empty-p line)
                            (when (and wt-path wt-branch
                                       (string-prefix-p base wt-path))
                              (push (cons wt-branch wt-path) results))
                            (setq wt-path nil wt-branch nil))))
                        (forward-line 1))
                      ;; Handle last entry if no trailing blank line
                      (when (and wt-path wt-branch
                                 (string-prefix-p base wt-path))
                        (push (cons wt-branch wt-path) results))))))))))
      (nreverse results)))

  (defun emacs-kit/conductor-resume-workspace (branch)
    "Resume an existing worktree as a conductor workspace.
Opens a perspective with magit and an agent session for the selected worktree."
    (interactive
     (let ((worktrees (emacs-kit/conductor--worktree-dirs)))
       (unless worktrees
         (user-error "No worktrees found in ~/.worktrees"))
       (list (completing-read "Resume workspace: "
                              (mapcar #'car worktrees) nil t))))
    (let* ((worktrees (emacs-kit/conductor--worktree-dirs))
           (worktree-dir (cdr (assoc branch worktrees))))
      (unless worktree-dir
        (user-error "Worktree not found: %s" branch))
      (emacs-kit/conductor--remember-project worktree-dir)
      (persp-switch branch)
      (require 'magit)
      (let ((default-directory worktree-dir))
        (magit-status-setup-buffer worktree-dir))
      (emacs-kit/conductor--start-agent emacs-kit-conductor-default-agent
                                        worktree-dir)))

  (defun emacs-kit/conductor-resume-all ()
    "Resume all existing worktrees as conductor workspaces."
    (interactive)
    (require 'magit)
    (let ((worktrees (emacs-kit/conductor--worktree-dirs)))
      (unless worktrees
        (user-error "No worktrees found in ~/.worktrees"))
      (dolist (wt worktrees)
        (let ((branch (car wt))
              (dir (cdr wt)))
          (emacs-kit/conductor--remember-project dir)
          (persp-switch branch)
          (let ((default-directory dir))
            (magit-status-setup-buffer dir))
          (emacs-kit/conductor--start-agent emacs-kit-conductor-default-agent
                                            dir)))
      (message "Resumed %d workspaces" (length worktrees))))

  (defun emacs-kit/conductor-delete-workspace (branch)
    "Delete a conductor workspace: kill perspective, remove worktree, delete branch.
Prompts for confirmation before proceeding."
    (interactive
     (let ((worktrees (emacs-kit/conductor--worktree-dirs)))
       (unless worktrees
         (user-error "No worktrees found in ~/.worktrees"))
       (list (completing-read "Delete workspace: "
                              (mapcar #'car worktrees) nil t))))
    (let* ((worktrees (emacs-kit/conductor--worktree-dirs))
           (worktree-dir (cdr (assoc branch worktrees))))
      (unless worktree-dir
        (user-error "Worktree not found: %s" branch))
      (unless (yes-or-no-p (format "Delete workspace '%s'? (worktree + branch) " branch))
        (user-error "Aborted"))
      ;; Remove from project.el
      (project-forget-project (file-name-as-directory
                               (abbreviate-file-name worktree-dir)))
      ;; Kill the perspective if it exists
      (when (member branch (persp-names))
        (persp-switch "main")
        (persp-kill branch))
      ;; Remove the git worktree
      (let ((repo-root (with-temp-buffer
                         (let ((default-directory worktree-dir))
                           (when (zerop (call-process "git" nil t nil
                                                      "rev-parse" "--path-format=absolute"
                                                      "--git-common-dir"))
                             (file-name-directory
                              (string-trim (buffer-string))))))))
        (when repo-root
          (let ((default-directory repo-root))
            (call-process "git" nil nil nil "worktree" "remove" "--force" worktree-dir)
            (call-process "git" nil nil nil "branch" "-D" branch))))
      (message "Deleted workspace '%s'" branch)))

  ;; --- Dashboard ---

  (defvar emacs-kit/conductor-dashboard-mode-map
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "r") #'emacs-kit/conductor-dashboard)
      (define-key map (kbd "RET") #'emacs-kit/conductor-dashboard-open)
      (define-key map (kbd "R") #'emacs-kit/conductor-dashboard-resume)
      (define-key map (kbd "D") #'emacs-kit/conductor-dashboard-delete)
      map))

  (defvar emacs-kit/conductor--refresh-timer nil)
  (defvar emacs-kit/conductor--prev-states (make-hash-table :test 'equal))
  (defvar emacs-kit/conductor--newly-idle nil)

  (define-derived-mode emacs-kit/conductor-dashboard-mode tabulated-list-mode
    "Conductor"
    "Major mode for the Conductor workspace dashboard."
    (setq tabulated-list-format [(" " 2 nil)
                                 ("Workspace" 30 t)
                                 ("Repo" 20 t)
                                 ("Agent" 10 t)
                                 ("Perspective" 12 t)
                                 ("Path" 0 t)])
    (setq tabulated-list-sort-key '("Workspace"))
    (tabulated-list-init-header)
    (add-hook 'kill-buffer-hook #'emacs-kit/conductor--stop-refresh nil t))

  (defun emacs-kit/conductor--workspace-entries ()
    "Build tabulated-list entries for all conductor workspaces."
    (let ((worktrees (emacs-kit/conductor--worktree-dirs))
          (active-persps (persp-names))
          entries)
      (dolist (wt worktrees)
        (let* ((branch (car wt))
               (dir (cdr wt))
               (repo (file-name-nondirectory
                      (directory-file-name (file-name-directory dir))))
               (shell-buffer (emacs-kit/conductor--agent-shell-buffer-for-dir dir))
               (has-process (and shell-buffer (get-buffer-process shell-buffer)))
               (busy (and has-process
                          (with-current-buffer shell-buffer
                            (shell-maker-busy))))
               (agent-label (and shell-buffer
                                 (emacs-kit/conductor--agent-label shell-buffer)))
               (status (cond
                        (busy "working")
                        (has-process agent-label)
                        (t "off")))
               (persp-status (if (member branch active-persps) "active" ""))
               (indicator (cond
                           ((member branch emacs-kit/conductor--newly-idle)
                            (propertize "\u25cf" 'face '(:foreground "#a6e3a1")))
                           ((equal status "working")
                            (propertize "\u25cf" 'face '(:foreground "#f9e2af")))
                           (t ""))))
          (push (list branch
                      (vector indicator branch repo status persp-status
                              (abbreviate-file-name dir)))
                entries)))
      (nreverse entries)))

  (defun emacs-kit/conductor--detect-transitions (entries)
    "Update newly-idle list based on state transitions in ENTRIES."
    (dolist (entry entries)
      (let* ((branch (car entry))
             (status (aref (cadr entry) 2))
             (prev (gethash branch emacs-kit/conductor--prev-states)))
        (when (and (not (equal status "working"))
                   (equal prev "working"))
          (cl-pushnew branch emacs-kit/conductor--newly-idle :test #'equal))
        (puthash branch status emacs-kit/conductor--prev-states))))

  (defun emacs-kit/conductor--clear-at-point ()
    "Clear the newly-idle indicator for the workspace at point."
    (when-let* ((branch (tabulated-list-get-id)))
      (setq emacs-kit/conductor--newly-idle
            (delete branch emacs-kit/conductor--newly-idle))))

  (defun emacs-kit/conductor--refresh-if-visible ()
    "Refresh the dashboard if it's visible in a window."
    (when-let* ((buf (get-buffer "*Conductor*"))
                ((get-buffer-window buf t)))
      (with-current-buffer buf
        (let ((pos (point)))
          (setq tabulated-list-entries (emacs-kit/conductor--workspace-entries))
          (emacs-kit/conductor--detect-transitions tabulated-list-entries)
          (tabulated-list-print t)
          (goto-char (min pos (point-max)))))))

  (defun emacs-kit/conductor--stop-refresh ()
    "Stop the dashboard auto-refresh timer."
    (when emacs-kit/conductor--refresh-timer
      (cancel-timer emacs-kit/conductor--refresh-timer)
      (setq emacs-kit/conductor--refresh-timer nil)))

  (defun emacs-kit/conductor-dashboard ()
    "Open the Conductor workspace dashboard."
    (interactive)
    (let ((buf (get-buffer-create "*Conductor*")))
      (with-current-buffer buf
        (emacs-kit/conductor-dashboard-mode)
        (setq tabulated-list-entries (emacs-kit/conductor--workspace-entries))
        (tabulated-list-print t))
      (pop-to-buffer buf)
      ;; Start auto-refresh every 5 seconds
      (emacs-kit/conductor--stop-refresh)
      (setq emacs-kit/conductor--refresh-timer
            (run-with-timer 5 5 #'emacs-kit/conductor--refresh-if-visible))))

  (defun emacs-kit/conductor-dashboard--branch ()
    "Get the branch name at point in the dashboard."
    (or (tabulated-list-get-id)
        (user-error "No workspace at point")))

  (defun emacs-kit/conductor-dashboard-open ()
    "Switch to the perspective for the workspace at point."
    (interactive)
    (emacs-kit/conductor--clear-at-point)
    (let ((branch (emacs-kit/conductor-dashboard--branch)))
      (if (member branch (persp-names))
          (persp-switch branch)
        (emacs-kit/conductor-resume-workspace branch))))

  (defun emacs-kit/conductor-dashboard-resume ()
    "Resume the workspace at point."
    (interactive)
    (emacs-kit/conductor--clear-at-point)
    (emacs-kit/conductor-resume-workspace
     (emacs-kit/conductor-dashboard--branch)))

  (defun emacs-kit/conductor-dashboard-delete ()
    "Delete the workspace at point."
    (interactive)
    (let ((branch (emacs-kit/conductor-dashboard--branch)))
      (emacs-kit/conductor-delete-workspace branch)
      (emacs-kit/conductor-dashboard)))

  (defun emacs-kit/conductor-shell ()
    "Open a vterm shell in the current workspace's worktree directory."
    (interactive)
    (require 'vterm)
    (let* ((dir (or (vc-root-dir) default-directory))
           (name (file-name-nondirectory (directory-file-name dir)))
           (vterm-buffer-name (format "*shell:%s*" name))
           (existing (get-buffer vterm-buffer-name)))
      (if (and existing (get-buffer-process existing))
          (pop-to-buffer existing)
        (when (and existing (not (get-buffer-process existing)))
          (kill-buffer existing))
        (let ((default-directory dir))
          (vterm vterm-buffer-name)))))

  ;; --- Workspace-aware wrappers ---

  (defun emacs-kit/conductor-workspace-agent ()
    "Open the default agent in the current workspace's directory."
    (interactive)
    (let ((default-directory (or (emacs-kit/conductor--current-worktree-dir)
                                 default-directory)))
      (emacs-kit/conductor--start-agent emacs-kit-conductor-default-agent
                                        default-directory)))

  (defun emacs-kit/conductor-workspace-claude ()
    "Open a Claude agent session in the current workspace's directory."
    (interactive)
    (let ((default-directory (or (emacs-kit/conductor--current-worktree-dir)
                                 default-directory)))
      (emacs-kit/conductor--start-agent 'claude default-directory)))

  (defun emacs-kit/conductor-workspace-codex ()
    "Open a Codex agent session in the current workspace's directory."
    (interactive)
    (let ((default-directory (or (emacs-kit/conductor--current-worktree-dir)
                                 default-directory)))
      (emacs-kit/conductor--start-agent 'codex default-directory)))

  (defun emacs-kit/conductor-workspace-shell ()
    "Open a shell in the current workspace's directory."
    (interactive)
    (let ((default-directory (or (emacs-kit/conductor--current-worktree-dir)
                                 default-directory)))
      (emacs-kit/conductor-shell)))

  (defun emacs-kit/conductor-workspace-magit ()
    "Open magit in the current workspace's directory."
    (interactive)
    (require 'magit)
    (let* ((dir (or (emacs-kit/conductor--current-worktree-dir)
                    default-directory)))
      (magit-status-setup-buffer dir)))

  ;; --- Transient Menu ---

  (require 'transient)

  (defun emacs-kit/conductor-workspace-dired ()
    "Open dired at the current workspace's root directory."
    (interactive)
    (let ((dir (or (emacs-kit/conductor--current-worktree-dir)
                   default-directory)))
      (dired dir)))

  (defun emacs-kit/conductor-workspace-project ()
    "Open project dispatch for the current workspace."
    (interactive)
    (let ((default-directory (or (emacs-kit/conductor--current-worktree-dir)
                                 default-directory)))
      (project-switch-project default-directory)))

  (defun emacs-kit/conductor--core-context-p ()
    "Return non-nil if the active context is the digits core repo or a core worktree."
    (when-let* ((root (or (emacs-kit/conductor--current-worktree-dir)
                          (vc-root-dir))))
      (let ((root (directory-file-name (expand-file-name root))))
        (or (string= (file-name-nondirectory root) "core")
            (equal (emacs-kit/conductor--worktree-repo-name root) "core")
            (string= (file-name-nondirectory
                      (directory-file-name (file-name-directory root)))
                     "core")))))

  (transient-define-prefix emacs-kit/conductor ()
    "Conductor workspace orchestration."
    ["Workspaces"
     ("w" "New workspace" emacs-kit/conductor-new-workspace)
     ("b" "From existing branch" emacs-kit/conductor-open-branch)
     ("W" "Resume workspace" emacs-kit/conductor-resume-workspace)
     ("a" "Resume all" emacs-kit/conductor-resume-all)
     ("d" "Dashboard" emacs-kit/conductor-dashboard)
     ("Q" "Delete workspace" emacs-kit/conductor-delete-workspace)]
    ["Current workspace"
     ("i" "Default agent" emacs-kit/conductor-workspace-agent)
     ("c" "Claude agent" emacs-kit/conductor-workspace-claude)
     ("x" "Codex agent" emacs-kit/conductor-workspace-codex)
     ("t" "Shell" emacs-kit/conductor-workspace-shell)
     ("g" "Magit" emacs-kit/conductor-workspace-magit)
     ("f" "Files (dired)" emacs-kit/conductor-workspace-dired)
     ("p" "Project" emacs-kit/conductor-workspace-project)
     ("r" "Comment on diff" emacs-kit/conductor-comment-on-diff)]
    ["Services"
     :if emacs-kit/conductor--core-context-p
     ("U" "Bring stack up" emacs-kit/digits-up)
     ("X" "Bring stack down" emacs-kit/digits-down)
     ("B" "Bootstrap emulators only" emacs-kit/digits-bootstrap)
     ("D" "Dashboard" emacs-kit/digits-dashboard)
     ("l" "Tail service log" emacs-kit/digits-tail-service)
     ("R" "Restart service" emacs-kit/digits-restart-service)
     ("K" "Stop service" emacs-kit/digits-stop-service)
     ("A" "Attach (vterm)" emacs-kit/digits-attach)])

  (global-set-key (kbd "C-c SPC") #'emacs-kit/conductor)

  (with-eval-after-load 'magit-diff
    (define-key magit-diff-mode-map (kbd "C-c C-r") #'emacs-kit/conductor-comment-on-diff))
  (with-eval-after-load 'magit
    (define-key magit-status-mode-map (kbd "C-c C-r") #'emacs-kit/conductor-comment-on-diff)))

(provide 'emacs-kit-conductor)
;;; emacs-kit-conductor.el ends here
