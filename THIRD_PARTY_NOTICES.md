# Third-party notices

## KeyboardShortcuts 3.1.0

Source: https://github.com/sindresorhus/KeyboardShortcuts/tree/3.1.0
Pinned source commit: 772133d9dbe800fdac0473226822994c5c162c58

MIT License

Copyright (c) Sindre Sorhus <sindresorhus@gmail.com> (https://sindresorhus.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.


# Visual platform sources

The menu-bar compatibility bridge is adapted from the architecture and Objective-C
runtime calls in [Hidden Bar](https://github.com/dwarvesf/hidden), especially
`hidden/Features/StatusBar/Engine/Native/HBNativeVisibilityShim.m` and
`NativeVisibilityEngine.swift`, accessed 2026-10-25. The bridge checks runtime
method signatures before invoking the private API. The legacy implementation
uses the same bounded status-item geometry technique described in Hidden Bar's
architecture documentation. This project does not include Ice source code.

Hidden Bar license notice:

MIT License

Copyright (c) 2019 Dwarves Foundation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
IN THE SOFTWARE.

## Compatibility limits

- macOS 27 hides menu extras per owner bundle, not per individual icon. Apple
  system menu extras are kept visible by the native visibility assertion.
- Legacy menu extras use Command-drag geometry, and cannot reveal icons that
  exceed the available menu-bar width or lie under a camera notch.
- Desktop icons and widgets are hidden by a stationary wallpaper cover above
  desktop content, with no Finder preference mutation. Backdrops are regular
  windows ordered directly below the foreground app window; windowless apps
  cannot be isolated.
- No screen content is captured. The wallpaper variant reads the current
  wallpaper image file reported by NSWorkspace.


## Apple platform interfaces

System Events, Standard Additions, CoreAudio, IOBluetooth, IOPM, AppKit and CoreGraphics are Apple platform frameworks. Private CoreBrightness and MenuBarClientCore interfaces are runtime checked and can become unavailable after an OS update. No Ice/GPL source code is included.
