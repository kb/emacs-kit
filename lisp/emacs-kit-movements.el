;;; emacs-kit-movements.el --- Enhanced navigation and window movement commands  -*- lexical-binding: t; -*-
;;
;; Author: Rahul Martim Juliato
;; URL: https://github.com/LionyxML/emacs-kit
;; Package-Requires: ((emacs "30.1"))
;; Keywords: convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; Provides enhanced scrolling with auto-centering, window
;; transposing (horizontal <-> vertical split), and buffer
;; promotion from side windows.

;;; Code:

(use-package emacs-kit-movements
  :ensure nil
  :no-require t
  :defer t
  :init
  (defun emacs-kit/rename-buffer-and-move-to-new-window ()
    "Promotes a side window buffer to a new regular window."
    (interactive)
    (let ((temp-name (make-temp-name "temp-buffer-")))
      (rename-buffer temp-name t)
      (delete-window)
      (split-window-right)
      (switch-to-buffer temp-name)))

  ;; FIXME: this basically do the same as (tear-off-window) binded to C-x w ^ f
  ;;        consider removing it
  (global-set-key (kbd "C-x x x") 'emacs-kit/rename-buffer-and-move-to-new-window)


  (defun emacs-kit-movements/scroll-down-centralize ()
    (interactive)
    (scroll-up-command)
    (recenter))

  (defun emacs-kit-movements/scroll-up-centralize ()
    (interactive)
    (scroll-down-command)
    (unless (= (window-start) (point-min))
      (recenter))
    (when (= (window-start) (point-min))
      (let ((midpoint (/ (window-height) 2)))
        (goto-char (window-start))
        (forward-line midpoint)
        (recenter midpoint))))

  (global-set-key (kbd "C-v") #'emacs-kit-movements/scroll-down-centralize)
  (global-set-key (kbd "M-v") #'emacs-kit-movements/scroll-up-centralize)


  (defun emacs-kit/transpose-split ()
    "Transpose a horizontal split into a vertical split, or vice versa."
    (interactive)
    (if (> (length (window-list)) 2)
        (user-error "More than two windows present")
      (let* ((this-win (selected-window))
             (other-win (next-window))
             (this-buf (window-buffer this-win))
             (other-buf (window-buffer other-win))
             (this-edges (window-edges this-win))
             (other-edges (window-edges other-win))
             (this-left (car this-edges))
             (other-left (car other-edges))
             (split-horizontally (not (= this-left other-left))))
        (delete-other-windows)
        (if split-horizontally
            (split-window-vertically)
          (split-window-horizontally))
        (set-window-buffer (selected-window) this-buf)
        (set-window-buffer (next-window) other-buf)
        (select-window this-win))))

  ;; FIXME: remove this once EMACS-31 drops as stable
  ;;        C-x w t does the same and we also get C-x w t ...
  (global-set-key (kbd "C-x 4 t") #'emacs-kit/transpose-split))

(provide 'emacs-kit-movements)
;;; emacs-kit-movements.el ends here
