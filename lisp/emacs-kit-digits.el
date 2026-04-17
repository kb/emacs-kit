;;; emacs-kit-digits.el --- Digits dev stack launcher  -*- lexical-binding: t; byte-compile-warnings: (not free-vars unresolved); -*-
;;
;; Author: Kyle Bolton
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Launches the Digits dev stack (go-services + frontend) in named
;; vterm buffers, replacing the tmux-based web-tier.sh workflow.
;; Services are parsed from web-tier.sh so changes there are
;; automatically picked up.

;;; Code:

(declare-function vterm "vterm")
(declare-function vterm-send-string "vterm")
(declare-function vterm-send-return "vterm")
(defvar vterm-shell)
(defvar vterm-buffer-name)

(use-package emacs-kit-digits
  :ensure nil
  :no-require t
  :init

  (defvar emacs-kit/digits-repo-path
    (expand-file-name "~/digits/core")
    "Default root path of the Digits core repository.
Overridden by the current workspace's worktree directory when available.")

  (defvar emacs-kit/digits--services nil
    "Cached list of parsed services from web-tier.sh.
Each entry is (GROUP NAME PATH AUTO-START-P TOOL-P).")

  (declare-function emacs-kit/conductor--current-worktree-dir "emacs-kit-conductor")

  (defun emacs-kit/digits--repo-path ()
    "Return the repo path for the current context.
Uses the conductor workspace worktree if available, otherwise the default."
    (or (when (fboundp 'emacs-kit/conductor--current-worktree-dir)
          (emacs-kit/conductor--current-worktree-dir))
        emacs-kit/digits-repo-path))

  (defvar emacs-kit/digits--running nil
    "List of currently running service buffer names.")

  ;; --- Parsing web-tier.sh ---

  (defun emacs-kit/digits--parse-web-tier ()
    "Parse web-tier.sh and return a list of service definitions.
Each entry is (GROUP NAME PATH AUTO-START-P TOOL-P)."
    (let ((script (expand-file-name
                   "go-services/development/web-tier.sh"
                   emacs-kit/digits-repo-path))
          services)
      (when (file-readable-p script)
        (with-temp-buffer
          (insert-file-contents script)
          (goto-char (point-min))
          (while (re-search-forward
                  "^\\(run_service\\|run_tool\\)\\s-+\"\\([^\"]+\\)\"\\s-+\"\\([^\"]+\\)\"\\s-+\"\\([^\"]+\\)\"\\(.*\\)"
                  nil t)
            (let* ((type (match-string 1))
                   (group (match-string 2))
                   (name (match-string 3))
                   (path (match-string 4))
                   (rest (string-trim (match-string 5)))
                   (auto-start (or (string-match-p "Enter" rest)
                                   (string-match-p "\"sync\"" rest)))
                   (tool-p (string= type "run_tool")))
              (push (list group name path auto-start tool-p) services)))))
      (setq emacs-kit/digits--services (nreverse services))))

  ;; --- Frontend services (from core.sh) ---

  (defvar emacs-kit/digits--frontend-services
    '(("frontend" "vite" "frontend-webapp" "make run")
      ("frontend" "admin" "frontend-webapp" "make admin"))
    "Frontend services not defined in web-tier.sh.")

  ;; --- Service lifecycle ---

  (defun emacs-kit/digits--service-buf-name (name)
    "Return buffer name for service NAME."
    (format "*digits:%s*" name))

  (defun emacs-kit/digits--service-running-p (name)
    "Return non-nil if service NAME has a running process."
    (let ((buf (get-buffer (emacs-kit/digits--service-buf-name name))))
      (and buf (get-buffer-process buf))))

  (defun emacs-kit/digits--run-service-cmd (name path &optional tool-p repo-path)
    "Return the shell command to run service NAME at PATH.
If TOOL-P, use the tool runner pattern.
REPO-PATH is the root of the digits repo to use."
    (let* ((repo (or repo-path (emacs-kit/digits--repo-path)))
           (go-root (expand-file-name "go-services" repo)))
      (format "export GO_REPOS_FULLPATH='%s' SPANNER_LOCAL_EMULATOR=true PUBSUB_EMULATOR_HOST=127.0.0.1:9085 DIGITS_REPO_PATH='%s' && %s"
              go-root
              repo
              (if tool-p
                  (format "cd '%s/tools/%s' && %s/development/bin/run-service %s tools/%s"
                          go-root path go-root name path)
                (format "cd '%s/services/%s' && %s/development/bin/run-service %s %s"
                        go-root path go-root name path)))))

  (defun emacs-kit/digits-start-service (name path &optional auto-start tool-p)
    "Start service NAME from PATH in a vterm buffer.
If AUTO-START, send Enter to begin the service immediately."
    (require 'vterm)
    (let* ((repo (emacs-kit/digits--repo-path))
           (buf-name (emacs-kit/digits--service-buf-name name))
           (go-root (expand-file-name "go-services" repo))
           (default-directory (if tool-p
                                  (expand-file-name (concat "tools/" path) go-root)
                                (expand-file-name (concat "services/" path) go-root)))
           (existing (get-buffer buf-name)))
      (when (and existing (not (get-buffer-process existing)))
        (kill-buffer existing)
        (setq existing nil))
      (unless existing
        (let* ((cmd (emacs-kit/digits--run-service-cmd name path tool-p repo))
               (vterm-buffer-name buf-name))
          (vterm buf-name)
          (run-at-time 0.5 nil
                       (lambda (b c auto)
                         (when (buffer-live-p b)
                           (with-current-buffer b
                             (vterm-send-string c t)
                             (vterm-send-return)
                             (when auto
                               (run-at-time 0.5 nil
                                            (lambda (b2)
                                              (when (buffer-live-p b2)
                                                (with-current-buffer b2
                                                  (vterm-send-return))))
                                            b)))))
                       (get-buffer buf-name) cmd auto-start)
          (push buf-name emacs-kit/digits--running)))))

  (defun emacs-kit/digits-start-frontend-service (name subdir cmd)
    "Start frontend service NAME in SUBDIR with CMD."
    (require 'vterm)
    (let* ((buf-name (emacs-kit/digits--service-buf-name name))
           (default-directory (expand-file-name subdir (emacs-kit/digits--repo-path)))
           (existing (get-buffer buf-name)))
      (when (and existing (not (get-buffer-process existing)))
        (kill-buffer existing)
        (setq existing nil))
      (unless existing
        (let ((vterm-buffer-name buf-name))
          (vterm buf-name)
          (run-at-time 0.5 nil
                       (lambda (b c)
                         (when (buffer-live-p b)
                           (with-current-buffer b
                             (vterm-send-string c)
                             (vterm-send-return))))
                       (get-buffer buf-name) cmd)
          (push buf-name emacs-kit/digits--running)))))

  ;; --- Emulator bootstrap ---

  (defun emacs-kit/digits-bootstrap ()
    "Bootstrap emulators (Spanner, PubSub, Gotenberg) before starting services.
Runs `make run-with-emulator` prerequisites from go-services."
    (interactive)
    (require 'vterm)
    (let* ((repo (emacs-kit/digits--repo-path))
           (go-root (expand-file-name "go-services" repo))
           (buf-name "*digits:bootstrap*")
           (default-directory go-root)
           (existing (get-buffer buf-name)))
      (when (and existing (not (get-buffer-process existing)))
        (kill-buffer existing)
        (setq existing nil))
      (unless existing
        (let ((vterm-buffer-name buf-name))
          (vterm buf-name)
          (run-at-time 0.5 nil
                       (lambda (b)
                         (when (buffer-live-p b)
                           (with-current-buffer b
                             (vterm-send-string
                              "make bootstrap-spanner-emulator gotenberg pubsub-emulator bootstrap-pubsub-emulator"
                              t)
                             (vterm-send-return))))
                       (get-buffer buf-name))
          (pop-to-buffer buf-name)
          (message "Bootstrapping emulators...")))))

  (defun emacs-kit/digits-stop-emulators ()
    "Stop all emulators."
    (interactive)
    (let* ((repo (emacs-kit/digits--repo-path))
           (go-root (expand-file-name "go-services" repo))
           (default-directory go-root))
      (shell-command "make stop-emulators &")
      (message "Stopping emulators...")))

  (defun emacs-kit/digits-stop-everything ()
    "Stop all services and emulators."
    (interactive)
    (emacs-kit/digits-stop-all)
    (emacs-kit/digits-stop-emulators))

  ;; --- Batch operations ---

  (defun emacs-kit/digits-start-group (group)
    "Start all services in GROUP."
    (interactive
     (list (completing-read "Start group: "
                            (delete-dups
                             (mapcar #'car (or emacs-kit/digits--services
                                               (emacs-kit/digits--parse-web-tier))))
                            nil t)))
    (let ((services (seq-filter (lambda (s) (string= (car s) group))
                                (or emacs-kit/digits--services
                                    (emacs-kit/digits--parse-web-tier)))))
      (dolist (svc services)
        (let ((name (nth 1 svc))
              (path (nth 2 svc))
              (auto (nth 3 svc))
              (tool (nth 4 svc)))
          (emacs-kit/digits-start-service name path auto tool)))
      (message "Started %d services in group '%s'" (length services) group)))

  (defun emacs-kit/digits-start-all ()
    "Start all backend services from web-tier.sh and frontend."
    (interactive)
    (let ((services (or emacs-kit/digits--services
                        (emacs-kit/digits--parse-web-tier))))
      (dolist (svc services)
        (let ((name (nth 1 svc))
              (path (nth 2 svc))
              (auto (nth 3 svc))
              (tool (nth 4 svc)))
          (emacs-kit/digits-start-service name path auto tool)))
      ;; Frontend
      (dolist (fe emacs-kit/digits--frontend-services)
        (emacs-kit/digits-start-frontend-service (nth 1 fe) (nth 2 fe) (nth 3 fe)))
      (message "Started %d services + %d frontend"
               (length services) (length emacs-kit/digits--frontend-services))))

  (defun emacs-kit/digits-stop-all ()
    "Stop all running Digits service buffers."
    (interactive)
    (let ((count 0))
      (dolist (buf (buffer-list))
        (when (string-prefix-p "*digits:" (buffer-name buf))
          (when (get-buffer-process buf)
            (delete-process (get-buffer-process buf)))
          (kill-buffer buf)
          (cl-incf count)))
      (setq emacs-kit/digits--running nil)
      (message "Stopped %d services" count)))

  (defun emacs-kit/digits-stop-service (name)
    "Stop a single service by NAME."
    (interactive
     (list (completing-read "Stop service: "
                            (seq-filter
                             (lambda (n)
                               (emacs-kit/digits--service-running-p n))
                             (mapcar #'cadr (or emacs-kit/digits--services
                                                (emacs-kit/digits--parse-web-tier))))
                            nil t)))
    (let ((buf (get-buffer (emacs-kit/digits--service-buf-name name))))
      (when buf
        (when (get-buffer-process buf)
          (delete-process (get-buffer-process buf)))
        (kill-buffer buf)
        (message "Stopped %s" name))))

  (defun emacs-kit/digits-restart-service (name)
    "Restart a single service by NAME."
    (interactive
     (list (completing-read "Restart service: "
                            (mapcar #'cadr (or emacs-kit/digits--services
                                               (emacs-kit/digits--parse-web-tier)))
                            nil t)))
    (let ((svc (seq-find (lambda (s) (string= (nth 1 s) name))
                         emacs-kit/digits--services)))
      (when svc
        (emacs-kit/digits-stop-service name)
        (run-at-time 1 nil
                     (lambda ()
                       (emacs-kit/digits-start-service
                        (nth 1 svc) (nth 2 svc) (nth 3 svc) (nth 4 svc)))))))

  (defun emacs-kit/digits-switch-to-service ()
    "Switch to a running Digits service buffer."
    (interactive)
    (let ((bufs (seq-filter
                 (lambda (b) (string-prefix-p "*digits:" (buffer-name b)))
                 (buffer-list))))
      (if bufs
          (switch-to-buffer
           (completing-read "Service: "
                            (mapcar #'buffer-name bufs) nil t))
        (user-error "No running Digits services"))))

  (defun emacs-kit/digits-service-status ()
    "Show status of all services in the minibuffer."
    (interactive)
    (let* ((services (or emacs-kit/digits--services
                         (emacs-kit/digits--parse-web-tier)))
           (running (seq-filter (lambda (s) (emacs-kit/digits--service-running-p (nth 1 s)))
                                services))
           (total (length services)))
      (message "%d/%d services running" (length running) total))))

(provide 'emacs-kit-digits)
;;; emacs-kit-digits.el ends here
