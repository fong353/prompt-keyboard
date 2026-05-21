#!/bin/bash
# 生成 PromptKeyboard 图标
# 用法: ./make_icon.sh <output.icns>
set -euo pipefail
cd "$(dirname "$0")"
exec swift make_icon.swift "${1:-AppIcon.icns}"
