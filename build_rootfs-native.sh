#!/bin/bash
: "${VERSION:=dev}"
DATE=$(date +%Y%m%d)      # 获取当前日期
ARCH=$(uname -m)          # 获取当前系统架构
ENABLE_binfmt="false"
BUILD_KDE_plus="false"
ANLAND_REPO=""
# 解析输入参数 (-i 指定 Dockerfile，-v 指定版本号)
while getopts "i:v:r:K:L:P:a:b:c:d:e:f:g:h:j:u:A:" opt; do
  case $opt in
    i) DOCKERFILE="$OPTARG" ;; # -i 参数赋值给 DOCKERFILE 变量
    v) VERSION="$OPTARG" ;;    # -v 参数赋值给 VERSION 变量
    r) ANLAND_REPO="$OPTARG" ;; # anland 仓库地址
    K) BUILD_KDE="$OPTARG"  ;;
    L) BUILD_KDE_plus="$OPTARG"  ;;
    P) PulseAudio="$OPTARG"  ;;
    g) ENABLE_zh_tz="$OPTARG"  ;; # 中文支持
    a) ENABLE_binfmt="$OPTARG" ;; # -a 跨架构支持
    b) ENABLE_yj="$OPTARG" ;;
    c) ENABLE_mesa="$OPTARG" ;;
    d) ENABLE_kfgj="$OPTARG" ;;
    e) ENABLE_zip="$OPTARG" ;;
    f) ENABLE_docker="$OPTARG" ;;
    h) ENABLE_srf="$OPTARG" ;; # 输入法 fcitx5
    j) ENABLE_tmoe="$OPTARG" ;; # tmoe
    u) USERNAME="$OPTARG" ;; # 自定义用户名
    A) ENABLE_anland_kde="$OPTARG" ;; # anland_kde 支持
    *) echo "用法: $0 -i <template.Dockerfile> [-v <version>]" ; exit 1 ;;
  esac
done

: "${USERNAME:=Gold}"

# 校验：检查是否传递了 Dockerfile 模板文件
if [ -z "$DOCKERFILE" ]; then
    echo "错误：必须使用 -i 参数指定模板文件。"
    exit 1
fi

# 校验：检查指定的 Dockerfile 文件在本地是否存在
if [ ! -f "$DOCKERFILE" ]; then
    echo "错误：找不到模板文件 '$DOCKERFILE'。"
    exit 1
fi

# 提取前缀名称（例如：从 Debian-13-KDE.Dockerfile 中提取出 Debian-13-KDE）
PREFIX=$(echo "$DOCKERFILE" | sed 's/\.Dockerfile//')

echo "========================================================="
echo " 开始构建项目 : $PREFIX"
echo " 使用模板文件 : $DOCKERFILE"
echo " 当前构建版本 : $VERSION"
echo " 跨架构 : $ENABLE_binfmt"
echo " 容器识别部分硬件和网络：$ENABLE_yj"
echo "========================================================="

# 1. 环境初始化（原生架构模式）
echo "确保处于原生构建环境..."
# 在原生（Native）模式下，不需要初始化 QEMU 模拟器或 binfmt 跨架构支持

# 2. 跨平台编译器（Buildx Builder）设置
# 检查是否存在名为 'droidspaces-builder' 的 buildx 构建器，如果没有则创建
if ! docker buildx inspect droidspaces-builder >/dev/null 2>&1; then
    echo "正在创建新的 buildx 构建器: droidspaces-builder"
    docker buildx create --name droidspaces-builder --driver docker-container --use
else
    echo "使用已存在的 buildx 构建器: droidspaces-builder"
    docker buildx use droidspaces-builder
fi

# 引导启动构建器，确保其处于就绪状态
docker buildx inspect --bootstrap || echo "警告: 引导失败，尝试继续执行..."

# 开启严格模式：后续任何一行命令执行失败（返回非0状态码），脚本立即熔断退出
set -e

# 3. 核心构建流程
TEMP_TAR="custom-${PREFIX}-rootfs.tar"
FINAL_NAME="${PREFIX}-Droidspaces-rootfs-${ARCH}-${DATE}-${VERSION}.tar.xz"

echo "正在运行 Docker Build (原生模式)..."




docker buildx build \
  --target export \
  --output type=tar,dest="$TEMP_TAR" \
  --build-arg BUILD_KDE="$BUILD_KDE" \
  --build-arg BUILD_KDE_plus="$BUILD_KDE_plus" \
  --build-arg PulseAudio="$PulseAudio" \
  --build-arg ENABLE_zh_tz_ARG="$ENABLE_zh_tz" \
  --build-arg ENABLE_binfmt_ARG="$ENABLE_binfmt" \
  --build-arg ENABLE_yj_ARG="$ENABLE_yj" \
  --build-arg ENABLE_mesa_ARG="$ENABLE_mesa" \
  --build-arg ENABLE_kfgj_ARG="$ENABLE_kfgj" \
  --build-arg ENABLE_zip_ARG="$ENABLE_zip" \
  --build-arg ENABLE_docker_ARG="$ENABLE_docker" \
  --build-arg ENABLE_srf_ARG="$ENABLE_srf" \
  --build-arg ENABLE_tmoe_ARG="$ENABLE_tmoe" \
  --build-arg ENABLE_anland_kde_ARG="$ENABLE_anland_kde" \
  --build-arg ANLAND_REPO="$ANLAND_REPO" \
  --build-arg USERNAME="$USERNAME" \
  -f "$DOCKERFILE" \
  .





echo "正在压缩构建产物 (使用 xz 最高压缩率 - 开启多线程加速)..."
xz -T0 -9 -f "$TEMP_TAR"

echo "正在重命名最终文件: $FINAL_NAME"
mv "${TEMP_TAR}.xz" "$FINAL_NAME"

echo "========================================================="
echo " 恭喜！构建成功完成: $FINAL_NAME"
echo "========================================================="
