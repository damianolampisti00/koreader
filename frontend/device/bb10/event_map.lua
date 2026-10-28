-- BlackBerry 10 key caps: Unicode for printable keys (like SDL keycodes), KEYCODE_* (sys/keycodes.h) otherwise.
return {
    [ 97] = "A", [ 98] = "B", [ 99] = "C", [100] = "D", [101] = "E", [102] = "F",
    [103] = "G", [104] = "H", [105] = "I", [106] = "J", [107] = "K", [108] = "L",
    [109] = "M", [110] = "N", [111] = "O", [112] = "P", [113] = "Q", [114] = "R",
    [115] = "S", [116] = "T", [117] = "U", [118] = "V", [119] = "W", [120] = "X",
    [121] = "Y", [122] = "Z",

    [48] = "0", [49] = "1", [50] = "2", [51] = "3", [52] = "4",
    [53] = "5", [54] = "6", [55] = "7", [56] = "8", [57] = "9",

    [33] = "!",
    [34] = "\"",
    [35] = "#",
    [36] = "$",
    [37] = "%",
    [38] = "&",
    [39] = "'",
    [40] = "(",
    [41] = ")",
    [42] = "*",
    [43] = "+",
    [44] = ",",
    [45] = "-",
    [46] = ".",
    [47] = "/",

    [58] = ":",
    [59] = ";",
    [60] = "<",
    [61] = "=",
    [62] = ">",
    [63] = "?",
    [64] = "@",

    [91] = "[",
    [92] = "\\",
    [93] = "]",
    [94] = "^",
    [95] = "_",
    [96] = "`",

    [32] = " ",

    [0xF008] = "Backspace", -- KEYCODE_BACKSPACE
    [0xF00D] = "Press", -- KEYCODE_RETURN
    [0xF01B] = "Back", -- KEYCODE_ESCAPE
    [0xF0FF] = "Del", -- KEYCODE_DELETE
    [0xF0E1] = "Shift", -- KEYCODE_LEFT_SHIFT
    [0xF0E2] = "Shift", -- KEYCODE_RIGHT_SHIFT
    [0xF0E9] = "Alt", -- KEYCODE_LEFT_ALT
    [0xF0EA] = "Alt", -- KEYCODE_RIGHT_ALT
    [0xF052] = "Up", -- KEYCODE_UP
    [0xF054] = "Down", -- KEYCODE_DOWN
    [0xF051] = "Left", -- KEYCODE_LEFT
    [0xF053] = "Right", -- KEYCODE_RIGHT
    [0xF055] = "LPgBack", -- KEYCODE_PG_UP
    [0xF056] = "LPgFwd", -- KEYCODE_PG_DOWN
    [0xF067] = "Menu", -- KEYCODE_MENU

    -- Side keys.
    [0xF21D] = "RPgBack", -- KEYCODE_VOLUME_UP
    [0xF21E] = "RPgFwd", -- KEYCODE_VOLUME_DOWN
    [0xF210] = "Menu", -- KEYCODE_PLAY (the key between the volume keys)
}
