-- yap keybinds for Omarchy.
--
-- `o.bind` is Omarchy's helper, from its default helpers.lua. On stock Hyprland the same two
-- binds are plain config lines:
--     bind = SUPER, H, exec, ~/.local/bin/yap
--     bind = SUPER SHIFT, H, exec, ~/.local/bin/yap --last
--
-- Paste the two lines below into ~/.config/hypr/bindings.lua, then:
--     hyprctl reload && hyprctl configerrors      -- expect no output
--     omarchy menu keybindings --print | grep -i yap
--
-- install.sh puts the client in ~/.local/bin. If $HOME does not expand in your setup, write the
-- absolute path instead (e.g. /home/you/.local/bin/yap).

o.bind("SUPER + H", "Dictate (yap)", "$HOME/.local/bin/yap")

-- The recovery bind: inserts the LAST transcript into whatever is focused right now.
-- Every transcript is also left on the clipboard, so Ctrl+V works as a fallback.
o.bind("SUPER + SHIFT + H", "Insert last transcript (yap)", "$HOME/.local/bin/yap --last")
