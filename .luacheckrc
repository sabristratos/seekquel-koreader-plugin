std = "luajit"

globals = {}

read_globals = {
    "require",
}

ignore = {
    "212/_.*",
    "212/self",
    "213/_.*",
    "631",
}

exclude_files = {
    "emulator/state",
}

files["spec/stubs.lua"] = {
    ignore = { "121", "122", "142", "143" },
}
