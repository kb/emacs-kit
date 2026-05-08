;;; early-init.el --- Emacs Kit Configuration --- Early Init  -*- lexical-binding: t; -*-
;;
;; Author: Rahul Martim Juliato
;; URL: https://github.com/LionyxML/emacs-kit
;; Package-Requires: ((emacs "30.1"))
;; Keywords: config
;; SPDX-License-Identifier: GPL-3.0-or-later
;;

;;; Commentary:
;;  Early init configuration for Emacs Kit
;;

;;; Code:

;; Allow upgrading built-in packages (e.g. transient) from MELPA
(setq package-install-upgrade-built-in t)

;; Prefer newer source over stale byte-compiled Elisp.
(setq load-prefer-newer t)

(defcustom emacs-kit-avoid-flash-options
  '((enabled . t)
    (background . "#000000")
    (foreground . "#000000")
    (reset-background . "#000000")
    (reset-foreground . "#ffffff"))
  "Options to avoid flash of light on Emacs startup.
- `enabled': whether to apply the workaround.
- `background', `foreground': initial colors to paint the frame in
  before init finishes loading the theme.
- `reset-background', `reset-foreground': colors restored after init.

Defaults match built-in `modus-vivendi'.  If you switch themes,
update these to match the new theme's bg/fg or the GUI flash
prevention will paint the wrong color before the theme loads."
  :type '(alist :key-type symbol :value-type (choice (const nil) string))
  :group 'emacs-kit)


;;; -------------------- PERFORMANCE & HACKS
;; HACK: inscrease startup speed

;; Delay garbage collection while Emacs is booting
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; Schedule garbage collection sensible defaults for after booting
(add-hook 'after-init-hook
          (lambda ()
            (setq gc-cons-threshold (* 100 1024 1024)
                  gc-cons-percentage 0.1)))

;; Single VC backend inscreases booting speed
(setq vc-handled-backends '(Git))

;; Do not native compile if on battery power
(setopt native-comp-async-on-battery-power nil) ; EMACS-31

;; HACK: avoid being flashbanged.  Emacs paints the initial GUI frame with
;; its hardcoded white default before init.el finishes loading the theme.
;; Pre-seed `default-frame-alist' with the theme's bg/fg so the *creation*
;; of the initial frame uses dark colors directly -- there's no flash to
;; cover up because the frame is never white.
;;
;; Gate on `initial-window-system' (set BEFORE early-init runs) rather than
;; `display-graphic-p' (which needs a frame to exist and so returns nil at
;; early-init time).  Daemon and TTY launches have no flash to avoid.
(defun emacs-kit/avoid-initial-flash-of-light ()
  "Pre-paint the initial GUI frame using the colors in
`emacs-kit-avoid-flash-options'.  See variable docstring."
  (when (alist-get 'enabled emacs-kit-avoid-flash-options)
    (let ((bg (alist-get 'background emacs-kit-avoid-flash-options))
          (fg (alist-get 'foreground emacs-kit-avoid-flash-options)))
      (push `(background-color . ,bg) default-frame-alist)
      (push `(foreground-color . ,fg) default-frame-alist)
      (set-face-attribute 'default nil :background bg :foreground fg)
      (setq mode-line-format nil))))

(defun emacs-kit/reset-default-colors ()
  "Restore reset colors after init completes loading the real theme."
  (when (alist-get 'enabled emacs-kit-avoid-flash-options)
    (let ((bg (alist-get 'reset-background emacs-kit-avoid-flash-options))
          (fg (alist-get 'reset-foreground emacs-kit-avoid-flash-options)))
      (when bg (set-face-attribute 'default nil :background bg))
      (when fg (set-face-attribute 'default nil :foreground fg)))))

(when initial-window-system
  (emacs-kit/avoid-initial-flash-of-light)
  (add-hook 'after-init-hook #'emacs-kit/reset-default-colors))


;; Always start Emacs and new frames maximized
(add-to-list 'default-frame-alist '(fullscreen . maximized))


;; Better Window Management handling
(setq frame-resize-pixelwise t
      frame-inhibit-implied-resize t
      frame-title-format
      '(:eval
        (let ((project (project-current)))
          (if project
              (concat "Emacs - [p] " (project-name project))
              (concat "Emacs - " (buffer-name))))))

(when (eq system-type 'darwin)
  (setq ns-use-proxy-icon nil))

(setq inhibit-compacting-font-caches t)

;; Disables unused UI Elements
(if (fboundp 'menu-bar-mode) (menu-bar-mode -1))
(if (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
(if (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(if (fboundp 'tooltip-mode) (tooltip-mode -1))
(if (fboundp 'fringe-mode) (fringe-mode -1))


;; Avoid raising the *Messages* buffer if anything is still without
;; lexical bindings
(setq warning-minimum-level :error)
(setq warning-suppress-types '((lexical-binding)))


(provide 'early-init)
;;; early-init.el ends here
