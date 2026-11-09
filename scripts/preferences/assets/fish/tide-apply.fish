#!/usr/bin/env fish
# tide-apply.fish —— 用 tide 自带的 configure --auto 写入一整套一致的 universal 变量。
# 不能手写 tide_* 变量：frame、颜色、分隔符、图标这些是 configure 派生的，缺了会
# 退化成极简提示符（实测：手写版本 frame=false、pwd_bg=normal、无 os 项）。
# 选项取值来自 tide 6 的 choices：style=Lean|Classic|Rainbow，
# powerline_prompt_tails/heads=Flat|Sharp|Slanted|Round。
tide configure --auto \
    --style=Classic \
    --prompt_colors='True color' \
    --show_time='24-hour format' \
    --classic_prompt_color=Dark \
    --classic_prompt_separators=Angled \
    --lean_prompt_height='Two lines' \
    --powerline_prompt_heads=Round \
    --powerline_prompt_tails=Round \
    --powerline_prompt_style='Two lines, character and frame' \
    --powerline_right_prompt_frame=No \
    --rainbow_prompt_separators=Angled \
    --prompt_connection=Solid \
    --prompt_connection_andor_frame_color=Lightest \
    --prompt_spacing=Sparse \
    --icons='Many icons' \
    --transient=No

# configure --auto 在非交互环境只写基础变量，_tide_left_items/_tide_right_items
# 这两份派生缓存不会生成；新用户首次登录时提示符会缺右侧状态段和 os 图标。
# 直接调用 tide 自己的派生函数，保持和交互式 configure 相同的过滤规则。
_tide_remove_unusable_items 2>/dev/null || true
