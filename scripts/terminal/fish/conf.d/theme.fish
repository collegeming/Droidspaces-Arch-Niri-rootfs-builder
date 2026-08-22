# ~/.config/fish/conf.d/theme.fish —— 语法高亮配色持久化
# fish_config theme choose 只对当前会话生效，写进 conf.d 每次启动自动加载
if status is-interactive
    fish_config theme choose catppuccin-frappe 2>/dev/null
    set -g fish_color_autosuggestion 545454
end
