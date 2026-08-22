# conf.d/fastfetch.fish —— 交互式登录 shell 启动时显示 fastfetch 系统信息
# 仅在交互式、且非嵌套子 shell 时运行，避免每次开子 shell 都刷屏。

if status is-interactive
    # 只在「顶层交互 shell」运行：SHLVL=1 表示首次登录的交互 shell
    # （fish 的 SHLVL 在首次登录交互 shell 为 1，子 shell 递增）
    if test "$SHLVL" -eq 1
        # 仅当 fastfetch 可执行时运行，避免未安装报错
        if type -q fastfetch
            fastfetch
        end
    end
end
