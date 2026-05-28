# Crash-recovery demo: torn-write detection + truncation on replay.
# Regenerate the GIF from the repo root with:  vhs docs/torn_write_demo.tape
# (requires `brew install vhs` and a Release build at ./build/clipd-cli).

Output docs/torn_write_demo.gif

Set Shell "bash"
Set FontSize 16
Set Width 1100
Set Height 800
Set Theme "Catppuccin Mocha"
Set Padding 20

Sleep 500ms
Type "./scripts/torn_write_demo.sh ./build/clipd-cli"
Sleep 600ms
Enter
Sleep 4s
