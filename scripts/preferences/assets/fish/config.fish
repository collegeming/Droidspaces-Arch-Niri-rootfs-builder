# ~/.config/fish/config.fish —— 主配置（精简，模块化部分放 conf.d/）

set fish_greeting ""

set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx COLORTERM truecolor

if status is-interactive
    # mise 多语言版本管理（替代 nvm/asdf/pyenv 等）
    # 安装后取消注释：mise activate fish | source
end
