import Foundation

extension GestureProfileSet {
    /// The dongle's built-in profiles (firmware/bandit-profiles/profiles/default.json, which the tests
    /// compare this with): what it does with no file of yours, and what `profiles reset` restores.
    public static let builtinJSON = #"""
{
  "format": "bandit-profiles",
  "version": 1,
  "name": "Built-in",
  "menu": {
    "m": "profile:media",
    "s": "profile:slides",
    "w": "profile:write",
    "c": "profile:copilot",
    "t": "profile:tv",
    "p": "host:previous",
    "l": "host:next"
  },
  "start": {
    "phone": "media",
    "computer": "media",
    "tv": "tv"
  },
  "profiles": [
    {
      "id": "media",
      "name": "Media",
      "buzz": 1,
      "gestures": {
        "index.hold": "menu",
        "index.doubleTap": "media:playPause",
        "middle.doubleTap": { "phone": "phoneMute", "computer": "key:cmd+shift+m" },
        "middle.hold": "media:voice",
        "swipe.right": "media:next",
        "swipe.left": "media:previous",
        "dial.cw": "media:volumeUp",
        "dial.ccw": "media:volumeDown"
      }
    },
    {
      "id": "slides",
      "name": "Slides",
      "hosts": ["computer"],
      "buzz": 2,
      "gestures": {
        "index.hold": "menu",
        "index.doubleTap": "key:right",
        "middle.doubleTap": "key:cmd+shift+m",
        "middle.hold": "media:voice",
        "swipe.right": "key:right",
        "swipe.left": "key:left",
        "dial.cw": "media:volumeUp",
        "dial.ccw": "media:volumeDown"
      }
    },
    {
      "id": "write",
      "name": "Write",
      "hosts": ["computer"],
      "buzz": 3,
      "typing": true,
      "pointer": true,
      "gestures": {
        "index.hold": "menu",
        "index.doubleTap": "mouse:click",
        "middle.doubleTap": "key:enter",
        "middle.hold": "media:voice",
        "swipe.up": "mouse:scrollUp",
        "swipe.down": "mouse:scrollDown",
        "swipe.right": "key:space",
        "swipe.left": "key:backspace"
      }
    },
    {
      "id": "copilot",
      "name": "Copilot",
      "hosts": ["computer"],
      "buzz": 4,
      "gestures": {
        "index.hold": "menu",
        "index.doubleTap": "key:enter",
        "middle.doubleTap": "key:ctrl+shift+space",
        "middle.hold": "hold:alt+space",
        "swipe.right": "key:cmd+shift+]",
        "swipe.left": "key:cmd+shift+[",
        "swipe.up": "key:cmd+'",
        "swipe.down": "key:cmd+u",
        "dial.cw": "key:down",
        "dial.ccw": "key:up"
      }
    },
    {
      "id": "tv",
      "name": "TV",
      "hosts": ["tv", "computer"],
      "buzz": 1,
      "gestures": {
        "index.hold": "menu",
        "index.doubleTap": "key:enter",
        "middle.doubleTap": "key:escape",
        "middle.hold": "media:voice",
        "swipe.right": "key:right",
        "swipe.left": "key:left",
        "swipe.up": "key:up",
        "swipe.down": "key:down",
        "dial.cw": "media:volumeUp",
        "dial.ccw": "media:volumeDown"
      }
    }
  ]
}
"""#

    public static let builtin: GestureProfileSet = {
        do {
            return try decode(Data(builtinJSON.utf8))
        } catch {
            preconditionFailure("the built-in profiles are valid: \(error)")
        }
    }()
}
