#!/usr/bin/env fish
# tide-apply.fish —— 直接写入 Tide v6 universal 变量，免去 tide configure 向导
# 样式: Lean | 左: os → pwd → git → newline → character
# 右: status, cmd_duration, context, jobs, bun, node, python, rustc, java, nix_shell, zig, time
# 提示符: ❯ | 单行（prompt 前不加空行）

# ── 提示符结构与样式 ──
set -U tide_left_prompt_items          os pwd git newline character
set -U tide_right_prompt_items          status cmd_duration context jobs bun node python rustc java nix_shell zig time
set -U tide_left_prompt_frame_enabled   false
set -U tide_right_prompt_frame_enabled  false
set -U tide_prompt_add_newline_before   false      # 单行（不额外加前置空行）
set -U tide_prompt_pad_items            false
set -U tide_prompt_transient_enabled    false
set -U tide_prompt_min_cols             34
set -U tide_prompt_color_frame_and_connection 6C6C6C
set -U tide_prompt_color_separator_same_color 949494

# ── 分隔符/前后缀（lean 空格分隔风格）──
set -U tide_left_prompt_prefix             ''
set -U tide_left_prompt_suffix             ' '
set -U tide_left_prompt_separator_diff_color   ' '
set -U tide_left_prompt_separator_same_color   ' '

# ── character 提示符 ──
set -U tide_character_color         $_tide_color_green
set -U tide_character_color_failure FF0000
# ❯ 符号由 tide_character_icon 控制（默认即 ❯，显式再设一次保险）
set -U tide_character_icon          '❯'

# ── os ──
set -U tide_os_bg_color normal
set -U tide_os_color    normal

# ── pwd ──
set -U tide_pwd_bg_color            normal
set -U tide_pwd_color_anchors       $_tide_color_light_blue
set -U tide_pwd_color_dirs          $_tide_color_dark_blue
set -U tide_pwd_color_truncated_dirs 8787AF
set -U tide_pwd_markers             .bzr .citc .git .hg .node-version .python-version .ruby-version .shorten_folder_marker .svn .terraform bun.lockb Cargo.toml composer.json CVS go.mod package.json build.zig

# ── git ──
set -U tide_git_bg_color            normal
set -U tide_git_bg_color_unstable   normal
set -U tide_git_bg_color_urgent     normal
set -U tide_git_color_branch        $_tide_color_green
set -U tide_git_color_conflicted    FF0000
set -U tide_git_color_dirty         $_tide_color_gold
set -U tide_git_color_operation     FF0000
set -U tide_git_color_staged        $_tide_color_gold
set -U tide_git_color_stash         $_tide_color_green
set -U tide_git_color_untracked     $_tide_color_light_blue
set -U tide_git_color_upstream      $_tide_color_green
set -U tide_git_truncation_length   24
set -U tide_git_truncation_strategy ''

# ── status ──
set -U tide_status_bg_color          normal
set -U tide_status_bg_color_failure  normal
set -U tide_status_color             $_tide_color_dark_green
set -U tide_status_color_failure     FF0000

# ── cmd_duration ──
set -U tide_cmd_duration_bg_color    normal
set -U tide_cmd_duration_color       87875F
set -U tide_cmd_duration_decimals    0
set -U tide_cmd_duration_threshold   3000

# ── context ──
set -U tide_context_always_display   false
set -U tide_context_bg_color         normal
set -U tide_context_color_default    D7AF87
set -U tide_context_color_root       $_tide_color_gold
set -U tide_context_color_ssh        D7AF87
set -U tide_context_hostname_parts   1

# ── jobs ──
set -U tide_jobs_bg_color            normal
set -U tide_jobs_color               $_tide_color_dark_green
set -U tide_jobs_number_threshold    1000

# ── 语言运行时（lean 风格，normal 背景）──
set -U tide_bun_bg_color       normal; set -U tide_bun_color       FBF0DF
set -U tide_node_bg_color      normal; set -U tide_node_color      44883E
set -U tide_python_bg_color    normal; set -U tide_python_color    00AFAF
set -U tide_rustc_bg_color     normal; set -U tide_rustc_color     FF0000
set -U tide_java_bg_color      normal; set -U tide_java_color      ED8B00
set -U tide_nix_shell_bg_color normal; set -U tide_nix_shell_color 7EBAE4
set -U tide_zig_bg_color       normal; set -U tide_zig_color       FFFFFF

# ── time ──
set -U tide_time_bg_color normal
set -U tide_time_color    8787AF

echo "✓ Tide v6 Lean 配置已写入 universal 变量"
echo "  左: os → pwd → git → newline → character (❯)"
echo "  右: status, cmd_duration, context, jobs, bun, node, python, rustc, java, nix_shell, zig, time"
echo "  单行模式 (tide_prompt_add_newline_before=false)"
echo "  如需微调: fish -c 'tide configure' 或直接 set -U tide_xxx ..."
