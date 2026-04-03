;;; emacs-kit-ace-window.el --- Quick window switching with labels  -*- lexical-binding: t; -*-
;;
;; Author: Rahul Martim Juliato
;; URL: https://github.com/LionyxML/emacs-kit
;; Package-Requires: ((emacs "30.1"))
;; Keywords: convenience
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; Based on: https://www.reddit.com/r/emacs/comments/1h0zjvq/comment/m0uy3bo/?context=3

;;; Commentary:
;;
;; Provides a quick window-jump command that labels visible windows
;; with number keys, allowing fast switching.  Inspired by the
;; ace-window package.
;;
;; TODO: implement ace-swap like feature

;;; Code:

(use-package emacs-kit-ace-window
  :ensure nil
  :no-require t
  :defer t
  :init
  (defvar emacs-kit-ace-window/quick-window-overlays nil
    "List of overlays used to temporarily display window labels.")

  (defun emacs-kit-ace-window/quick-window-jump ()
    "Jump to a window by typing its assigned character label.
Windows are labeled starting from the top-left window and proceeding
top to bottom, then left to right."
    (interactive)
    (let* ((window-list (emacs-kit-ace-window/get-windows))
           (window-keys (seq-take '("1" "2" "3" "4" "5" "6" "7" "8")
                                  (length window-list)))
           (window-map (cl-pairlis window-keys window-list)))
      (emacs-kit-ace-window/add-window-key-overlays window-map)
      (let ((key (read-key (format "Select window [%s]: " (string-join window-keys ", ")))))
        (emacs-kit-ace-window/remove-window-key-overlays)
        (if-let* ((selected-window (cdr (assoc (char-to-string key) window-map))))
            (select-window selected-window)
          (message "No window assigned to key: %c" key)))))

  (defun emacs-kit-ace-window/get-windows ()
    "Return a list of windows in the current frame.
Ordered from top to bottom, left to right."
    (sort (window-list nil 'no-mini)
          (lambda (w1 w2)
            (let ((edges1 (window-edges w1))
                  (edges2 (window-edges w2)))
              (or (< (car edges1) (car edges2)) ; Compare top edges
                  (and (= (car edges1) (car edges2)) ; If equal, compare left edges
                       (< (cadr edges1) (cadr edges2))))))))

  (defun emacs-kit-ace-window/add-window-key-overlays (window-map)
    "From WINDOW-MAP, add temporary overlays to windows.
With their assigned key labels ."
    (setq emacs-kit-ace-window/quick-window-overlays nil)
    (dolist (entry window-map)
      (let* ((key (car entry))
             (window (cdr entry))
             (start (window-start window))
             (overlay (make-overlay start start (window-buffer window))))
        (overlay-put overlay 'after-string
                     (propertize (format " [%s] " key)
                                 'face '(:foreground "#c3e88d"
                                                     :weight bold
                                                     :height default)))
        (overlay-put overlay 'window window)
        (push overlay emacs-kit-ace-window/quick-window-overlays))))

  (defun emacs-kit-ace-window/remove-window-key-overlays ()
    "Remove all temporary overlays used to display key labels in windows."
    (mapc 'delete-overlay emacs-kit-ace-window/quick-window-overlays)
    (setq emacs-kit-ace-window/quick-window-overlays nil))

  (global-set-key (kbd "M-O") #'emacs-kit-ace-window/quick-window-jump))

(provide 'emacs-kit-ace-window)
;;; emacs-kit-ace-window.el ends here
