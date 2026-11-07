# ~/.config/fish/conf.d/reef.fish —— 启用 reef bash 兼容层
# reef 默认装好后未启用，需手动 reef on；放交互块避免非交互会话触发
if status is-interactive
    reef on 2>/dev/null
end
