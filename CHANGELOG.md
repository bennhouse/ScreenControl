# Changelog

## Unreleased

- New icon, redrawn with the rest of the suite from one shared design (same glass parts, light, shadows and safe area on every icon).
- The panel opens 2 pt under its status item, as macOS places its own menu bar windows (it was 5 pt).
- Closing the panel: a linear 0.22 s fade of the panel itself (twice the system's), with no white flash. The system faded a snapshot of the window, in which the translucent material showed up white.
- Keep Awake turns itself off after 24 hours at most, however it was turned on (⇧⌘L, "Indefinitely"), counted from when it was turned on; choosing another duration meanwhile doesn't reset it. The limit is checked again on wake. A small popover under the menu bar icon says so, fading in and out. The menu shows the latest end time.
- External displays whose monitor never answers a DDC brightness read (or reports brightness as unsupported) get a disabled slider, and nothing is written to them. "Reduce brightness" still works on them.
- Likely fix for the menu bar icon sometimes cut off after a resolution change (not reproduced): the item is as wide as its image (variable length; a square item measured 22.5 pt for a 22 pt icon in a test app) and is laid out again after display changes and on wake.
- The menu bar icon stays highlighted while the panel is open, as system menu bar items do (it only flashed, then flickered: clicks on the icon are now handled before the button tracks them, so nothing takes the highlight away).
- The "Keep Awake turned off" popover's arrow sits on the icon's centre (it was 1¼ pt to the left).
- The display in the menu bar icon no longer moves ½ pt left when the coffee cup appears.

## 1.4

- New icon: the suite's colour icons, ScreenControl in orange.
- **Keep Awake**: stops the Mac and its display from sleeping. Right-click the menu bar icon for **Turn On Keep Awake**, or **Turn On For…** 15 minutes to 8 hours or indefinitely. ⇧⌘L turns it on and off from anywhere.
- While Keep Awake is on, the menu bar icon shows a small coffee cup on its screen, and the menu shows until when.
- **Settings…** in the right-click menu: change the Keep Awake shortcut. Shortcuts are registered exclusively, so other apps using the same keys don't get them.
- After the right-click menu closed, the menu bar button kept waiting for the click to end, so shortcuts (⌃⌥⌘B too) and Quit did nothing until the next click. Fixed.

## 1.3

- The Night Shift button turns orange when on, as in Control Center, whatever the accent colour.
- The built-in display's slider stops at 1% instead of turning the screen off.
- **Black screen**, below the built-in display's slider: brightness to a true 0, backlight off, while the display stays on and part of the desktop. Any brightness change ends it. The slider glides to 0, then fades to grey; turning it off, it fades back in and glides up.
- While the built-in screen is black (Black screen or the brightness keys at 0), its slider is greyed out.
- Slider knobs: their dark edge fades out on the left as they reach the icon, so it never cuts across it.
- Sliders follow changes made elsewhere as they happen, gliding instead of jumping: the built-in display through macOS's brightness notifications (brightness keys, Touch Bar, Control Center, auto-brightness), the keyboard backlight ten times a second. True Tone follows too while the panel is open.

## 1.2

- The panel opens a little below the menu bar, like Control Center's panels.
- The status lines under Dark Mode, Night Shift and True Tone go on two lines, as in Control Center ("On until / tomorrow").

## 1.1

- The panel moves to the other screen when its own display is turned off, once the displays have settled.
- The panel no longer slides or fades when other displays change; it fades in only when its own screen changes resolution.
- Smaller slider knob, inside the slider's outline.
- New icon: the monitor in one piece, with the sun inside the screen.
- Installer (DMG) on the Releases page.

## 1.0

- First release: the macOS Display menu with external monitor brightness, Reduce brightness, display power and keyboard backlight.
