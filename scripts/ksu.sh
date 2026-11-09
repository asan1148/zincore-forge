#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEVICE="${1:?Usage: ksu.sh <device>}"
DEVICE_JSON="devices/${DEVICE}.json"

: "${KSU_REPO_URL:?KSU_REPO_URL not set — source config.env first}"
: "${KSU_REPO_PIN:?KSU_REPO_PIN not set — source config.env first}"
: "${SUSFS_REPO_URL:?SUSFS_REPO_URL not set — source config.env first}"
: "${SUSFS_REPO_PIN:?SUSFS_REPO_PIN not set — source config.env first}"

KERNEL_VERSION=$(read_field kernel_version)
[ -n "$KERNEL_VERSION" ] || die "kernel_version missing in $DEVICE_JSON"

# Clone + pin dependencies BEFORE executing anything from them
WORKDIR="$(pwd)"
KSU_SRC="${WORKDIR}/.zincore_deps/ksu_next"
SUSFS_SRC="${WORKDIR}/.zincore_deps/susfs"
mkdir -p "$(dirname "$KSU_SRC")"

log "Cloning KernelSU-Next (pinned to ${KSU_REPO_PIN})"
git init --quiet "$KSU_SRC"
git -C "$KSU_SRC" remote add origin "$KSU_REPO_URL"
git -C "$KSU_SRC" fetch --quiet --depth 1 origin "$KSU_REPO_PIN"
git -C "$KSU_SRC" checkout --quiet FETCH_HEAD

log "Cloning SuSFS source (JackA1ltman, pinned to ${SUSFS_REPO_PIN})"
git init --quiet "$SUSFS_SRC"
git -C "$SUSFS_SRC" remote add origin "$SUSFS_REPO_URL"
git -C "$SUSFS_SRC" fetch --quiet --depth 1 origin "$SUSFS_REPO_PIN"
git -C "$SUSFS_SRC" checkout --quiet FETCH_HEAD

FRAGMENT_DIR="zincore_fragments"
FRAGMENT_FILE="${FRAGMENT_DIR}/kernelsu.config"
mkdir -p "$FRAGMENT_DIR"
: > "$FRAGMENT_FILE"

log "Installing KernelSU-Next (pinned to ${KSU_REPO_PIN})"
bash "${KSU_SRC}/kernel/setup.sh" "$KSU_REPO_PIN"

# 兜底确保 drivers/Kconfig 与 drivers/Makefile 包含 KernelSU 入口（针对非 GKI 4.19 树）
if [ -d "KernelSU" ] && [ ! -d "drivers/kernelsu" ]; then
    ln -sfn ../KernelSU/kernel drivers/kernelsu
fi

if [ -f "drivers/Kconfig" ] && ! grep -q "drivers/kernelsu/Kconfig" "drivers/Kconfig" 2>/dev/null; then
    sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' "drivers/Kconfig"
    log "Injected KernelSU Kconfig entry into drivers/Kconfig"
fi

if [ -f "drivers/Makefile" ] && ! grep -q "kernelsu" "drivers/Makefile" 2>/dev/null; then
    echo "obj-\$(CONFIG_KSU) += kernelsu/" >> drivers/Makefile
    log "Injected KernelSU obj entry into drivers/Makefile"
fi

# 兼容分支名（如 next）和具体 Commit SHA-1 的校验逻辑
if [ -d "drivers/kernelsu" ] || [ -d "KernelSU" ]; then
    CURRENT_HEAD="$(git -C "$KSU_SRC" rev-parse --short HEAD 2>/dev/null || echo "pinned")"
    log "KernelSU-Next installed successfully (at ${CURRENT_HEAD})"
else
    die "KernelSU-Next setup failed — drivers/kernelsu or KernelSU directory not found"
fi

log "Applying SuSFS patch for kernel $KERNEL_VERSION"

if grep -q "CONFIG_KSU_SUSFS" "fs/namespace.c" 2>/dev/null; then
    log "SuSFS already patched in this tree, skipping patch step"
else
    SUSFS_PATCH_FILE="${SUSFS_SRC}/Patches/Patch/susfs_patch_to_${KERNEL_VERSION}.patch"

    if [ ! -f "$SUSFS_PATCH_FILE" ]; then
        die "$SUSFS_PATCH_FILE not found in pinned SuSFS source — check that susfs_patch_to_${KERNEL_VERSION}.patch exists at this pinned commit."
    fi

    log "Applying SuSFS patch"
    set +e
    patch -p1 --fuzz=3 < "$SUSFS_PATCH_FILE"
    PATCH_RC=$?
    set -e
    if [ "$PATCH_RC" -gt 1 ]; then
        die "patch exited with code $PATCH_RC — not a hunk rejection but a fatal patch error (malformed patch, unreadable target file). Check $SUSFS_PATCH_FILE."
    fi
    
    # A reject is ignored only if it is whitespace-only
    ws_only() {
        awk '
            /^--- / || /^\+\+\+ / || /^@@/ { next }
            /^-/ { s = substr($0, 2); gsub(/[[:space:]]/, "", s); m[++nm] = s; next }
            /^\+/ { s = substr($0, 2); gsub(/[[:space:]]/, "", s); p[++np] = s; next }
            END {
                if (nm == 0 || nm != np) exit 1
                for (i = 1; i <= nm; i++) if (m[i] != p[i]) exit 1
            }' "$1"
    }

    REAL_REJ=()
    while IFS= read -r -d '' rej; do
        if ws_only "$rej"; then
            log "Whitespace-only reject ignored: $rej"
            rm -f -- "$rej"
        else
            REAL_REJ+=("$rej")
        fi
    done < <(find . -path ./.zincore_deps -prune -o -name '*.rej' -print0 2>/dev/null)

    if [ "${#REAL_REJ[@]}" -gt 0 ]; then
        warn "SuSFS patch produced real rejected hunks:"
        for r in "${REAL_REJ[@]}"; do warn "  $r"; done
        die "These must be resolved manually against this kernel tree before a KSU build can be trusted."
    fi
    log "SuSFS patch applied cleanly (no real rejects)"
fi

# Manual hook script
log "Applying SuSFS manual hook patches"
bash "${SUSFS_SRC}/Patches/susfs_inline_hook_patches.sh" | tee /tmp/zincore_susfs_hook.log
grep -o "Current susfs patch version:[0-9.]*" /tmp/zincore_susfs_hook.log | head -1 | sed 's/Current susfs patch version://' > "${WORKDIR}/${DEVICE}-susfs-version.txt" || true
[ -s "${WORKDIR}/${DEVICE}-susfs-version.txt" ] || die "SuSFS hook script ran but no patch version was found in /tmp/zincore_susfs_hook.log, the version grep may be out of date"

# 核心符号与桩函数导出（彻底解决链接器未定义符号报错）
log "Injecting missing glue symbols and stub implementations"

# 1. 还原并清理 fs/read_write.c 中可能残留的代码
git checkout -- "fs/read_write.c" 2>/dev/null || true
sed -i '/ksu_is_init_rc_hook_enabled/d' "fs/read_write.c" 2>/dev/null || true

# 2. 清理之前可能残留的脏配置与目录
sed -i '/fs\/susfs\/Kconfig/d' "fs/Kconfig" 2>/dev/null || true
rm -rf "fs/susfs"

# 3. 补齐链接器报错所需的所有符号实现
cat << 'EOF' > fs/ksu_susfs_fix.c
#include <linux/jump_label.h>
#include <linux/export.h>
#include <linux/types.h>
#include <linux/fs.h>

/* Jump label keys */
struct static_key_true ksu_is_init_rc_hook_enabled = STATIC_KEY_TRUE_INIT;
EXPORT_SYMBOL(ksu_is_init_rc_hook_enabled);

struct static_key_false ksu_is_input_hook_enabled = STATIC_KEY_FALSE_INIT;
EXPORT_SYMBOL(ksu_is_input_hook_enabled);

/* SuSFS SELinux domain SIDs */
u32 susfs_ksu_sid = 0;
EXPORT_SYMBOL(susfs_ksu_sid);

u32 susfs_priv_app_sid = 0;
EXPORT_SYMBOL(susfs_priv_app_sid);

bool susfs_is_current_ksu_domain(void) {
    return false;
}
EXPORT_SYMBOL(susfs_is_current_ksu_domain);

/* KernelSU VFS / Exec hooks */
int __attribute__((weak)) ksu_handle_vfs_fstat(int fd, struct kstat *stat) {
    return 0;
}
EXPORT_SYMBOL(ksu_handle_vfs_fstat);

int __attribute__((weak)) ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) {
    return 0;
}
EXPORT_SYMBOL(ksu_handle_post_execveat_sucompat);
EOF

# 4. 将独立辅助源文件注册进 fs/Makefile
if ! grep -q "ksu_susfs_fix.o" "fs/Makefile" 2>/dev/null; then
    echo "obj-y += ksu_susfs_fix.o" >> fs/Makefile
fi

# 5. 确保 fs/Makefile 强制编译 susfs.o 为内置对象
if [ -f "fs/susfs.c" ]; then
    sed -i '/susfs\.o/d' "fs/Makefile" 2>/dev/null || true
    echo "obj-y += susfs.o" >> fs/Makefile
    log "Registered susfs.o as built-in (obj-y) to fs/Makefile"
fi

# 6. 全局头文件硬编码激活 SuSFS 特性宏定义
if [ -f "include/linux/susfs.h" ]; then
    sed -i '1i #ifndef CONFIG_KSU_SUSFS\n#define CONFIG_KSU_SUSFS 1\n#endif' include/linux/susfs.h
    sed -i '1i #ifndef CONFIG_KSU_SUSFS_SUS_PATH\n#define CONFIG_KSU_SUSFS_SUS_PATH 1\n#endif' include/linux/susfs.h
    sed -i '1i #ifndef CONFIG_KSU_SUSFS_SUS_MOUNT\n#define CONFIG_KSU_SUSFS_SUS_MOUNT 1\n#endif' include/linux/susfs.h
    sed -i '1i #ifndef CONFIG_KSU_SUSFS_SUS_KSTAT\n#define CONFIG_KSU_SUSFS_SUS_KSTAT 1\n#endif' include/linux/susfs.h
    log "Injected SuSFS macro definitions into include/linux/susfs.h"
fi

# Core config fragment (structural — merged into out/.config by compile.sh)
log "Patching static symbol exports required by KernelSU-Next"

UNSTATIC_APPLIED=0
UNSTATIC_TOTAL=0

unstatic() {
    local file="$1" regex="$2"
    UNSTATIC_TOTAL=$((UNSTATIC_TOTAL + 1))

    if [ ! -f "$file" ]; then
        warn "unstatic: $file not found in this tree — skipping '$regex' (expected if this kernel's source layout differs)"
        return
    fi

    if grep -q "static $regex" "$file" 2>/dev/null; then
        sed -i "s/static $regex/$regex/" "$file"
        log "  exported: $regex ($file)"
        UNSTATIC_APPLIED=$((UNSTATIC_APPLIED + 1))
    else
        warn "  not found as 'static $regex' in $file — already non-static, or this kernel tree's SELinux code differs from what this pattern expects"
    fi
}

unstatic "security/selinux/selinuxfs.c" "ssize_t (\*write_op\[\])"
unstatic "security/selinux/selinuxfs.c" "const struct file_operations sel_handle_status_ops"
unstatic "security/selinux/selinuxfs.c" "DEFINE_MUTEX(sel_mutex);"
unstatic "security/selinux/ss/services.c" "struct page \*selinux_status_page;"
unstatic "security/selinux/ss/services.c" "DEFINE_MUTEX(selinux_status_lock);"
unstatic "security/selinux/ss/services.c" "DEFINE_RWLOCK(policy_rwlock);"
unstatic "security/selinux/hooks.c" "struct security_operations selinux_ops"
unstatic "security/selinux/ss/services.c" "void security_dump_masked_av("
unstatic "security/selinux/ss/services.c" "void context_struct_compute_av("

log "Static-symbol export summary: ${UNSTATIC_APPLIED}/${UNSTATIC_TOTAL} applied"

if [ "$UNSTATIC_APPLIED" -lt "$UNSTATIC_TOTAL" ]; then
    warn "$((UNSTATIC_TOTAL - UNSTATIC_APPLIED)) pattern(s) above were NOT applied — this is expected if they're already non-static in this tree, but if this is a NEW kernel source (different repo/version than previously verified), manually confirm KernelSU-Next actually has the symbol access it needs before trusting this build."
fi

# 直接注入设备原厂 defconfig，确保内核初次 make defconfig 即携带完整功能
DEFCONFIG_FILE="arch/arm64/configs/vendor/wayne_defconfig"
log "Directly injecting KSU & dependencies into $DEFCONFIG_FILE"
if [ -f "$DEFCONFIG_FILE" ]; then
    sed -i '/CONFIG_KSU/d' "$DEFCONFIG_FILE"
    sed -i '/CONFIG_KPROBES/d' "$DEFCONFIG_FILE"
    sed -i '/CONFIG_HAVE_KPROBES/d' "$DEFCONFIG_FILE"
    sed -i '/CONFIG_KPROBE_EVENTS/d' "$DEFCONFIG_FILE"
    sed -i '/CONFIG_FTRACE/d' "$DEFCONFIG_FILE"
    sed -i '/CONFIG_FTRACE_SYSCALLS/d' "$DEFCONFIG_FILE"

    cat << 'EOF' >> "$DEFCONFIG_FILE"
CONFIG_KPROBES=y
CONFIG_HAVE_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_FTRACE=y
CONFIG_FTRACE_SYSCALLS=y
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
fi

# 写入 fragment 文件用于兜底合并
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KPROBES"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_HAVE_KPROBES"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KPROBE_EVENTS"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_FTRACE"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_FTRACE_SYSCALLS"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_SUS_PATH"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_SUS_MOUNT"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_SUS_KSTAT"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_SPOOF_UNAME"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_ENABLE_LOG"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_OPEN_REDIRECT"
fragment_add "$FRAGMENT_FILE" "-e CONFIG_KSU_SUSFS_SUS_MAP"

# THREAD_INFO_IN_TASK 条件依赖检查
if grep -q "THREAD_INFO_IN_TASK" "drivers/kernelsu/Kconfig" 2>/dev/null || grep -q "THREAD_INFO_IN_TASK" "KernelSU/kernel/Kconfig" 2>/dev/null; then
    fragment_add "$FRAGMENT_FILE" "-e CONFIG_THREAD_INFO_IN_TASK"
    log "THREAD_INFO_IN_TASK required by this KernelSU Kconfig, added"
fi

log "Fragment written: $FRAGMENT_FILE"
cat "$FRAGMENT_FILE"
