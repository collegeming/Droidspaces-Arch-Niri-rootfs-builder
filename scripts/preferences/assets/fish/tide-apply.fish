#!/usr/bin/env fish
# tide-apply.fish —— 用 tide 自带的 configure --auto 写入一整套一致的 universal 变量。
# 不能手写 tide_* 变量：frame、颜色、分隔符、图标这些是 configure 派生的，缺了会
# 退化成极简提示符（实测：手写版本 frame=false、pwd_bg=normal、无 os 项）。
#
# 样式对齐 WSL 上的目标效果：Rainbow（Tango 分色：os 灰、pwd 蓝、git 绿/黄、
# 时间浅灰胶囊）+ Angled 分隔符 + 双 frame + 两行带 character。Classic 会把所有
# 段压成同一个深灰底，和截图差异明显，因此这里用 Rainbow。
tide configure --auto \
    --style=Rainbow \
    --prompt_colors='True color' \
    --show_time='24-hour format' \
    --rainbow_prompt_separators=Angled \
    --powerline_prompt_heads=Round \
    --powerline_prompt_tails=Round \
    --powerline_prompt_style='Two lines, character and frame' \
    --powerline_right_prompt_frame=Yes \
    --prompt_connection=Solid \
    --prompt_connection_andor_frame_color=Lightest \
    --prompt_spacing=Sparse \
    --icons='Many icons' \
    --transient=No

# configure --auto 在非交互环境只写基础变量，_tide_left_items/_tide_right_items
# 这两份派生缓存不会生成；新用户首次登录时提示符会缺右侧状态段和 os 图标。
# 直接调用 tide 自己的派生函数，保持和交互式 configure 相同的过滤规则。
_tide_remove_unusable_items 2>/dev/null || true
