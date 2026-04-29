;;; emacs-kit-digits.el --- Digits dev stack control panel  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Author: Kyle Bolton
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Control panel for the Digits dev stack.  The stack itself runs in a
;; detached tmux session created by go-services/development/web-tier.sh
;; (via `make run-with-emulator').  This package only orchestrates that
;; session through the tmux CLI and surfaces logs in regular Emacs
;; buffers via `auto-revert-tail-mode'.

;;; Code:

(declare-function vterm "vterm")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(defvar vterm-buffer-name)

(defvar compilation-scroll-output)
(defvar compilation-buffer-name-function)

(declare-function emacs-kit/conductor--current-worktree-dir "emacs-kit-conductor")

(use-package emacs-kit-digits
  :ensure nil
  :no-require t
  :init

  (defvar emacs-kit/digits-repo-path
    (expand-file-name "~/digits/core")
    "Default root path of the Digits core repository.
Overridden by the current workspace's worktree directory when available.")

  (defvar emacs-kit/digits-tmux-socket "digits"
    "tmux socket name used by web-tier.sh's `dmux' helper.")

  (defvar emacs-kit/digits-log-dir
    (expand-file-name "~/.cache/digits/logs")
    "Directory for per-service captured log files.")

  (defun emacs-kit/digits--repo-path ()
    "Return the repo path for the current context.
Uses the conductor workspace worktree if available, otherwise the default."
    (or (when (fboundp 'emacs-kit/conductor--current-worktree-dir)
          (emacs-kit/conductor--current-worktree-dir))
        emacs-kit/digits-repo-path))

  (defun emacs-kit/digits--session-suffix ()
    "Return a stable tmux/log suffix for the current repo or worktree."
    (let* ((repo (directory-file-name (expand-file-name (emacs-kit/digits--repo-path))))
           (base (file-name-as-directory (expand-file-name "~/.worktrees/")))
           (label (if (string-prefix-p base (file-name-as-directory repo))
                      (string-remove-prefix base (file-name-as-directory repo))
                    (file-name-nondirectory repo))))
      (replace-regexp-in-string "[^[:alnum:]]+" "-"
                                (string-trim label "-+" "-+"))))

  (defun emacs-kit/digits--session ()
    "Return the per-workspace tmux session name."
    (format "digits-%s" (emacs-kit/digits--session-suffix)))

  ;; --- tmux primitives ---

  (defun emacs-kit/digits--tmux (&rest args)
    "Run `tmux -L SOCKET ARGS', return trimmed stdout on success or nil."
    (with-temp-buffer
      (let ((exit (apply #'call-process "tmux" nil t nil
                         "-L" emacs-kit/digits-tmux-socket args)))
        (when (zerop exit)
          (string-trim (buffer-string))))))

  (defun emacs-kit/digits--session-up-p ()
    "Return non-nil if the current workspace's tmux session exists."
    (eq 0 (call-process "tmux" nil nil nil
                        "-L" emacs-kit/digits-tmux-socket
                        "has-session" "-t" (emacs-kit/digits--session))))

  (defun emacs-kit/digits--window-exists-p (window)
    "Return non-nil if WINDOW exists in the current session."
    (and (emacs-kit/digits--session-up-p)
         (string-match-p
          (format "^%s$" (regexp-quote window))
          (or (emacs-kit/digits--tmux
               "list-windows" "-t" (emacs-kit/digits--session)
               "-F" "#{window_name}")
              ""))))

  (defun emacs-kit/digits--panes ()
    "Return list of (WINDOW TITLE PANE-ID PID DEAD-P) for every pane in the session."
    (when (emacs-kit/digits--session-up-p)
      (let ((out (emacs-kit/digits--tmux
                  "list-panes" "-s" "-t" (emacs-kit/digits--session)
                  "-F" "#{window_name}\t#{pane_title}\t#{pane_id}\t#{pane_pid}\t#{pane_dead}")))
        (when (and out (not (string-empty-p out)))
          (mapcar (lambda (line)
                    (let ((p (split-string line "\t")))
                      (list (nth 0 p) (nth 1 p) (nth 2 p) (nth 3 p)
                            (string= (nth 4 p) "1"))))
                  (split-string out "\n" t))))))

  (defun emacs-kit/digits--read-service ()
    "Prompt for a service (pane title) from the running session."
    (let* ((panes (emacs-kit/digits--panes))
           (titles (mapcar #'cadr panes)))
      (unless titles
        (user-error "No Digits services running.  Run `emacs-kit/digits-up' first"))
      (let ((title (completing-read "Service: " titles nil t)))
        (seq-find (lambda (p) (string= (cadr p) title)) panes))))

  ;; --- Stack lifecycle ---

  (defun emacs-kit/digits--add-window (window pane-title subdir cmd)
    "Create tmux WINDOW with a single pane titled PANE-TITLE running CMD in SUBDIR."
    (let* ((repo (emacs-kit/digits--repo-path))
           (dir (expand-file-name subdir repo))
           (session (emacs-kit/digits--session))
           (target (format "%s:%s" session window)))
      (emacs-kit/digits--tmux "new-window" "-t" session "-n" window "-c" dir)
      (emacs-kit/digits--tmux "select-pane" "-t" target "-T" pane-title)
      (emacs-kit/digits--tmux "send-keys" "-t" target
                              (emacs-kit/digits--tmux-command cmd) "Enter")))

  (defun emacs-kit/digits--split-pane (window pane-title subdir cmd)
    "Split tmux WINDOW; new pane PANE-TITLE runs CMD in SUBDIR."
    (let* ((repo (emacs-kit/digits--repo-path))
           (dir (expand-file-name subdir repo))
           (session (emacs-kit/digits--session))
           (target (format "%s:%s" session window)))
      (emacs-kit/digits--tmux "split-window" "-t" target "-c" dir)
      (emacs-kit/digits--tmux "select-pane" "-t" target "-T" pane-title)
      (emacs-kit/digits--tmux "send-keys" "-t" target
                              (emacs-kit/digits--tmux-command cmd) "Enter")))

  (defun emacs-kit/digits--zsh-env (var)
    "Return value of VAR from user's interactive zsh, or nil if unset/empty."
    (let ((val (with-temp-buffer
                 (call-process "zsh" nil t nil "-ic"
                               (format "printf %%s \"${%s:-}\"" var))
                 (string-trim (buffer-string)))))
      (unless (string-empty-p val) val)))

  (defun emacs-kit/digits--tmux-command (cmd)
    "Wrap CMD so tmux panes run it through interactive zsh.
This matches the environment used by `emacs-kit/digits-up' and
leaves an interactive shell behind when CMD exits or is interrupted."
    (format "zsh -ic %s; exec zsh -il"
            (shell-quote-argument cmd)))

  (defun emacs-kit/digits--frontend-vite-path ()
    "Return the expected local Vite binary path for the frontend worktree."
    (expand-file-name "frontend-webapp/node_modules/.bin/vite"
                      (emacs-kit/digits--repo-path)))

  (defun emacs-kit/digits--ensure-frontend-ready ()
    "Abort if the frontend worktree is missing its local Vite install."
    (unless (file-executable-p (emacs-kit/digits--frontend-vite-path))
      (let ((frontend-dir (expand-file-name "frontend-webapp"
                                            (emacs-kit/digits--repo-path))))
        (user-error
         (concat "frontend-webapp is not bootstrapped in this worktree. "
                 "Run `cd %s && make clean setup`")
         (abbreviate-file-name frontend-dir)))))

  (defun emacs-kit/digits--start-frontend ()
    "Mirror core.sh: add `frontend' window (vite + admin split) and, when
MAKE_AIB is set in the user's zsh, a `view-gen' window."
    (emacs-kit/digits--ensure-frontend-ready)
    (unless (emacs-kit/digits--window-exists-p "frontend")
      (emacs-kit/digits--add-window "frontend" "vite" "frontend-webapp" "make run")
      (emacs-kit/digits--split-pane "frontend" "admin" "frontend-webapp" "make admin"))
    (when (and (emacs-kit/digits--zsh-env "MAKE_AIB")
               (not (emacs-kit/digits--window-exists-p "view-gen")))
      (emacs-kit/digits--add-window "view-gen" "view-gen"
                                    "data-ingestion" "make dev-ai-bookkeeper")))

  (defun emacs-kit/digits--up-finish (buffer msg)
    "Hook for `compilation-finish-functions': add frontend/AIB on success."
    (when (and (string-prefix-p "*digits-up:" (buffer-name buffer))
               (string-prefix-p "finished" msg)
               (emacs-kit/digits--session-up-p))
      (emacs-kit/digits--start-frontend)
      (message "Digits stack up: backend + frontend%s"
               (if (emacs-kit/digits--zsh-env "MAKE_AIB") " + AIB" ""))))

  (defun emacs-kit/digits-up ()
    "Bring up the Digits stack via `make run-with-emulator'.
The make target bootstraps Spanner/PubSub emulators, then web-tier.sh
spawns a detached tmux session named after the workspace.  On success,
this adds the same windows `core.sh' would: a `frontend' window with
vite + admin split panes, and a `view-gen' window when MAKE_AIB is set.
Idempotent when the session already exists."
    (interactive)
    (if (emacs-kit/digits--session-up-p)
        (message "Digits session already running: %s" (emacs-kit/digits--session))
      (make-directory emacs-kit/digits-log-dir t)
      (let* ((repo (emacs-kit/digits--repo-path))
             (go-root (expand-file-name "go-services" repo))
             (session (emacs-kit/digits--session))
             (default-directory go-root)
             (compilation-buffer-name-function
              (lambda (_mode) (format "*digits-up:%s*" session)))
             (compilation-scroll-output t)
             (process-environment
              (append (list (format "SESSION=%s" session)
                            (format "DIGITS_REPO_PATH=%s" repo)
                            ;; Trick web-tier.sh into the "not attaching" branch.
                            "TMUX=skip"
                            ;; Dev scripts use `tput' for colors; set -e exits
                            ;; non-zero without TERM.
                            "TERM=xterm-256color")
                      process-environment))
             ;; zsh -ic so the user's interactive shell config (oh-my-zsh,
             ;; config.zsh, secrets) is sourced before make runs.  Picks up
             ;; MAKE_AIB, SEED_STRIPE, STRIPE_API_KEY, etc.
             (buf (compile "zsh -ic 'make run-with-emulator'")))
        (with-current-buffer buf
          (add-hook 'compilation-finish-functions
                    #'emacs-kit/digits--up-finish nil t))
        (message "Bringing up Digits stack (session %s)..." session))))

  (defun emacs-kit/digits-down ()
    "Stop the Digits stack via `make stop-core'.
Stops vault, pubsub/spanner emulators, gotenberg, and the tmux session."
    (interactive)
    (let ((session (emacs-kit/digits--session)))
      (when (yes-or-no-p (format "Stop digits session '%s' (vault, emulators, tmux)? " session))
        (let* ((repo (emacs-kit/digits--repo-path))
               (default-directory repo)
               (compilation-buffer-name-function
                (lambda (_mode) (format "*digits-down:%s*" session)))
               (compilation-scroll-output t)
               (process-environment
                (append (list (format "CORE_SESSION=%s" session)
                              (format "DIGITS_REPO_PATH=%s" repo)
                              "TERM=xterm-256color")
                        process-environment)))
          (compile "zsh -ic 'make stop-core'")
          (message "Stopping Digits stack (session %s)..." session)))))

  (defun emacs-kit/digits-bootstrap ()
    "Bootstrap emulators only (no services).
Useful when you want to keep the stack down but have Spanner/PubSub up."
    (interactive)
    (let* ((repo (emacs-kit/digits--repo-path))
           (go-root (expand-file-name "go-services" repo))
           (default-directory go-root)
           (compilation-buffer-name-function
            (lambda (_mode) "*digits:bootstrap*"))
           (compilation-scroll-output t)
           (process-environment
            (cons "TERM=xterm-256color" process-environment)))
      (compile "zsh -ic 'make bootstrap-spanner-emulator gotenberg pubsub-emulator bootstrap-pubsub-emulator'")))

  ;; --- Per-service control ---

  (defun emacs-kit/digits-restart-service (service)
    "Restart SERVICE by sending C-c to its tmux pane.
Reflex re-launches the inner Go process; the pane stays alive."
    (interactive (list (emacs-kit/digits--read-service)))
    (emacs-kit/digits--tmux "send-keys" "-t" (nth 2 service) "C-c")
    (message "Restarted %s" (cadr service)))

  (defun emacs-kit/digits-stop-service (service)
    "Stop SERVICE by killing its tmux pane."
    (interactive (list (emacs-kit/digits--read-service)))
    (emacs-kit/digits--tmux "kill-pane" "-t" (nth 2 service))
    (message "Killed pane for %s" (cadr service)))

  ;; --- Log tailing ---

  (defun emacs-kit/digits--log-file (title)
    "Return the on-disk log path for service TITLE."
    (expand-file-name (format "%s.log" title)
                      (expand-file-name (emacs-kit/digits--session-suffix)
                                        emacs-kit/digits-log-dir)))

  (defun emacs-kit/digits-tail-service (service)
    "Tail SERVICE logs in a regular Emacs buffer.
Snapshots existing scrollback into a file, then pipes future output
to the same file with `pipe-pane'.  The buffer uses
`auto-revert-tail-mode' so you read it like any text file."
    (interactive (list (emacs-kit/digits--read-service)))
    (let* ((title (cadr service))
           (pane-id (nth 2 service))
           (log (emacs-kit/digits--log-file title)))
      (make-directory (file-name-directory log) t)
      (with-temp-file log
        (call-process "tmux" nil t nil
                      "-L" emacs-kit/digits-tmux-socket
                      "capture-pane" "-p" "-J" "-S" "-10000"
                      "-t" pane-id))
      ;; Toggle pipe-pane off then on so we don't stack pipes on repeat tails.
      (emacs-kit/digits--tmux "pipe-pane" "-t" pane-id)
      (emacs-kit/digits--tmux "pipe-pane" "-O" "-t" pane-id
                              (format "cat >> %s" (shell-quote-argument log)))
      (let ((buf (find-file-noselect log)))
        (with-current-buffer buf
          (read-only-mode 1)
          (auto-revert-tail-mode 1)
          (goto-char (point-max)))
        (pop-to-buffer buf))))

  ;; --- Attach (rare interactive case) ---

  (defun emacs-kit/digits-attach (&optional service)
    "Attach a vterm to the digits tmux session.
With prefix arg or non-nil SERVICE, jump to that service's window."
    (interactive
     (list (when current-prefix-arg (emacs-kit/digits--read-service))))
    (require 'vterm)
    (let* ((session (emacs-kit/digits--session))
           (cmd (if service
                    (format "tmux -L %s attach -t %s \\; select-window -t %s"
                            emacs-kit/digits-tmux-socket
                            session
                            (shell-quote-argument
                             (format "%s:%s" session (car service))))
                  (format "tmux -L %s attach -t %s"
                          emacs-kit/digits-tmux-socket session)))
           (vterm-buffer-name (format "*digits-tmux:%s*" session)))
      (vterm vterm-buffer-name)
      (run-at-time 0.3 nil
                   (lambda (b c)
                     (when (buffer-live-p b)
                       (with-current-buffer b
                         (vterm-send-string c)
                         (vterm-send-return))))
                   (get-buffer vterm-buffer-name) cmd)))

  ;; --- Dashboard ---

  (defvar emacs-kit/digits-dashboard-mode-map
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "g") #'emacs-kit/digits-dashboard)
      (define-key map (kbd "RET") #'emacs-kit/digits-dashboard-tail)
      (define-key map (kbd "r") #'emacs-kit/digits-dashboard-restart)
      (define-key map (kbd "k") #'emacs-kit/digits-dashboard-stop)
      (define-key map (kbd "a") #'emacs-kit/digits-dashboard-attach)
      map))

  (define-derived-mode emacs-kit/digits-dashboard-mode tabulated-list-mode
    "Digits"
    "Dashboard for the Digits dev stack."
    (setq tabulated-list-format [("Window" 18 t)
                                 ("Service" 28 t)
                                 ("PID" 8 t)
                                 ("Status" 8 t)])
    (setq tabulated-list-sort-key '("Window"))
    (tabulated-list-init-header))

  (defun emacs-kit/digits--dashboard-entries ()
    (mapcar (lambda (pane)
              (let ((win (nth 0 pane)) (title (nth 1 pane))
                    (pane-id (nth 2 pane)) (pid (nth 3 pane))
                    (dead (nth 4 pane)))
                (list pane-id (vector win title pid (if dead "dead" "live")))))
            (emacs-kit/digits--panes)))

  (defun emacs-kit/digits--pane-by-id (pane-id)
    (seq-find (lambda (p) (string= (nth 2 p) pane-id))
              (emacs-kit/digits--panes)))

  (defun emacs-kit/digits-dashboard ()
    "Show the Digits dashboard for the current workspace."
    (interactive)
    (unless (emacs-kit/digits--session-up-p)
      (user-error "Digits session not running.  Use `emacs-kit/digits-up'"))
    (let ((buf (get-buffer-create
                (format "*Digits:%s*" (emacs-kit/digits--session)))))
      (with-current-buffer buf
        (emacs-kit/digits-dashboard-mode)
        (setq tabulated-list-entries (emacs-kit/digits--dashboard-entries))
        (tabulated-list-print t))
      (pop-to-buffer buf)))

  (defun emacs-kit/digits-dashboard--at-point ()
    (let ((id (tabulated-list-get-id)))
      (unless id (user-error "No service at point"))
      (or (emacs-kit/digits--pane-by-id id)
          (user-error "Pane no longer exists; press `g' to refresh"))))

  (defun emacs-kit/digits-dashboard-tail ()
    (interactive)
    (emacs-kit/digits-tail-service (emacs-kit/digits-dashboard--at-point)))

  (defun emacs-kit/digits-dashboard-restart ()
    (interactive)
    (emacs-kit/digits-restart-service (emacs-kit/digits-dashboard--at-point)))

  (defun emacs-kit/digits-dashboard-stop ()
    (interactive)
    (emacs-kit/digits-stop-service (emacs-kit/digits-dashboard--at-point)))

  (defun emacs-kit/digits-dashboard-attach ()
    (interactive)
    (emacs-kit/digits-attach (emacs-kit/digits-dashboard--at-point))))

(provide 'emacs-kit-digits)
;;; emacs-kit-digits.el ends here
