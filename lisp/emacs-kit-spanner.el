;;; emacs-kit-spanner.el --- Cloud Spanner helpers for Emacs Kit  -*- lexical-binding: t; -*-
;;
;; Author: Kyle Bolton
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, sql, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Register a `sql.el' Cloud Spanner product backed by spanner-cli, plus
;; helpers for connecting to local and cook-pod Spanner emulators.

;;; Code:

;; `sql.el' is built-in.  Spanner isn't a known product, so register it
;; here.  Connects to whatever the emulator is bound to in the running
;; environment.  From host Emacs, `emacs-kit/sql-spanner-cook' discovers the
;; cook spotlight entry for a pod and points spanner-cli at the underlying
;; localhost SSH port-forward; from inside a pod, `emacs-kit/sql-spanner'
;; still defaults to localhost:9010.
(require 'seq)
(require 'subr-x)

(declare-function persp-add-buffer "perspective" (buffer-or-name))
(declare-function sql-add-product "sql")
(declare-function sql-del-product "sql")
(declare-function sql-interactive-mode "sql")
(declare-function sql-send-region "sql" (start end))
(defvar sql-mode-map)
(defvar sql-product-alist)

(defcustom emacs-kit-spanner-project   "local-dev"   "Spanner project for `emacs-kit/sql-spanner'." :type 'string :group 'emacs-kit)
(defcustom emacs-kit-spanner-instance  "local-test"  "Spanner instance for `emacs-kit/sql-spanner'." :type 'string :group 'emacs-kit)
(defcustom emacs-kit-spanner-database  "identity"  "Default Spanner database; `emacs-kit/sql-spanner' prompts with this preselected." :type 'string :group 'emacs-kit)
(defcustom emacs-kit-spanner-admin-endpoint "http://localhost:9020"
  "Spanner emulator admin REST API endpoint, used to list databases."
  :type 'string :group 'emacs-kit)
(defcustom emacs-kit-spanner-cook-command "cook"
  "Command used to query cook pod and spotlight state."
  :type 'string :group 'emacs-kit)
(defcustom emacs-kit-spanner-cook-repo-root "~/digits/core"
  "Local core checkout where cook should run."
  :type 'directory :group 'emacs-kit)
(defcustom emacs-kit-spanner-cook-spotlight-state-dir "~/.digits/cook/state/spotlight"
  "Directory where cook stores spotlight state."
  :type 'directory :group 'emacs-kit)
(defcustom emacs-kit-spanner-cook-spotlight-port-offset-stride 10000
  "Port stride used by cook spotlight slots."
  :type 'integer :group 'emacs-kit)
(defcustom emacs-kit-spanner-cook-spanner-port 9010
  "Pod-side Spanner emulator port exposed by cook spotlight."
  :type 'integer :group 'emacs-kit)
(defcustom emacs-kit-spanner-cook-auto-reset-spotlight t
  "When non-nil, offer to run `cook reset spotlight' if a pod has no spotlight."
  :type 'boolean :group 'emacs-kit)

(defvar sql-spanner-options nil
  "Command-line options passed to spanner-cli when starting `sql-spanner'.
Set per-call by `emacs-kit/sql-spanner' from the
`emacs-kit-spanner-{project,instance,database}' customizations.")

(use-package sql
  :ensure nil
  :defer t
  :config
  ;; `sql-add-product' intentionally errors on duplicates.  Make reloads via
  ;; `C-c R' idempotent by replacing our custom product definition.
  (when (assoc 'spanner sql-product-alist)
    (sql-del-product 'spanner))
  (sql-add-product 'spanner "Cloud Spanner"
                   :sqli-program "spanner-cli"
                   :sqli-options 'sql-spanner-options
                   :prompt-regexp "^spanner> "
                   :prompt-cont-regexp "^      -> "))

(defun emacs-kit/sql-spanner--list-databases ()
  "Return the list of database names from the running emulator.
Queries the admin REST API at `emacs-kit-spanner-admin-endpoint'.
Returns nil if the emulator is unreachable, in which case
`emacs-kit/sql-spanner' falls back to a plain prompt."
  (require 'json)
  (let ((url (format "%s/v1/projects/%s/instances/%s/databases"
                     emacs-kit-spanner-admin-endpoint
                     emacs-kit-spanner-project
                     emacs-kit-spanner-instance)))
    (with-temp-buffer
      (when (zerop (call-process "curl" nil t nil "-sS" "--max-time" "3" url))
        (goto-char (point-min))
        (let* ((data (ignore-errors (json-parse-buffer :object-type 'alist)))
               (dbs  (alist-get 'databases data)))
          (mapcar (lambda (d)
                    (file-name-nondirectory (alist-get 'name d)))
                  (and (vectorp dbs) (append dbs nil))))))))

(defun emacs-kit/sql-spanner--read-database (&optional prompt)
  "Read a Spanner database name with PROMPT.
Local emulator database completion is used when the admin API is reachable;
otherwise fall back to a plain prompt seeded by
`emacs-kit-spanner-database'."
  (let* ((dbs (emacs-kit/sql-spanner--list-databases))
         (default emacs-kit-spanner-database)
         (prompt (or prompt "Database")))
    (if dbs
        (completing-read (format "%s (default %s): " prompt default)
                         dbs nil t nil nil default)
      (read-string (format "%s (default %s): " prompt default)
                   nil nil default))))

(defun emacs-kit/sql-spanner--read-database-plain (&optional prompt)
  "Read a Spanner database name with PROMPT and no admin API lookup."
  (let ((prompt (or prompt "Database"))
        (default emacs-kit-spanner-database))
    (read-string (format "%s (default %s): " prompt default)
                 nil nil default)))

(defun emacs-kit/sql-spanner--cook-repo-root ()
  "Return `emacs-kit-spanner-cook-repo-root' as a directory name."
  (file-name-as-directory
   (expand-file-name emacs-kit-spanner-cook-repo-root)))

(defun emacs-kit/sql-spanner--cook-run (&rest args)
  "Run cook with ARGS in `emacs-kit-spanner-cook-repo-root'; return stdout."
  (let ((default-directory (emacs-kit/sql-spanner--cook-repo-root)))
    (unless (file-directory-p default-directory)
      (user-error "Cook repo root does not exist: %s" default-directory))
    (unless (executable-find emacs-kit-spanner-cook-command)
      (user-error "cook command not found on PATH: %s" emacs-kit-spanner-cook-command))
    (with-temp-buffer
      (let ((status (apply #'call-process
                           emacs-kit-spanner-cook-command nil t nil args))
            (output (string-trim (buffer-string))))
        (unless (eq status 0)
          (user-error "cook %s failed: %s"
                      (string-join args " ")
                      (if (string-empty-p output) status output)))
        output))))

(defun emacs-kit/sql-spanner--cook-list-json ()
  "Return `cook list --json' parsed as hash tables/lists."
  (require 'json)
  (let ((output (emacs-kit/sql-spanner--cook-run "list" "--json")))
    (json-parse-string output
                       :object-type 'hash-table
                       :array-type 'list
                       :null-object nil
                       :false-object nil)))

(defun emacs-kit/sql-spanner--spotlight-spanner-host (spotlight)
  "Return public HOST:PORT for SPOTLIGHT's spanner-emulator route."
  (when spotlight
    (or (catch 'found
          (dolist (port (gethash "ports" spotlight))
            (when (equal (gethash "name" port) "spanner-emulator")
              (let ((url (gethash "url" port)))
                (when (and url
                           (string-match
                            "\\`jdbc:cloudspanner://\\([^/]+\\)/" url))
                  (throw 'found (match-string 1 url)))))))
        (when-let* ((hostname (gethash "hostname" spotlight)))
          (format "%s:9010" hostname)))))

(defun emacs-kit/sql-spanner--cook-spotlight-entry (pod-name)
  "Return cook spotlight state entry for POD-NAME, if present."
  (let ((file (expand-file-name
               (format "%s.json" pod-name)
               emacs-kit-spanner-cook-spotlight-state-dir)))
    (when (file-readable-p file)
      (require 'json)
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer
         :object-type 'hash-table
         :array-type 'list
         :null-object nil
         :false-object nil)))))

(defun emacs-kit/sql-spanner--cook-direct-spanner-host (pod-name)
  "Return direct localhost HOST:PORT for POD-NAME's spotlight port-forward.
This bypasses the SNI/:authority proxy hostname and talks to the
underlying cook spotlight SSH port-forward.  That is friendlier to
non-browser clients like spanner-cli, whose resolver may not map
*.localhost hostnames to loopback."
  (when-let* ((entry (emacs-kit/sql-spanner--cook-spotlight-entry pod-name))
              (slot (gethash "slot" entry)))
    (format "127.0.0.1:%d"
            (+ emacs-kit-spanner-cook-spanner-port
               (* (1+ slot)
                  emacs-kit-spanner-cook-spotlight-port-offset-stride)))))

(defun emacs-kit/sql-spanner--cook-pods ()
  "Return cook pods as plists enriched with spotlight Spanner host data."
  (let* ((data (emacs-kit/sql-spanner--cook-list-json))
         (spotlight (gethash "spotlight" data)))
    (mapcar
     (lambda (pod)
       (let* ((name (gethash "name" pod))
              (sp (and spotlight name (gethash name spotlight)))
              (direct-host (and sp name
                                (emacs-kit/sql-spanner--cook-direct-spanner-host name)))
              (public-host (emacs-kit/sql-spanner--spotlight-spanner-host sp)))
         (list :name name
               :branch (gethash "branch" pod)
               :status (gethash "status" pod)
               :ssh-host (gethash "ssh_host" pod)
               :spotlight sp
               :spotlight-hostname (and sp (gethash "hostname" sp))
               :spanner-public-host public-host
               :spanner-direct-host direct-host
               :spanner-host (or direct-host public-host))))
     (gethash "pods" data))))

(defun emacs-kit/sql-spanner--pod-label (pod)
  "Return the user-facing label for cook POD."
  (or (plist-get pod :branch)
      (plist-get pod :name)
      "unknown"))

(defun emacs-kit/sql-spanner--current-tab-name ()
  "Return the current tab-bar tab name, if available."
  (when (and (bound-and-true-p tab-bar-mode)
             (fboundp 'tab-bar--current-tab))
    (alist-get 'name (tab-bar--current-tab))))

(defun emacs-kit/sql-spanner--default-cook-pod (pods)
  "Return a likely default cook pod from PODS for the current buffer/tab."
  (let ((remote-host (file-remote-p default-directory 'host))
        (tab-name (emacs-kit/sql-spanner--current-tab-name)))
    (or (and remote-host
             (seq-find (lambda (pod)
                         (equal (plist-get pod :ssh-host) remote-host))
                       pods))
        (and tab-name
             (seq-find (lambda (pod)
                         (let ((ssh-host (plist-get pod :ssh-host))
                               (spotlight-hostname (plist-get pod :spotlight-hostname)))
                           (or (equal (plist-get pod :branch) tab-name)
                               (and ssh-host
                                    (equal (string-remove-prefix "cook-" ssh-host)
                                           tab-name))
                               (and spotlight-hostname
                                    (equal (string-remove-suffix ".localhost" spotlight-hostname)
                                           tab-name)))))
                       pods))
        (seq-find (lambda (pod) (plist-get pod :spanner-host)) pods)
        (car pods))))

(defun emacs-kit/sql-spanner--read-cook-pod ()
  "Prompt for a cook pod using `cook list --json'."
  (let* ((pods (emacs-kit/sql-spanner--cook-pods))
         (default-pod (emacs-kit/sql-spanner--default-cook-pod pods))
         (default (and default-pod
                       (emacs-kit/sql-spanner--pod-label default-pod)))
         (candidates (mapcar (lambda (pod)
                               (cons (emacs-kit/sql-spanner--pod-label pod) pod))
                             pods))
         (completion-extra-properties
          `(:annotation-function
            ,(lambda (candidate)
               (when-let* ((pod (cdr (assoc candidate candidates))))
                 (format "  %s%s"
                         (or (plist-get pod :status) "")
                         (if (plist-get pod :spanner-host)
                             (format "  spotlight %s"
                                     (plist-get pod :spanner-host))
                           "  no spotlight")))))))
    (unless candidates
      (user-error "No cook pods found"))
    (cdr (assoc (completing-read
                 (if default
                     (format "Cook pod (default %s): " default)
                   "Cook pod: ")
                 candidates nil t nil nil default)
                candidates))))

(defun emacs-kit/sql-spanner--find-cook-pod (name pods)
  "Return cook pod NAME from PODS.
NAME may be a branch, pod name, ssh host, or spotlight hostname."
  (seq-find (lambda (pod)
              (member name (delq nil
                                 (list (plist-get pod :branch)
                                       (plist-get pod :name)
                                       (plist-get pod :ssh-host)
                                       (plist-get pod :spotlight-hostname)))))
            pods))

(defun emacs-kit/sql-spanner--ensure-cook-spanner-host (pod)
  "Return POD's spotlight Spanner HOST:PORT, optionally starting spotlight."
  (or (plist-get pod :spanner-host)
      (let ((branch (plist-get pod :branch)))
        (unless branch
          (user-error "Pod has no branch; cannot reset spotlight: %s"
                      (plist-get pod :name)))
        (unless (and emacs-kit-spanner-cook-auto-reset-spotlight
                     (yes-or-no-p
                      (format "%s has no active spotlight; run cook reset spotlight %s? "
                              (emacs-kit/sql-spanner--pod-label pod)
                              branch)))
          (user-error "No active spotlight for %s"
                      (emacs-kit/sql-spanner--pod-label pod)))
        (emacs-kit/sql-spanner--cook-run "reset" "spotlight" branch)
        (let* ((fresh-pods (emacs-kit/sql-spanner--cook-pods))
               (fresh (emacs-kit/sql-spanner--find-cook-pod
                       (plist-get pod :name) fresh-pods))
               (host (and fresh (plist-get fresh :spanner-host))))
          (or host
              (user-error "Spotlight restarted, but no spanner-emulator URL was found for %s"
                          branch))))))

(defun emacs-kit/sql-spanner--start (database emulator-host &optional context)
  "Start spanner-cli for DATABASE against EMULATOR-HOST.
Optional CONTEXT is included in the comint buffer name."
  (require 'sql)
  (require 'comint)
  (let* ((spanner-cli (or (executable-find "spanner-cli")
                         (user-error "spanner-cli not found on PATH; install with: go install github.com/cloudspannerecosystem/spanner-cli@latest")))
         (bare-name (if context
                        (format "spanner:%s [%s]" context database)
                      (format "spanner [%s]" database)))
         (process-environment
          (cons (concat "SPANNER_EMULATOR_HOST=" emulator-host)
                process-environment))
         (sql-spanner-options
          (list "-p" emacs-kit-spanner-project
                "-i" emacs-kit-spanner-instance
                "-d" database))
         (buf (apply #'make-comint bare-name spanner-cli nil sql-spanner-options)))
    (with-current-buffer buf
      (let ((sql-product 'spanner))
        (sql-interactive-mode))
      (when (and (featurep 'perspective)
                 (bound-and-true-p persp-mode))
        (persp-add-buffer (current-buffer))))
    (pop-to-buffer buf)))

;;;###autoload
(defun emacs-kit/sql-spanner (&optional database)
  "Start a `sql-spanner' REPL against the local Spanner emulator.
Prompts for DATABASE (with completion from the live emulator
list when reachable; default `emacs-kit-spanner-database').  Sets
SPANNER_EMULATOR_HOST and the spanner-cli -p/-i/-d flags, then
enters `sql-interactive-mode' for the spanner product."
  (interactive
   (list (emacs-kit/sql-spanner--read-database)))
  (emacs-kit/sql-spanner--start
   database
   (or (getenv "SPANNER_EMULATOR_HOST") "localhost:9010")))

;;;###autoload
(defun emacs-kit/sql-spanner-cook (&optional pod database)
  "Start a local spanner-cli REPL against a cook pod's spotlight emulator.
POD may be a cook pod plist, branch, pod name, ssh host, or spotlight
hostname.  DATABASE defaults to `emacs-kit-spanner-database'."
  (interactive
   (list (emacs-kit/sql-spanner--read-cook-pod) nil))
  (let* ((pods (and (stringp pod) (emacs-kit/sql-spanner--cook-pods)))
         (pod (cond
               ((listp pod) pod)
               ((stringp pod) (or (emacs-kit/sql-spanner--find-cook-pod pod pods)
                                  (user-error "No cook pod found for %s" pod)))
               ((null pod) (emacs-kit/sql-spanner--read-cook-pod))
               (t (user-error "Unsupported cook pod value: %S" pod))))
         (emulator-host (emacs-kit/sql-spanner--ensure-cook-spanner-host pod))
         (database (or database (emacs-kit/sql-spanner--read-database-plain)))
         (context (or (plist-get pod :branch)
                      (plist-get pod :spotlight-hostname)
                      (plist-get pod :name))))
    (emacs-kit/sql-spanner--start database emulator-host context)))

(global-set-key (kbd "C-c p s") #'emacs-kit/sql-spanner-cook)

(defun emacs-kit/sql-spanner--live-buffers ()
  "Return live spanner-cli comint buffers, most-recently-used first."
  (seq-filter
   (lambda (b)
     (and (buffer-live-p b)
          (string-prefix-p "*spanner" (buffer-name b))
          (get-buffer-process b)))
   (buffer-list)))

;;;###autoload
(defun emacs-kit/sql-spanner-send-region (start end)
  "Send region START..END to a running `emacs-kit/sql-spanner' session.
With a single live spanner session, sends to it.  With multiple,
prompts to pick one.  With none, errors -- start one first via
`emacs-kit/sql-spanner'."
  (interactive "r")
  (require 'sql)
  (let* ((buffers (emacs-kit/sql-spanner--live-buffers))
         (target (cond
                  ((null buffers)
                   (user-error "No live spanner session -- M-x emacs-kit/sql-spanner first"))
                  ((null (cdr buffers)) (car buffers))
                  (t (get-buffer
                      (completing-read "Send to: "
                                       (mapcar #'buffer-name buffers)
                                       nil t))))))
    (let ((sql-buffer target))
      (sql-send-region start end))))

(with-eval-after-load 'sql
  (define-key sql-mode-map (kbd "C-c C-s") #'emacs-kit/sql-spanner-send-region))

(provide 'emacs-kit-spanner)
;;; emacs-kit-spanner.el ends here
