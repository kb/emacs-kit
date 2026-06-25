;;; emacs-kit-cook.el --- One-Emacs hub for cook dev pods  -*- lexical-binding: t; -*-
;;
;; Author: Kyle Bolton
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Drive cook dev pods from a single GUI Emacs.  Each pod becomes a
;; `tab-bar' workspace: remote files over TRAMP plus `ghostel' terminals
;; running on the pod (claude, dev stack).  Pods are reached through the
;; `cook-*' ssh hosts that cook writes to ~/.digits/cook/ssh/config, so
;; the pod list and TRAMP transport stay in sync with `cook' itself.

;;; Code:

(require 'tab-bar)
(require 'subr-x)
(require 'project)
(declare-function ghostel "ghostel" (&optional arg))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function persp-current-name "perspective" ())
(declare-function persp-switch "perspective" (name &optional norecord))
(declare-function persp-add-buffer "perspective" (buffer-or-name))
(declare-function tab-bar--current-tab-find "tab-bar" (&optional tabs frame))
(defvar ghostel-buffer-name)
(defvar ghostel-buffer-name-function)
(defvar ghostel-tramp-shells)
(defvar persp-initial-frame-name)
(defvar persp-mode)
(defvar tab-bar-tab-post-select-functions)
(defvar-local emacs-kit/claude-tui-buffer nil
  "Non-nil when this buffer is a Claude TUI target for Emacs Kit helpers.")

(use-package emacs-kit-cook
  :ensure nil
  :no-require t
  :init
  (defcustom emacs-kit/cook-remote-repo "/home/agent/digits/core"
    "Absolute path of the core checkout inside a cook pod."
    :type 'string :group 'emacs-kit)

  (defcustom emacs-kit/cook-ssh-config "~/.digits/cook/ssh/config"
    "cook-generated ssh config that lists the `cook-*' pod hosts."
    :type 'string :group 'emacs-kit)

  (defcustom emacs-kit/cook-repo-root "~/digits/core"
    "Local core checkout where the `cook' command should run.
The cook wrapper resolves the repo root from `default-directory', so run it
from the core checkout rather than from `user-emacs-directory'."
    :type 'directory :group 'emacs-kit)

  (defcustom emacs-kit/cook-command "cook"
    "Command used to run cook."
    :type 'string :group 'emacs-kit)

  (defcustom emacs-kit/cook-autostart-claude t
    "When non-nil, run `claude' in a new workspace's claude terminal."
    :type 'boolean :group 'emacs-kit)

  (defcustom emacs-kit/cook-autostart-stack nil
    "When non-nil, run `make core' in a new workspace's stack terminal.
Off by default: the stack boots emulators and is slow, so it's usually
started on demand rather than with every workspace."
    :type 'boolean :group 'emacs-kit)

  (defun emacs-kit/cook--hosts ()
    "Return the `cook-*' ssh host aliases from the cook ssh config.
The wildcard `cook-*' catch-all entry is excluded."
    (let ((file (expand-file-name emacs-kit/cook-ssh-config)))
      (when (file-readable-p file)
        (with-temp-buffer
          (insert-file-contents file)
          (let (hosts)
            (while (re-search-forward "^Host \\(cook-[[:alnum:]-]+\\)$" nil t)
              (push (match-string 1) hosts))
            (nreverse hosts))))))

  (defun emacs-kit/cook--label (host)
    "Return HOST with its `cook-' prefix stripped, for tab/buffer names."
    (string-remove-prefix "cook-" host))

  (defun emacs-kit/cook--remote-dir (host)
    "Return the TRAMP path to the core repo on cook pod HOST."
    ;; `sshx' forces TRAMP to run the remote shell through an SSH
    ;; RemoteCommand/TTY.  That has proven more reliable for cook pods than the
    ;; plain `ssh' method, whose non-tty bootstrap can trip over the pod's
    ;; login/session setup.  Existing successful cook TRAMP paths in this config
    ;; also use /sshx:cook-...:.
    (format "/sshx:%s:%s" host emacs-kit/cook-remote-repo))

  (defun emacs-kit/cook--remember-project (host)
    "Remember HOST's cook repo in `project-list-file', when detectable."
    (let ((dir (file-name-as-directory (emacs-kit/cook--remote-dir host))))
      (when-let* ((project (project-current nil dir)))
        (project-remember-project project))))

  (defun emacs-kit/cook--perspective-name (host)
    "Return the Perspective name to use for cook pod HOST."
    (emacs-kit/cook--label host))

  (defun emacs-kit/cook--default-perspective-name ()
    "Return the Perspective name to use for non-cook tabs."
    (if (boundp 'persp-initial-frame-name)
        persp-initial-frame-name
      "main"))

  (defun emacs-kit/cook--tag-current-tab (host)
    "Tag the current `tab-bar' tab as the workspace for cook pod HOST."
    (when-let* ((tab (and (fboundp 'tab-bar--current-tab-find)
                          (tab-bar--current-tab-find))))
      ;; `tab-bar' preserves unknown tab alist keys when saving/restoring tabs,
      ;; so this lets tab selection restore the matching Perspective later.
      (setf (alist-get 'emacs-kit-cook-host tab) host)
      (setf (alist-get 'emacs-kit-perspective tab)
            (emacs-kit/cook--perspective-name host))))

  (defun emacs-kit/cook--host-for-label (label)
    "Return the cook ssh host whose workspace label is LABEL, or nil."
    (seq-find (lambda (host)
                (equal (emacs-kit/cook--label host) label))
              (emacs-kit/cook--hosts)))

  (defun emacs-kit/cook--tab-perspective (tab)
    "Return the Perspective associated with TAB.
Tabs created before cook tabs were tagged can still be recognized by matching
their tab name to the active cook pod host list."
    (or (alist-get 'emacs-kit-perspective tab)
        (when-let* ((label (alist-get 'name tab))
                    (host (emacs-kit/cook--host-for-label label)))
          (setf (alist-get 'emacs-kit-cook-host tab) host)
          (setf (alist-get 'emacs-kit-perspective tab)
                (emacs-kit/cook--perspective-name host)))))

  (defun emacs-kit/cook--switch-perspective (host)
    "Switch to HOST's cook Perspective when `persp-mode' is active."
    (when (and (featurep 'perspective)
               (bound-and-true-p persp-mode))
      (persp-switch (emacs-kit/cook--perspective-name host))))

  (defun emacs-kit/cook--sync-perspective-to-tab (&rest _)
    "Switch Perspective to match the selected `tab-bar' tab.
Cook workspace tabs are tagged with their pod perspective.  Untagged tabs are
treated as ordinary/default Emacs tabs and return to the initial Perspective,
which keeps `C-x b' from showing buffers from the last visited cook workspace."
    (when (and (featurep 'perspective)
               (bound-and-true-p persp-mode)
               (fboundp 'tab-bar--current-tab-find))
      (let* ((tab (tab-bar--current-tab-find))
             (target (or (emacs-kit/cook--tab-perspective tab)
                         (emacs-kit/cook--default-perspective-name))))
        (when (and target
                   (not (equal target (persp-current-name))))
          (persp-switch target)))))

  (defun emacs-kit/cook--repo-root ()
    "Return the expanded cook repo root as a directory name."
    (file-name-as-directory (expand-file-name emacs-kit/cook-repo-root)))

  (defun emacs-kit/cook--current-branch ()
    "Return the current local Git branch in `emacs-kit/cook-repo-root', or nil."
    (let ((default-directory (emacs-kit/cook--repo-root)))
      (when (file-directory-p default-directory)
        (string-trim
         (shell-command-to-string
          "git rev-parse --abbrev-ref HEAD 2>/dev/null")))))

  (defun emacs-kit/cook--run (name args)
    "Run cook subcommand NAME with ARGS in a compilation buffer."
    (require 'compile)
    (let* ((default-directory (emacs-kit/cook--repo-root))
           (command (string-join
                     (cons (shell-quote-argument emacs-kit/cook-command)
                           (mapcar #'shell-quote-argument args))
                     " "))
           (buffer-name (format "*cook %s*" name)))
      (unless (file-directory-p default-directory)
        (user-error "Cook repo root does not exist: %s" default-directory))
      (compilation-start command nil (lambda (_) buffer-name))))

  (defun emacs-kit/cook--branches ()
    "Return active cook pod branches using `cook list --tsv'."
    (let* ((default-directory (emacs-kit/cook--repo-root))
           (output (and (file-directory-p default-directory)
                        (shell-command-to-string
                         (concat (shell-quote-argument emacs-kit/cook-command)
                                 " list --tsv 2>/dev/null")))))
      (when output
        (seq-filter
         (lambda (branch)
           (not (string-empty-p branch)))
         (mapcar
          (lambda (line)
            (let ((fields (split-string line "\t")))
              (or (cadr fields) "")))
          (split-string output "\n" t))))))

  (defun emacs-kit/cook--read-branch (&optional prompt default branches)
    "Read a cook branch with PROMPT, DEFAULT, and optional BRANCHES completion."
    (let* ((prompt (or prompt "Cook branch: "))
           (completion-extra-properties
            `(:annotation-function
              ,(lambda (s)
                 (and (member s branches) "  active pod"))))
           (value (completing-read
                   (if (and default (not (string-empty-p default)))
                       (format "%s(default %s) " prompt default)
                     prompt)
                   branches nil nil nil nil default)))
      (string-trim value)))

  (defun emacs-kit/cook-create (branch &optional no-wait)
    "Create a cook pod for BRANCH.
With prefix argument NO-WAIT, pass `--no-wait'."
    (interactive
     (list (emacs-kit/cook--read-branch
            "Create cook pod for branch: "
            (emacs-kit/cook--current-branch))
           current-prefix-arg))
    (when (string-empty-p branch)
      (user-error "Branch is required"))
    (emacs-kit/cook--run
     (format "create %s" branch)
     (append '("create") (and no-wait '("--no-wait")) (list branch))))

  (defun emacs-kit/cook-rm (branch)
    "Remove the cook pod for BRANCH.
The command runs `cook rm --force BRANCH' after Emacs confirmation."
    (interactive
     (let* ((branches (emacs-kit/cook--branches))
            (default (or (car branches) (emacs-kit/cook--current-branch))))
       (list (emacs-kit/cook--read-branch
              "Remove cook pod for branch: " default branches))))
    (when (string-empty-p branch)
      (user-error "Branch is required"))
    (unless (yes-or-no-p (format "Remove cook pod for %s? " branch))
      (user-error "Aborted"))
    (emacs-kit/cook--run
     (format "rm %s" branch)
     (list "rm" "--force" branch)))

  (defun emacs-kit/cook--read-host ()
    "Prompt for a cook pod host with completion."
    (let ((hosts (emacs-kit/cook--hosts)))
      (unless hosts
        (user-error "No cook pods found in %s" emacs-kit/cook-ssh-config))
      (completing-read "Cook pod: " hosts nil t)))

  (defun emacs-kit/cook--claude-command (host)
    "Return the Claude command to run for cook pod HOST.
Naming the session after the pod prevents Claude's terminal title and
prompt from making a new pod workspace look like it belongs to a previous
pod's conversation."
    (format "claude --name %s"
            (shell-quote-argument (emacs-kit/cook--label host))))

  (defun emacs-kit/cook--terminal (host title &optional command)
    "Open ghostel terminal TITLE on cook pod HOST; return its buffer.
A live buffer for the same HOST/TITLE is reused.  With COMMAND non-nil,
type it into the remote shell once the login shell has settled (the
shell is interactive+login per `ghostel-tramp-shells', so PATH resolves
pod tools like `claude')."
    (require 'ghostel)
    (let* ((default-directory (emacs-kit/cook--remote-dir host))
           ;; Ghostel doesn't ship an `sshx' entry in `ghostel-tramp-shells'.
           ;; Without one it falls back to TRAMP's /bin/sh, which skips the
           ;; cook dev-profile zsh setup and misses PATH entries like
           ;; /usr/local/cook-bin/claude.  Source cook's exported container env
           ;; first, then replace bash with the pod user's zsh as a login,
           ;; interactive shell so ~/.zshrc (oh-my-zsh, nvm, ~/.local/bin, etc.)
           ;; is loaded too.
           (ghostel-tramp-shells
            (cons '("sshx" "/bin/bash" nil "-lc"
                    ". /etc/profile.d/cook-env.sh 2>/dev/null || true; exec /usr/bin/zsh -l -i")
                  ghostel-tramp-shells))
           (ghostel-buffer-name
            (format "*%s:%s*" (emacs-kit/cook--label host) title))
           (buffer (ghostel)))
      ;; Ghostel normally renames buffers to whatever OSC title the TUI reports
      ;; (Claude uses its session name).  In cook workspaces that makes a new
      ;; pod's terminal look like the previous pod if Claude offers/resumes an
      ;; old conversation.  Keep the stable pod/title buffer name instead.
      (with-current-buffer buffer
        (setq-local ghostel-buffer-name-function nil)
        (setq-local emacs-kit/claude-tui-buffer (string= title "claude"))
        (rename-buffer ghostel-buffer-name t))
      (when command
        (run-at-time
         0.6 nil
         (lambda (buf cmd)
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (ghostel-send-string (concat cmd "\n")))))
         buffer command))
      buffer))

  (defun emacs-kit/cook--display-terminal (window host title &optional command)
    "Display cook terminal TITLE for HOST in WINDOW.
With COMMAND non-nil, send it after the login shell has settled."
    (with-selected-window window
      (let ((buffer (emacs-kit/cook--terminal host title command)))
        (set-window-buffer window buffer)
        buffer)))

  (defun emacs-kit/cook--tab-exists-p (name)
    "Return non-nil when a `tab-bar' tab named NAME exists on this frame."
    (seq-find (lambda (tab) (equal (alist-get 'name tab) name))
              (tab-bar-tabs)))

  (defun emacs-kit/cook-terminal (host)
    "Open a single ghostel shell on cook pod HOST in the core repo."
    (interactive (list (emacs-kit/cook--read-host)))
    (emacs-kit/cook--remember-project host)
    (emacs-kit/cook--switch-perspective host)
    (pop-to-buffer (emacs-kit/cook--terminal host "shell")))

  (defun emacs-kit/cook-workspace (host)
    "Open or switch to the `tab-bar' workspace for cook pod HOST.
Layout: remote dired on the left, claude over the dev stack on the right.
Re-running for an existing pod switches to its tab without disturbing the
running terminals."
    (interactive (list (emacs-kit/cook--read-host)))
    (let ((label (emacs-kit/cook--label host)))
      (emacs-kit/cook--remember-project host)
      (if (emacs-kit/cook--tab-exists-p label)
          (progn
            (tab-bar-switch-to-tab label)
            (emacs-kit/cook--tag-current-tab host)
            (emacs-kit/cook--switch-perspective host))
        (tab-bar-new-tab)
        (tab-bar-rename-tab label)
        (emacs-kit/cook--tag-current-tab host)
        (emacs-kit/cook--switch-perspective host)
        (delete-other-windows)
        (dired (emacs-kit/cook--remote-dir host))
        (let ((files (selected-window)))
          (let* ((right (split-window-right))
                 (stack (with-selected-window right
                          (split-window-below))))
            (emacs-kit/cook--display-terminal
             right host "claude" (and emacs-kit/cook-autostart-claude
                                       (emacs-kit/cook--claude-command host)))
            (emacs-kit/cook--display-terminal
             stack host "stack" (and emacs-kit/cook-autostart-stack "make core")))
          (select-window files)))))

  (add-hook 'tab-bar-tab-post-select-functions
            #'emacs-kit/cook--sync-perspective-to-tab)

  :bind (("C-c p c" . emacs-kit/cook-create)
         ("C-c p r" . emacs-kit/cook-rm)
         ("C-c p w" . emacs-kit/cook-workspace)
         ("C-c p t" . emacs-kit/cook-terminal)))

(provide 'emacs-kit-cook)
;;; emacs-kit-cook.el ends here
