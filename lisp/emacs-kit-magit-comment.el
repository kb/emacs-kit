;;; emacs-kit-magit-comment.el --- Send magit diff hunks to Claude TUIs  -*- lexical-binding: t; -*-
;;
;; Author: Kyle Bolton
;; Package-Requires: ((emacs "30.1") (magit "3.3"))
;; Keywords: vc, tools, ai
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Send a Magit diff hunk plus a reviewer comment to a Claude TUI running in
;; an Emacs `ghostel' buffer.  Works in any `magit-diff-mode' or
;; `magit-status-mode' buffer regardless of perspective / worktree setup.
;;
;; Usage:
;;   1. Place point on a diff hunk in a magit buffer (or select specific
;;      lines within the hunk for finer-grained feedback).
;;   2. M-x emacs-kit/magit-comment-on-diff   (or C-c C-r)
;;   3. Type your comment in the minibuffer.
;;   4. If there's a single live Claude TUI buffer it is used; if multiple,
;;      you're prompted to pick one.
;;
;; The hunk text is wrapped in a fenced ```diff``` block, prefixed with
;; the file path, suffixed with your comment, and submitted to the chosen
;; Claude TUI.

;;; Code:

(declare-function magit-current-section "magit-section")
(declare-function magit-file-at-point "magit-git")
(declare-function ghostel-paste-string "ghostel" (string))
(declare-function ghostel-send-key "ghostel" (key-name &optional mods))
(declare-function slot-value "eieio" (object slot))

(defvar ghostel--title)
(defvar magit-diff-mode-map)
(defvar magit-status-mode-map)
(defvar-local emacs-kit/claude-tui-buffer nil
  "Non-nil when this buffer is a Claude TUI target for Magit comments.")

(require 'seq)

(defgroup emacs-kit-magit-comment nil
  "Send magit diff hunks to Claude TUIs for review."
  :group 'tools
  :prefix "emacs-kit-magit-comment-")

(defcustom emacs-kit-magit-comment-claude-buffer-regexp "\\bclaude\\b"
  "Regexp used to identify Claude TUI `ghostel' buffers.
The cook workspace command names Claude buffers like
\"*pod-name:claude*\", which this default matches."
  :type 'regexp
  :group 'emacs-kit-magit-comment)

(defun emacs-kit/magit-comment--section-text (section)
  "Return SECTION text without properties, or nil."
  (when section
    ;; `slot-value' avoids byte-compiler slot resolution issues here while
    ;; still reading Magit's `start' and `end' markers directly.
    (buffer-substring-no-properties
     (slot-value section 'start)
     (slot-value section 'end))))

(defun emacs-kit/magit-comment--claude-buffer-p (buffer)
  "Return non-nil when BUFFER looks like a live Claude `ghostel' TUI."
  (and (buffer-live-p buffer)
       (get-buffer-process buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'ghostel-mode)
              (or (bound-and-true-p emacs-kit/claude-tui-buffer)
                  (string-match-p
                   emacs-kit-magit-comment-claude-buffer-regexp
                   (downcase
                    (mapconcat
                     #'identity
                     (delq nil
                           (list (buffer-name)
                                 (and (boundp 'ghostel--title)
                                      ghostel--title)))
                     " "))))))))

(defun emacs-kit/magit-comment--claude-buffers ()
  "Return live Claude `ghostel' buffers, most-recently-used first."
  (seq-filter
   #'emacs-kit/magit-comment--claude-buffer-p
   (buffer-list)))

(defun emacs-kit/magit-comment--pick-claude-buffer ()
  "Pick a Claude TUI buffer to receive the comment.
Returns the only live Claude TUI, or prompts when there are several.
Errors if none are running."
  (let ((buffers (emacs-kit/magit-comment--claude-buffers)))
    (cond
     ((null buffers)
      (user-error "No live Claude ghostel buffer found -- start Claude first"))
     ((null (cdr buffers))
      (car buffers))
     (t
      (let* ((names (mapcar #'buffer-name buffers))
             (chosen (completing-read "Send to Claude: " names nil t)))
        (get-buffer chosen))))))

(defun emacs-kit/magit-comment--send-to-claude (buffer text)
  "Paste TEXT into Claude TUI BUFFER and submit it."
  (require 'ghostel)
  (with-current-buffer buffer
    (unless (derived-mode-p 'ghostel-mode)
      (user-error "Target buffer is not a ghostel buffer"))
    (ghostel-paste-string text)
    (ghostel-send-key "return")))

;;;###autoload
(defun emacs-kit/magit-comment-on-diff ()
  "Send the magit diff hunk at point, plus a comment, to Claude.
If a region is active, the selected lines are highlighted in the
message and the full hunk is included as context.  When multiple
Claude TUIs are running you'll be prompted to pick one."
  (interactive)
  (unless (derived-mode-p 'magit-diff-mode 'magit-status-mode)
    (user-error "Not in a magit diff or status buffer"))
  (let* ((section (magit-current-section))
         (hunk-text (emacs-kit/magit-comment--section-text section)))
    (unless hunk-text
      (user-error "No diff hunk at point"))
    (let* ((selection (when (use-region-p)
                        (buffer-substring-no-properties
                         (region-beginning) (region-end))))
           (file (or (magit-file-at-point) "unknown file"))
           (feedback (read-string "Comment: "))
           (claude-buffer (emacs-kit/magit-comment--pick-claude-buffer))
           (text (if selection
                     (format "In %s, regarding these specific lines:\n\n```diff\n%s\n```\n\nFull hunk for context:\n\n```diff\n%s\n```\n\n%s"
                             file selection hunk-text feedback)
                   (format "In %s, regarding this change:\n\n```diff\n%s\n```\n\n%s"
                           file hunk-text feedback))))
      (emacs-kit/magit-comment--send-to-claude claude-buffer text)
      (message "[magit-comment] sent to %s" (buffer-name claude-buffer)))))

(with-eval-after-load 'magit-diff
  (define-key magit-diff-mode-map (kbd "C-c C-r") #'emacs-kit/magit-comment-on-diff))
(with-eval-after-load 'magit
  (when (boundp 'magit-status-mode-map)
    (define-key magit-status-mode-map (kbd "C-c C-r") #'emacs-kit/magit-comment-on-diff)))

(provide 'emacs-kit-magit-comment)
;;; emacs-kit-magit-comment.el ends here
