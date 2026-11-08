# ~/.config/fish/conf.d/reef.fish —— 启用 reef bash 兼容层
# reef 装好后默认未启用，需手动 reef on。未安装时不要调用：fish 的
# “未知的命令” 打在自己的 stderr 上，2>/dev/null 盖不住，登录就会刷一串报错。
if status is-interactive; and type -q reef
    reef on
end
