#!/bin/bash
# Finder opens this file in Terminal. Locate the bundled installer, never a checkout.
set -u
# The app discovers AI only in its standard Application Support directory.
# Alternate runtime locations are for direct setup-script tests, not this launcher.
unset YINGSHU_AI_RUNTIME_DIR

onboarding_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)" || exit 1
onboarding_setup="$onboarding_dir/安装支援/prepare-local-ai.sh"
onboarding_status=0

printf '%s\n' '映述 · 准备本地 AI' '首次准备需要联网下载公开运行环境和模型，无需 API Key。' ''
if [[ ! -f "$onboarding_setup" ]]; then
    printf '%s\n' '未找到同目录的“安装支援/prepare-local-ai.sh”。' '请重新完整解压 YingShu-Mac.zip，将准备器与“安装支援”文件夹放在一起后重试。'
    onboarding_status=1
else
    /bin/bash "$onboarding_setup"
    onboarding_status=$?
fi

printf '\n'
if [[ "$onboarding_status" -eq 0 ]]; then
    printf '%s\n' '本地 AI 准备完成。' '请正常退出后重新打开“映述.app”，在语音与整理设置中选择“AI识别与整理”。' '已有项目、原始素材和云端整理设置没有被更改。'
elif [[ "$onboarding_status" -eq 130 ]]; then
    printf '%s\n' '本次准备已取消。需要时可重新双击准备器。'
else
    printf '本地 AI 尚未准备完成（退出码 %s）。\n' "$onboarding_status"
    printf '%s\n' '请查看上方的具体失败原因与日志位置，处理后重新双击准备器重试。' '未完成准备时，仍可使用手写感想与导出；系统识别是否可用取决于 macOS 中文资源。'
fi
printf '\n%s\n' '按回车键结束；终端会保留上方结果，便于查看。'
IFS= read -r onboarding_reply || true
exit "$onboarding_status"
