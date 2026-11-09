# ~/.config/fish/conf.d/reef.fish —— 启用 reef bash 兼容层
# fish 按 basename 去重 conf.d：本文件会遮蔽包的
# /usr/share/fish/vendor_conf.d/reef.fish，所以必须自己 source 再调用
# 初始化函数；直接 `reef on` 会报 unknown command 'on'。
if status is-interactive
    if test -r /usr/share/fish/vendor_conf.d/reef.fish
        source /usr/share/fish/vendor_conf.d/reef.fish
        functions -q __reef_setup; and __reef_setup
    else
        echo "reef: 未安装（缺少 /usr/share/fish/vendor_conf.d/reef.fish）" >&2
    end
end
