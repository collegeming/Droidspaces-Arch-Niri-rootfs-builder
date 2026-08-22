#!/usr/bin/env fish
# tide-apply.fish —— 直接写入 Tide v6 universal 变量，免去 tide configure 向导
# 样式: Lean (Classic 风格 Powerline) | 双行 | 启用 frame
# 左: os → pwd → git → newline → character
# 右: status, cmd_duration, context, jobs, direnv, bun, node, python, rustc, java,
#     php, pulumi, ruby, go, gcloud, kubectl, distrobox, toolbox, terraform, aws,
#     nix_shell, crystal, elixir, zig, time
# 提示符: ❯ | 双行（prompt 前不加空行）

# ── 提示符结构与样式 ──
set -U _tide_left_items        os pwd git newline character
set -U _tide_right_items       status cmd_duration context jobs direnv bun node python rustc java php pulumi ruby go gcloud kubectl distrobox toolbox terraform aws nix_shell crystal elixir zig time
set -U tide_left_prompt_items  os pwd git newline character
set -U tide_right_prompt_items status cmd_duration context jobs direnv bun node python rustc java php pulumi ruby go gcloud kubectl distrobox toolbox terraform aws nix_shell crystal elixir zig time

set -U tide_left_prompt_frame_enabled   true
set -U tide_right_prompt_frame_enabled  true
set -U tide_prompt_add_newline_before   false      # 不额外加前置空行（视觉上仍是双行）
set -U tide_prompt_pad_items            true
set -U tide_prompt_transient_enabled    false
set -U tide_prompt_min_cols             34
set -U tide_prompt_color_frame_and_connection 6C6C6C
set -U tide_prompt_color_separator_same_color 949494
set -U tide_prompt_icon_connection             ' '

# ── Powerline 分隔符/前后缀（Classic 风格）──
set -U tide_left_prompt_prefix                 \ue0b6
set -U tide_left_prompt_suffix                 \ue0b4
set -U tide_left_prompt_separator_diff_color   \ue0b0
set -U tide_left_prompt_separator_same_color   \ue0b1
set -U tide_right_prompt_prefix                \ue0b6
set -U tide_right_prompt_suffix                \ue0b4
set -U tide_right_prompt_separator_diff_color  \ue0b2
set -U tide_right_prompt_separator_same_color  \ue0b3

# ── character 提示符 ──
set -U tide_character_color         5FD700
set -U tide_character_color_failure FF0000
set -U tide_character_icon          '❯'
set -U tide_character_vi_icon_default '❮'
set -U tide_character_vi_icon_replace '▶'
set -U tide_character_vi_icon_visual 'V'

# ── os ──
set -U tide_os_bg_color 4D4D4D
set -U tide_os_color    1793D1
set -U tide_os_icon     \uf303

# ── pwd ──
set -U tide_pwd_bg_color            3465A4
set -U tide_pwd_color_anchors       E4E4E4
set -U tide_pwd_color_dirs          E4E4E4
set -U tide_pwd_color_truncated_dirs BCBCBC
set -U tide_pwd_icon_home           \uf015
set -U tide_pwd_icon                \uf07c
set -U tide_pwd_icon_unwritable     \uf023
set -U tide_pwd_markers             .bzr .citc .git .hg .node-version .python-version .ruby-version .shorten_folder_marker .svn .terraform bun.lockb Cargo.toml composer.json CVS go.mod package.json build.zig

# ── git ──
set -U tide_git_bg_color            4E9A06
set -U tide_git_bg_color_unstable   C4A000
set -U tide_git_bg_color_urgent      CC0000
set -U tide_git_color_branch        000000
set -U tide_git_color_conflicted    000000
set -U tide_git_color_dirty         000000
set -U tide_git_color_operation     000000
set -U tide_git_color_staged        000000
set -U tide_git_color_stash         000000
set -U tide_git_color_untracked     000000
set -U tide_git_color_upstream      000000
set -U tide_git_icon                \uf1d3
set -U tide_git_truncation_length   24
set -U tide_git_truncation_strategy ''

# ── status ──
set -U tide_status_bg_color          2E3436
set -U tide_status_bg_color_failure   CC0000
set -U tide_status_color              4E9A06
set -U tide_status_color_failure      FFFF00
set -U tide_status_icon               \u2714
set -U tide_status_icon_failure        \u2718

# ── cmd_duration ──
set -U tide_cmd_duration_bg_color    C4A000
set -U tide_cmd_duration_color        000000
set -U tide_cmd_duration_decimals     0
set -U tide_cmd_duration_threshold    3000
set -U tide_cmd_duration_icon         \uf252

# ── context ──
set -U tide_context_always_display    false
set -U tide_context_bg_color          444444
set -U tide_context_color_default     D7AF87
set -U tide_context_color_root        D7AF00
set -U tide_context_color_ssh          D7AF87
set -U tide_context_hostname_parts    1

# ── jobs ──
set -U tide_jobs_bg_color            444444
set -U tide_jobs_color               4E9A06
set -U tide_jobs_icon                \uf013
set -U tide_jobs_number_threshold    1000

# ── direnv ──
set -U tide_direnv_bg_color          D7AF00
set -U tide_direnv_bg_color_denied   FF0000
set -U tide_direnv_color             000000
set -U tide_direnv_color_denied      000000
set -U tide_direnv_icon              \u25bc

# ── 语言运行时模块 ──
set -U tide_bun_bg_color       FBF0DF
set -U tide_bun_color           14151A
set -U tide_bun_icon            \U000f0cd3

set -U tide_node_bg_color      44883E
set -U tide_node_color          000000
set -U tide_node_icon           \ue24f

set -U tide_python_bg_color    444444
set -U tide_python_color        00AFAF
set -U tide_python_icon         \U000f0320

set -U tide_rustc_bg_color     F74C00
set -U tide_rustc_color         000000
set -U tide_rustc_icon          \ue7a8

set -U tide_java_bg_color      ED8B00
set -U tide_java_color          000000
set -U tide_java_icon           \ue256

set -U tide_php_bg_color        617CBE
set -U tide_php_color            000000
set -U tide_php_icon            \ue608

set -U tide_ruby_bg_color        B31209
set -U tide_ruby_color           000000
set -U tide_ruby_icon            \ue23e

set -U tide_go_bg_color         00ACD7
set -U tide_go_color             000000
set -U tide_go_icon             \ue627

set -U tide_zig_bg_color         F7A41D
set -U tide_zig_color            000000
set -U tide_zig_icon             \ue6a9

set -U tide_crystal_bg_color    FFFFFF
set -U tide_crystal_color        000000
set -U tide_crystal_icon         \ue62f

set -U tide_elixir_bg_color      4E2A8E
set -U tide_elixir_color         000000
set -U tide_elixir_icon          \ue62d

set -U tide_nix_shell_bg_color  7EBAE4
set -U tide_nix_shell_color      000000
set -U tide_nix_shell_icon       \uf313

# ── 云平台 / 容器 / IaC ──
set -U tide_aws_bg_color       FF9900
set -U tide_aws_color           232F3E
set -U tide_aws_icon            \uf270

set -U tide_gcloud_bg_color     4285F4
set -U tide_gcloud_color         000000
set -U tide_gcloud_icon          \U000f02ad

set -U tide_kubectl_bg_color    326CE5
set -U tide_kubectl_color         000000
set -U tide_kubectl_icon         \U000f10fe

set -U tide_distrobox_bg_color  FF00FF
set -U tide_distrobox_color      000000
set -U tide_distrobox_icon       \U000f01a7

set -U tide_toolbox_bg_color    613583
set -U tide_toolbox_color         000000
set -U tide_toolbox_icon          \ue24f

set -U tide_terraform_bg_color  800080
set -U tide_terraform_color      000000
set -U tide_terraform_icon        \U000f1062

set -U tide_pulumi_bg_color       F7BF2A
set -U tide_pulumi_color           000000
set -U tide_pulumi_icon            \uf1b2

set -U tide_docker_bg_color      2496ED
set -U tide_docker_color           000000
set -U tide_docker_icon           \uf308
set -U tide_docker_default_contexts default colima

# ── shlvl ──
set -U tide_shlvl_bg_color      808000
set -U tide_shlvl_color           000000
set -U tide_shlvl_icon           \uf120
set -U tide_shlvl_threshold       1

# ── private_mode ──
set -U tide_private_mode_bg_color F1F3F4
set -U tide_private_mode_color     000000
set -U tide_private_mode_icon     \U000f05f9

# ── time ──
set -U tide_time_bg_color       D3D7CF
set -U tide_time_color            000000
set -U tide_time_format           '%T'

# ── vi_mode ──
set -U tide_vi_mode_bg_color_default 949494
set -U tide_vi_mode_bg_color_insert   87AFAF
set -U tide_vi_mode_bg_color_replace 87AF87
set -U tide_vi_mode_bg_color_visual   FF8700
set -U tide_vi_mode_color_default     000000
set -U tide_vi_mode_color_insert      000000
set -U tide_vi_mode_color_replace     000000
set -U tide_vi_mode_color_visual      000000
set -U tide_vi_mode_icon_default      'D'
set -U tide_vi_mode_icon_insert       'I'
set -U tide_vi_mode_icon_replace      'R'
set -U tide_vi_mode_icon_visual       'V'

# ── 其他 ──
set -U VIRTUAL_ENV_DISABLE_PROMPT true

echo "✓ Tide v6 配置已写入 universal 变量"
echo "  样式: Lean (Classic Powerline) | 双行 frame"
echo "  左: os → pwd → git → newline → character (❯)"
echo "  右: status, cmd_duration, context, jobs, direnv, bun, node, python, rustc, java,"
echo "      php, pulumi, ruby, go, gcloud, kubectl, distrobox, toolbox, terraform, aws,"
echo "      nix_shell, crystal, elixir, zig, time"
echo "  双行模式 (frame 启用, prompt 前不加空行)"
echo "  如需微调: fish -c 'tide configure' 或直接 set -U tide_xxx ..."
