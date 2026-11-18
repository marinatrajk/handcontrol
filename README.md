# HandControl

Control your Mac with your hand through the built-in camera. It's a menu bar app that uses Apple's Vision hand tracking. There are no dependencies, and the video never leaves your Mac.

| Gesture | What it does |
| --- | --- |
| Move your hand (relaxed or pointing) | The pointer follows your knuckles |
| Pinch thumb and index | Click. Pinch twice quickly to double-click |
| Two fingers up (index, middle) | Scroll. Move your hand up or down from where you started; the further you go, the faster it scrolls. Come back to the start to stop. It follows your Mac's natural scrolling setting |
| Three fingers up (index, middle, ring) | Grab: the mouse button stays down while you move. Change shape to drop |
| Flat open hand (four fingers straight) | The pointer parks, so you can reposition your hand |
| Open hand, swipe down | Close the front window |
| ⌃⌥H | Turn hand control on or off |

Hold your hand inside the dashed box in the camera window. That box is mapped onto the whole screen.

## Build and run

You need only the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

```bash
open build/HandControl.app
```

On first launch, macOS asks for two permissions:

1. **Camera**: click Allow.
2. **Accessibility**, which lets the app move the pointer and close windows. Turn on HandControl under System Settings › Privacy & Security › Accessibility.

The app is signed ad hoc. After a rebuild, macOS may treat it as a new app. If the pointer stops moving, remove HandControl from the Accessibility list, add it back, and relaunch.

## Tuning

**Pointer Smoothness** in the menu bar menu trades wobble for lag:

| Setting | Wobble when still | Stops after a quick move |
| --- | --- | --- |
| Responsive | about 4.5 pt | instantly |
| Balanced (default) | about 1.4 pt | about 0.1 s |
| Steady | about 0.7 pt | about 0.5 s |

These figures come from synthetic hands with tracking jitter and drift. Real-camera numbers will differ.

All other thresholds live in `GestureConfig` in `Sources/GestureEngine.swift`, including the screen-mapped box, pinch distances, pointer smoothing and swipe speed. The camera window shows the live pinch gap and finger count to help you tune them.

```bash
./build.sh test
```

That runs the gesture engine against synthetic hands, so you can change the logic without waving at the camera.

## License

MIT
