;;; emacs-kit-magit-comment.el --- Send magit diff hunks to agent-shell  -*- lexical-binding: t; -*-
;;
;; Author: Kyle Bolton
;; Package-Requires: ((emacs "30.1") (magit "3.3"))
;; Keywords: vc, tools, ai
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Standalone version of the diff-comment workflow that previously lived
;; in `emacs-kit-conductor'.  Works in any `magit-diff-mode' or
;; `magit-status-mode' buffer regardless of perspective / worktree setup.
;;
;; Usage:
;;   1. Place point on a diff hunk in a magit buffer (or select specific
;;      lines within the hunk for finer-grained feedback).
;;   2. M-x emacs-kit/magit-comment-on-diff   (or C-c C-r)
;;   3. Type your comment in the minibuffer.
;;   4. If there's a single live `agent-shell' session it is used; if
;;      multiple, you're prompted to pick one.
;;
;; The hunk text is wrapped in a fenced ```diff``` block, prefixed with
;; the file path, suffixed with your comment, and submitted to the chosen
;; agent-shell session for evaluation.

;;; Code:

(declare-function magit-current-section "magit-section")
(declare-function magit-file-at-point "magit-git")
(declare-function agent-shell-insert "agent-shell")

(defgroup emacs-kit-magit-comment nil
  "Send magit diff hunks to agent-shell sessions for review."
  :group 'tools
  :prefix "emacs-kit-magit-comment-")

(defun emacs-kit/magit-comment--section-text (section)
  "Return SECTION text without properties, or nil."
  (when section
    ;; `slot-value' avoids byte-compiler slot resolution issues here while
    ;; still reading Magit's `start' and `end' markers directly.
    (buffer-substring-no-properties
     (slot-value section 'start)
     (slot-value section 'end))))

(defun emacs-kit/magit-comment--agent-buffers ()
  "Return live `agent-shell' buffers, most-recently-used first."
  (seq-filter
   (lambda (b)
     (and (buffer-live-p b)
          (with-current-buffer b (derived-mode-p 'agent-shell-mode))
          (get-buffer-process b)))
   (buffer-list)))

(defun emacs-kit/magit-comment--pick-agent-buffer ()
  "Pick an `agent-shell' buffer to receive the comment.
Returns the only live session, or prompts when there are several.
Errors if none are running."
  (let ((buffers (emacs-kit/magit-comment--agent-buffers)))
    (cond
     ((null buffers)
      (user-error "No live agent-shell session found -- start one first"))
     ((null (cdr buffers))
      (car buffers))
     (t
      (let* ((names (mapcar #'buffer-name buffers))
             (chosen (completing-read "Send to agent: " names nil t)))
        (get-buffer chosen))))))

;;;###autoload
(defun emacs-kit/magit-comment-on-diff ()
  "Send the magit diff hunk at point, plus a comment, to an agent-shell.
If a region is active, the selected lines are highlighted in the
message and the full hunk is included as context.  When multiple
agent-shell sessions are running you'll be prompted to pick one."
  (interactive)
  (unless (derived-mode-p 'magit-diff-mode 'magit-status-mode)
    (user-error "Not in a magit diff or status buffer"))
  (require 'agent-shell)
  (let* ((section (magit-current-section))
         (hunk-text (emacs-kit/magit-comment--section-text section)))
    (unless hunk-text
      (user-error "No diff hunk at point"))
    (let* ((selection (when (use-region-p)
                        (buffer-substring-no-properties
                         (region-beginning) (region-end))))
           (file (or (magit-file-at-point) "unknown file"))
           (feedback (read-string "Comment: "))
           (shell-buffer (emacs-kit/magit-comment--pick-agent-buffer))
           (text (if selection
                     (format "In %s, regarding these specific lines:\n\n```diff\n%s\n```\n\nFull hunk for context:\n\n```diff\n%s\n```\n\n%s"
                             file selection hunk-text feedback)
                   (format "In %s, regarding this change:\n\n```diff\n%s\n```\n\n%s"
                           file hunk-text feedback))))
      (agent-shell-insert :shell-buffer shell-buffer
                          :text text
                          :submit t
                          :no-focus t)
      (message "[magit-comment] sent to %s" (buffer-name shell-buffer)))))

(with-eval-after-load 'magit-diff
  (define-key magit-diff-mode-map (kbd "C-c C-r") #'emacs-kit/magit-comment-on-diff))
(with-eval-after-load 'magit
  (when (boundp 'magit-status-mode-map)
    (define-key magit-status-mode-map (kbd "C-c C-r") #'emacs-kit/magit-comment-on-diff)))

(provide 'emacs-kit-magit-comment)
;;; emacs-kit-magit-comment.el ends here
