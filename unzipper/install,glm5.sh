#!/bin/bash
#===============================================================================
# 🚀 极客私有云：全自动解压与沉浸式阅读引擎 - 一键安装脚本
# 
# 功能：在 Ubuntu 系统上构建高度自动化的文件处理中枢
# - 监听并自动解压常见压缩包（含分卷）
# - 基于文件名正则提取密码并建立本地密码学习库
# - 自动侦测并转换 GBK/BIG5 编码的 TXT 小说为 UTF-8 格式 Markdown
# - 解压后原包"阅后即焚"
# - FileBrowser 和 Samba 提供全平台无缝阅读
#
# 适用系统：Ubuntu 20.04+ / Debian 11+
# 执行方式：sudo bash install.sh
#===============================================================================

set -e  # 遇错即停（部分命令允许失败）

#===============================================================================
# 颜色定义与输出函数
#===============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# 状态图标
CHECK="✅"
CROSS="❌"
ARROW="➜"
GEAR="⚙️"
FOLDER="📁"
GLOBE="🌐"
LOCK="🔒"

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "\n${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; 
                echo -e "${CYAN}${ARROW} $1${NC}"; }
log_success() { echo -e "${GREEN}${CHECK} $1${NC}"; }
log_fail()    { echo -e "${RED}${CROSS} $1${NC}"; }

#===============================================================================
# 全局配置变量
#===============================================================================
# 根工作目录
WORK_DIR="/opt/web-unzipper"
DATA_DIR="${WORK_DIR}/data"
BUFFER_DIR="${WORK_DIR}/buffer"

# 文件路径
PYTHON_SCRIPT="${WORK_DIR}/auto_extractor.py"
PWD_FILE="${DATA_DIR}/passwords.txt"
BACKUP_FILE="${WORK_DIR}/passwords_backup.txt"
LOG_FILE="${WORK_DIR}/extractor.log"
FB_DB="${WORK_DIR}/filebrowser.db"

# 服务名称
EXTRACTOR_SERVICE="auto-extractor"
FILEBROWSER_SERVICE="filebrowser"

# FileBrowser 配置
FB_PORT=8080
FB_ADMIN_USER="admin"
FB_ADMIN_PASS="admin123"
FB_READER_USER="reader"
FB_READER_PASS="reader123"

# FileBrowser 下载地址（x86_64 架构）
FILEBROWSER_URL="https://github.com/filebrowser/filebrowser/releases/download/v2.31.2/linux-amd64-filebrowser.tar.gz"

# 生命周期参数
MAX_RETENTION_DAYS=7

#===============================================================================
# 前置检查
#===============================================================================
preflight_check() {
    log_step "执行前置检查"
    
    # 检查是否以 root 运行
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本必须以 root 权限运行！"
        log_info "请使用: sudo bash install.sh"
        exit 1
    fi
    log_success "Root 权限检查通过"
    
    # 检测系统类型
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        log_info "检测到系统: ${PRETTY_NAME:-$ID}"
    else
        log_warn "无法检测系统类型，假设为 Debian/Ubuntu 兼容系统"
    fi
    
    # 检测系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64|amd64)
            FB_ARCH="linux-amd64"
            log_success "系统架构: x86_64"
            ;;
        aarch64|arm64)
            FB_ARCH="linux-arm64"
            FILEBROWSER_URL="https://github.com/filebrowser/filebrowser/releases/download/v2.31.2/linux-arm64-filebrowser.tar.gz"
            log_success "系统架构: ARM64"
            ;;
        *)
            log_error "不支持的系统架构: $ARCH"
            exit 1
            ;;
    esac
    
    # 获取实际登录用户（非 root）
    REAL_USER=${SUDO_USER:-$USER}
    REAL_USER_HOME=$(eval echo ~$REAL_USER)
    log_info "实际用户: ${REAL_USER}"
}

#===============================================================================
# 第一步：安装系统依赖
#===============================================================================
install_dependencies() {
    log_step "安装系统依赖包"
    
    log_info "更新软件包索引..."
    apt-get update -qq
    
    # 必需依赖列表
    DEPS=(
        python3          # Python 运行时
        p7zip-full       # 7z 解压核心
        lsof             # 文件占用检测
        samba            # 局域网共享
        samba-common-bin # Samba 工具
        curl             # 下载工具
        wget             # 备用下载
        tar              # 解压工具
    )
    
    log_info "安装依赖包: ${DEPS[*]}"
    apt-get install -y -qq "${DEPS[@]}"
    
    log_success "系统依赖安装完成"
    
    # 验证关键工具
    command -v python3 >/dev/null 2>&1 || { log_fail "python3 安装失败"; exit 1; }
    command -v 7z >/dev/null 2>&1 || { log_fail "7z 安装失败"; exit 1; }
    command -v lsof >/dev/null 2>&1 || { log_fail "lsof 安装失败"; exit 1; }
    
    log_success "关键工具验证通过"
}

#===============================================================================
# 第二步：创建目录结构
#===============================================================================
create_directories() {
    log_step "创建目录结构"
    
    # 创建主工作目录
    mkdir -p "${WORK_DIR}"
    log_info "创建: ${WORK_DIR}"
    
    # 创建数据目录（主数据盘）
    mkdir -p "${DATA_DIR}"
    log_info "创建: ${DATA_DIR}"
    
    # 创建缓冲目录（傲腾高速缓冲盘）
    mkdir -p "${BUFFER_DIR}"
    log_info "创建: ${BUFFER_DIR}"
    
    # 设置目录权限
    chown -R ${REAL_USER}:${REAL_USER} "${WORK_DIR}"
    chmod -R 755 "${WORK_DIR}"
    
    log_success "目录结构创建完成"
    log_info "目录权限已设置为: ${REAL_USER}:${REAL_USER}"
}

#===============================================================================
# 第三步：写入 Python 守护进程脚本
#===============================================================================
write_python_script() {
    log_step "写入 Python 守护进程脚本"
    
    cat > "${PYTHON_SCRIPT}" << 'PYTHON_EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
🚀 极客私有云：全自动解压与沉浸式阅读引擎
守护进程 - 自动监控解压、编码转换、密码学习

功能特性：
- 防传输中断（文件稳定度检测）
- 智能提取文件名密码（正则提取 @xxx、[xxx] 格式）
- 全局 GBK/BIG5 到 UTF-8 转码并升级为 .md
- 解压成功后强行物理删除原压缩包（阅后即焚）
- 自动清理过期文件和磁盘空间管理
"""

import os
import time
import subprocess
import re
import shutil
import logging
from logging.handlers import RotatingFileHandler
from concurrent.futures import ProcessPoolExecutor

#===============================================================================
# 全局配置
#===============================================================================
DATA_DIR = "/opt/web-unzipper/data"
BUFFER_DIR = "/opt/web-unzipper/buffer"
PWD_FILE = os.path.join(DATA_DIR, "passwords.txt")
BACKUP_FILE = "/opt/web-unzipper/passwords_backup.txt"
LOG_FILE = "/opt/web-unzipper/extractor.log"

# 性能与生命周期参数
MAX_WORKERS = 4                 # 并行解压工作进程数
MAX_RETENTION_DAYS = 7          # 文件最大保留天数
MAX_DISK_USAGE_PERCENT = 85     # 磁盘使用率告警阈值
TARGET_DISK_USAGE_PERCENT = 75  # 清理目标磁盘使用率

#===============================================================================
# 日志系统初始化
#===============================================================================
logger = logging.getLogger("Extractor")
logger.setLevel(logging.INFO)

# 避免重复添加 handler（脚本重载场景）
if not logger.handlers:
    handler = RotatingFileHandler(
        LOG_FILE, 
        maxBytes=10*1024*1024,  # 10MB
        backupCount=1, 
        encoding='utf-8'
    )
    formatter = logging.Formatter(
        '%(asctime)s [%(levelname)s] %(message)s', 
        datefmt='%Y-%m-%d %H:%M:%S'
    )
    handler.setFormatter(formatter)
    logger.addHandler(handler)

#===============================================================================
# 密码管理模块
#===============================================================================
def get_passwords():
    """读取密码字典，返回密码列表（空密码优先）"""
    if not os.path.exists(PWD_FILE):
        return [""]
    try:
        with open(PWD_FILE, 'r', encoding='utf-8') as f:
            pwds = f.read().splitlines()
        # 去重并保留顺序，空密码放在最前面
        return [""] + list(dict.fromkeys([p for p in pwds if p.strip()]))
    except Exception as e:
        logger.error(f"读取密码文件失败: {e}")
        return [""]

def auto_learn_password(new_pwd):
    """自动学习新密码并追加到密码字典"""
    if not new_pwd or not new_pwd.strip():
        return
    try:
        # 检查密码是否已存在
        content = ""
        if os.path.exists(PWD_FILE):
            with open(PWD_FILE, 'r', encoding='utf-8') as f:
                content = f.read()
            existing = content.splitlines()
        else:
            existing = []
        
        if new_pwd not in existing:
            with open(PWD_FILE, 'a', encoding='utf-8') as f:
                if content and not content.endswith('\n'):
                    f.write('\n')
                f.write(f"{new_pwd}\n")
            logger.info(f"🔑 学习并保存新密码: {new_pwd}")
    except Exception as e:
        logger.error(f"保存密码失败: {e}")

#===============================================================================
# 文件稳定性检测模块
#===============================================================================
def is_file_stable(filepath):
    """
    检测文件是否稳定（不再被写入）
    使用 lsof 检测文件占用 + 大小变化检测
    """
    if not os.path.exists(filepath):
        return False
    
    # 方法1: 使用 lsof 检测文件是否被其他进程占用
    try:
        result = subprocess.run(
            ['lsof', filepath], 
            stdout=subprocess.PIPE, 
            stderr=subprocess.PIPE
        )
        if result.returncode == 0:
            # 文件被占用，不稳定
            return False
    except Exception:
        pass
    
    # 方法2: 检测文件大小变化
    try:
        s1 = os.path.getsize(filepath)
        time.sleep(2)
        s2 = os.path.getsize(filepath)
        
        # 文件大小稳定且不为空，且修改时间距今超过2秒
        if s1 == s2 and s1 > 0:
            mtime = os.path.getmtime(filepath)
            if (time.time() - mtime) > 2.0:
                return True
    except Exception:
        pass
    
    return False

#===============================================================================
# 压缩包识别模块
#===============================================================================
def is_main_archive(filename):
    """判断是否为主压缩包（排除分卷包的非首个分卷）"""
    lower_f = filename.lower()
    
    # 已解压标记文件，跳过
    if lower_f.endswith('.extracted'):
        return False
    
    # .001 是分卷主包
    if re.search(r'\.(zip|7z|rar|tar)\.001$', lower_f):
        return True
    
    # 其他数字分卷（.002, .003 等）不是主包
    if re.search(r'\.(zip|7z|rar|tar)\.\d+$', lower_f):
        return False
    
    # .part01.rar 或 .part1.rar 是分卷主包
    if re.search(r'\.part0*1\.rar$', lower_f):
        return True
    
    # 其他 part 分卷不是主包
    if re.search(r'\.part\d+\.rar$', lower_f):
        return False
    
    # 标准压缩格式（先检查复合扩展名，再检查简单扩展名）
    if lower_f.endswith(('.tar.gz', '.tgz')):
        return True
    if lower_f.endswith(('.zip', '.rar', '.7z', '.tar', '.gz')):
        return True
    
    return False

def get_archive_parts(filepath):
    """获取压缩包的所有分卷文件列表"""
    dir_name = os.path.dirname(filepath)
    filename = os.path.basename(filepath)
    parts = [filepath]
    
    # 处理 .001, .002 格式分卷
    if re.search(r'\.\d{3}$', filename):
        base = filename[:-4]  # 去掉后4位（如 .001）
        for f in os.listdir(dir_name):
            suffix = f[len(base)+1:] if f.startswith(base + '.') else ""
            if f != filename and f.startswith(base + '.') and suffix.isdigit():
                parts.append(os.path.join(dir_name, f))
    
    # 处理 .part01.rar 格式分卷
    elif re.search(r'\.part0*1\.rar$', filename, re.IGNORECASE):
        base = re.sub(r'\.part0*1\.rar$', '', filename, flags=re.IGNORECASE)
        for f in os.listdir(dir_name):
            if f != filename and re.search(rf'^{re.escape(base)}\.part\d+\.rar$', f, re.IGNORECASE):
                parts.append(os.path.join(dir_name, f))
    
    # 处理 .rar + .r01, .r02 格式分卷
    elif filename.lower().endswith('.rar'):
        base = filename[:-4]
        for f in os.listdir(dir_name):
            if f != filename and re.search(rf'^{re.escape(base)}\.r\d+$', f, re.IGNORECASE):
                parts.append(os.path.join(dir_name, f))
    
    return parts

def get_stable_archives():
    """扫描并返回所有稳定的待处理压缩包"""
    stable_files = []
    for root, dirs, files in os.walk(DATA_DIR):
        for f in files:
            if is_main_archive(f):
                filepath = os.path.join(root, f)
                parts = get_archive_parts(filepath)
                # 所有分卷都必须稳定
                if all(is_file_stable(p) for p in parts):
                    stable_files.append(filepath)
    return stable_files

#===============================================================================
# 密码提取模块
#===============================================================================
def extract_potential_pwds_from_filename(filename):
    """从文件名中提取可能的密码"""
    pwds = set()
    
    # 匹配 "密码:xxx" "解压码:xxx" "提取码:xxx" 格式
    # 注意: 不包含 '.' 以避免匹配文件扩展名
    pwds.update(re.findall(
        r'(?:密码|解压码|提取码)\s*[:：\s]*([a-zA-Z0-9_@#!\*\-]+)', 
        filename
    ))
    
    # 匹配括号内的内容
    for bracket_content in re.findall(r'[\(（\[【\{](.*?)[\)）\]】\}]', filename):
        # 清理括号内的密码前缀
        clean = re.sub(r'^(?:密码|解压码|提取码)\s*[:：\s]*', '', bracket_content).strip()
        if clean and len(clean) < 50:
            pwds.add(clean)
    
    # 匹配 @xxx 格式（文件名末尾的密码标记）
    at_match = re.search(r'@([^@\.]+)(?=\.[a-zA-Z0-9]+$)', filename)
    if at_match:
        pwds.add(at_match.group(1))
    
    return list(pwds)

#===============================================================================
# 编码转换模块
#===============================================================================
def convert_txt_to_md(directory):
    """
    将目录下所有 TXT 文件转换为 UTF-8 编码的 Markdown 文件
    自动检测 GB18030、BIG5、UTF-8 编码
    """
    protected_files = {'passwords.txt', 'passwords_backup.txt'}
    
    for root, dirs, files in os.walk(directory):
        for file in files:
            if file.lower().endswith('.txt') and file not in protected_files:
                old_path = os.path.join(root, file)
                new_file = os.path.splitext(file)[0] + '.md'
                new_path = os.path.join(root, new_file)
                
                # 跳过已存在的 .md 文件
                if os.path.exists(new_path):
                    continue
                
                content = None
                detected_encoding = None
                
                # 尝试多种编码读取
                for enc in ['utf-8', 'gb18030', 'big5', 'gbk']:
                    try:
                        with open(old_path, 'r', encoding=enc) as f:
                            content = f.read()
                        detected_encoding = enc
                        break
                    except UnicodeDecodeError:
                        continue
                
                if content is not None:
                    try:
                        with open(new_path, 'w', encoding='utf-8') as f:
                            f.write(content)
                        os.remove(old_path)
                        logger.info(f"📄 编码转换: {file} ({detected_encoding}) -> {new_file} (utf-8)")
                    except Exception as e:
                        logger.error(f"编码转换失败 [{file}]: {e}")

#===============================================================================
# 核心解压模块
#===============================================================================
def try_extract(filepath):
    """
    尝试解压压缩包
    返回: (成功标志, 文件路径)
    """
    passwords = get_passwords()
    filename = os.path.basename(filepath)
    
    # 从文件名提取可能的密码，优先尝试
    filename_pwds = extract_potential_pwds_from_filename(filename)
    for sp in filename_pwds:
        if sp not in passwords:
            passwords.insert(0, sp)
    
    # 计算输出目录名
    base_name = filename
    
    # 去除分卷后缀
    if re.search(r'\.\d{3}$', base_name):
        base_name = base_name[:-4]
    if re.search(r'\.part\d+\.rar$', base_name, re.IGNORECASE):
        base_name = re.sub(r'\.part\d+\.rar$', '', base_name, flags=re.IGNORECASE)
    else:
        base_name = os.path.splitext(base_name)[0]
    
    # 清理文件名中的密码标记
    clean_name = re.sub(r'@[^@]+$', '', base_name)
    clean_name = re.sub(r'[\(（\[【\{].*?(密码|解压码).*?[\)）\]】\}]', '', clean_name).strip()
    clean_name = clean_name.strip('_- ')
    
    if not clean_name:
        clean_name = "extracted_" + str(int(time.time()))
    
    base_dir = os.path.dirname(filepath)
    final_out_dir = os.path.join(base_dir, clean_name)
    buffer_out_dir = os.path.join(BUFFER_DIR, clean_name)
    
    # 目标目录已存在，跳过
    if os.path.exists(final_out_dir):
        return False, filepath
    
    os.makedirs(buffer_out_dir, exist_ok=True)
    
    success = False
    successful_pwd = ""
    
    # 尝试所有密码
    for pwd in passwords:
        cmd = [
            '7z', 'x', 
            filepath, 
            f'-p{pwd}', 
            f'-o{buffer_out_dir}', 
            '-y', 
            '-mmt=on'
        ]
        
        result = subprocess.run(
            cmd, 
            stdout=subprocess.DEVNULL, 
            stderr=subprocess.DEVNULL
        )
        
        if result.returncode == 0:
            success = True
            successful_pwd = pwd
            break
    
    if success:
        # 删除所有分卷（阅后即焚）
        parts = get_archive_parts(filepath)
        for part in parts:
            try:
                os.remove(part)
                logger.info(f"🔥 已删除压缩包: {os.path.basename(part)}")
            except Exception as e:
                logger.error(f"删除压缩包失败 [{part}]: {e}")
        
        # 学习成功密码
        if successful_pwd:
            auto_learn_password(successful_pwd)
        
        # 编码转换
        convert_txt_to_md(buffer_out_dir)
        
        # 移动到最终目录
        try:
            shutil.move(buffer_out_dir, final_out_dir)
            logger.info(f"✅ 解压完成: {filename} -> {clean_name}/")
        except Exception as e:
            logger.error(f"移动目录失败: {e}")
            # 尝试复制
            try:
                shutil.copytree(buffer_out_dir, final_out_dir)
                shutil.rmtree(buffer_out_dir)
            except Exception:
                pass
        
        return True, filepath
    else:
        # 解压失败，清理缓冲目录
        try:
            shutil.rmtree(buffer_out_dir)
        except Exception:
            pass
        logger.warning(f"⚠️ 解压失败（密码错误或文件损坏）: {filename}")
        return False, filepath

#===============================================================================
# 生命周期管理模块
#===============================================================================
def run_lifecycle_management():
    """执行文件生命周期管理和磁盘空间清理"""
    now = time.time()
    protected = {'passwords.txt', 'passwords_backup.txt'}
    
    # 1. 清理过期文件
    for f in os.listdir(DATA_DIR):
        if f in protected:
            continue
        full_path = os.path.join(DATA_DIR, f)
        try:
            mtime = os.path.getmtime(full_path)
            if (now - mtime) > (MAX_RETENTION_DAYS * 86400):
                if os.path.isfile(full_path):
                    os.remove(full_path)
                else:
                    shutil.rmtree(full_path)
                logger.info(f"🗑️ 已清理过期文件: {f}")
        except Exception:
            pass
    
    # 2. 磁盘空间管理
    try:
        total, used, free = shutil.disk_usage(DATA_DIR)
        current_percent = (used / total) * 100
        
        if current_percent > MAX_DISK_USAGE_PERCENT:
            logger.warning(f"⚠️ 磁盘使用率过高: {current_percent:.1f}%")
            
            # 按修改时间排序，清理最旧的文件
            items = []
            for item in os.listdir(DATA_DIR):
                if item in protected:
                    continue
                p = os.path.join(DATA_DIR, item)
                try:
                    items.append((p, os.path.getmtime(p)))
                except Exception:
                    pass
            
            items.sort(key=lambda x: x[1])  # 按时间升序
            
            for item_path, _ in items:
                try:
                    if os.path.isfile(item_path):
                        os.remove(item_path)
                    else:
                        shutil.rmtree(item_path)
                    logger.info(f"🗑️ 磁盘空间清理: {os.path.basename(item_path)}")
                    
                    # 检查是否达到目标
                    current_used = shutil.disk_usage(DATA_DIR).used
                    if (current_used / total) * 100 <= TARGET_DISK_USAGE_PERCENT:
                        break
                except Exception:
                    pass
    except Exception as e:
        logger.error(f"磁盘空间管理失败: {e}")

#===============================================================================
# 主程序入口
#===============================================================================
def main():
    logger.info("="*60)
    logger.info("🚀 极客私有云解压引擎启动")
    logger.info(f"   数据目录: {DATA_DIR}")
    logger.info(f"   缓冲目录: {BUFFER_DIR}")
    logger.info("="*60)
    
    last_pwd_mtime = 0
    last_cleanup_time = 0
    failed_files = set()
    
    # 初始化密码文件
    if not os.path.exists(PWD_FILE) and not os.path.exists(BACKUP_FILE):
        open(PWD_FILE, 'w').close()
        logger.info("已创建空密码字典文件")
    
    # 开机自检：对现有目录执行编码转换
    convert_txt_to_md(DATA_DIR)
    
    with ProcessPoolExecutor(max_workers=MAX_WORKERS) as executor:
        while True:
            try:
                # 定期执行生命周期管理
                if time.time() - last_cleanup_time > 300:  # 每5分钟
                    run_lifecycle_management()
                    last_cleanup_time = time.time()
                
                # 密码文件恢复（防止误删）
                if not os.path.exists(PWD_FILE) and os.path.exists(BACKUP_FILE):
                    shutil.copy2(BACKUP_FILE, PWD_FILE)
                    logger.info("已从备份恢复密码字典")
                
                # 密码文件变更检测
                cur_mtime = os.path.getmtime(PWD_FILE) if os.path.exists(PWD_FILE) else 0
                if cur_mtime > last_pwd_mtime:
                    if os.path.exists(PWD_FILE):
                        shutil.copy2(PWD_FILE, BACKUP_FILE)
                    failed_files.clear()  # 密码更新后重试失败的文件
                    last_pwd_mtime = cur_mtime
                
                # 扫描稳定的压缩包
                pending_tasks = [f for f in get_stable_archives() if f not in failed_files]
                
                if pending_tasks:
                    logger.info(f"📦 发现 {len(pending_tasks)} 个待处理压缩包")
                    results = list(executor.map(try_extract, pending_tasks))
                    
                    for success, path in results:
                        if not success:
                            failed_files.add(path)
                
                # 清理不存在的失败记录
                failed_files.intersection_update(set(get_stable_archives()))
                
            except Exception as e:
                logger.error(f"主循环异常: {e}")
            
            time.sleep(3)  # 主循环间隔

if __name__ == "__main__":
    main()
PYTHON_EOF

    # 设置文件权限
    chmod +x "${PYTHON_SCRIPT}"
    chown ${REAL_USER}:${REAL_USER} "${PYTHON_SCRIPT}"
    
    log_success "Python 守护进程脚本已写入: ${PYTHON_SCRIPT}"
}

#===============================================================================
# 第四步：创建初始密码字典
#===============================================================================
create_password_file() {
    log_step "创建初始密码字典"
    
    # 创建空密码字典
    if [[ ! -f "${PWD_FILE}" ]]; then
        touch "${PWD_FILE}"
        chown ${REAL_USER}:${REAL_USER} "${PWD_FILE}"
        log_success "已创建空密码字典: ${PWD_FILE}"
    else
        log_info "密码字典已存在，跳过创建"
    fi
    
    # 创建备份文件
    if [[ ! -f "${BACKUP_FILE}" ]]; then
        touch "${BACKUP_FILE}"
        chown ${REAL_USER}:${REAL_USER} "${BACKUP_FILE}"
        log_success "已创建密码备份文件: ${BACKUP_FILE}"
    fi
}

#===============================================================================
# 第五步：下载并配置 FileBrowser
#===============================================================================
setup_filebrowser() {
    log_step "下载并配置 FileBrowser"
    
    local FB_BIN="/usr/local/bin/filebrowser"
    
    # 检查是否已安装
    if command -v filebrowser &>/dev/null; then
        log_info "FileBrowser 已安装，检查版本..."
        filebrowser version || true
    else
        log_info "正在下载 FileBrowser..."
        
        # 创建临时目录
        local TMP_DIR=$(mktemp -d)
        local TMP_FILE="${TMP_DIR}/filebrowser.tar.gz"
        
        # 下载
        if curl -fsSL "${FILEBROWSER_URL}" -o "${TMP_FILE}"; then
            log_success "FileBrowser 下载完成"
        else
            log_error "FileBrowser 下载失败，请检查网络连接"
            log_info "下载地址: ${FILEBROWSER_URL}"
            exit 1
        fi
        
        # 解压
        tar -xzf "${TMP_FILE}" -C "${TMP_DIR}"
        
        # 安装
        mv "${TMP_DIR}/filebrowser" "${FB_BIN}"
        chmod +x "${FB_BIN}"
        
        # 清理临时文件
        rm -rf "${TMP_DIR}"
        
        log_success "FileBrowser 安装完成"
    fi
    
    # 初始化数据库配置
    log_info "初始化 FileBrowser 数据库..."
    
    # 删除旧数据库（重新配置）
    rm -f "${FB_DB}"
    
    # 配置初始化
    filebrowser config init \
        -a "0.0.0.0" \
        -p ${FB_PORT} \
        -d "${FB_DB}" \
        -r "${DATA_DIR}"
    
    # 设置管理员账户
    filebrowser users add ${FB_ADMIN_USER} ${FB_ADMIN_PASS} \
        --perm.admin \
        -d "${FB_DB}"
    
    # 创建只读阅读账户
    filebrowser users add ${FB_READER_USER} ${FB_READER_PASS} \
        --perm.download=true \
        --perm.modify=false \
        --perm.delete=false \
        --perm.create=false \
        --perm.rename=false \
        --perm.copy=false \
        -d "${FB_DB}"
    
    # 设置数据库权限
    chown ${REAL_USER}:${REAL_USER} "${FB_DB}"
    
    log_success "FileBrowser 配置完成"
    log_info "管理员账户: ${FB_ADMIN_USER} / ${FB_ADMIN_PASS}"
    log_info "阅读账户: ${FB_READER_USER} / ${FB_READER_PASS}（只读，适合 PWA 沉浸阅读）"
}

#===============================================================================
# 第六步：配置 Systemd 服务
#===============================================================================
setup_systemd_services() {
    log_step "配置 Systemd 服务"
    
    # -------------------------------------------------------------------------
    # 创建 auto-extractor.service
    # -------------------------------------------------------------------------
    cat > /etc/systemd/system/${EXTRACTOR_SERVICE}.service << EOF
[Unit]
Description=Auto Extractor Daemon - 极客私有云解压引擎
Documentation=https://github.com/web-unzipper
After=network.target

[Service]
Type=simple
User=${REAL_USER}
Group=${REAL_USER}
WorkingDirectory=${WORK_DIR}
ExecStart=/usr/bin/python3 ${PYTHON_SCRIPT}
Restart=always
RestartSec=10
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

# 资源限制
LimitNOFILE=65535
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

    log_success "已创建服务: ${EXTRACTOR_SERVICE}.service"
    
    # -------------------------------------------------------------------------
    # 创建 filebrowser.service
    # -------------------------------------------------------------------------
    cat > /etc/systemd/system/${FILEBROWSER_SERVICE}.service << EOF
[Unit]
Description=FileBrowser - Web 文件管理界面
Documentation=https://filebrowser.org
After=network.target

[Service]
Type=simple
User=${REAL_USER}
Group=${REAL_USER}
WorkingDirectory=${WORK_DIR}
ExecStart=/usr/local/bin/filebrowser -d ${FB_DB}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    log_success "已创建服务: ${FILEBROWSER_SERVICE}.service"
    
    # -------------------------------------------------------------------------
    # 重载 systemd 并启用服务
    # -------------------------------------------------------------------------
    systemctl daemon-reload
    systemctl enable ${EXTRACTOR_SERVICE}
    systemctl enable ${FILEBROWSER_SERVICE}
    
    log_success "Systemd 服务已启用（开机自启）"
}

#===============================================================================
# 第七步：配置 Samba 共享
#===============================================================================
setup_samba() {
    log_step "配置 Samba 局域网共享"
    
    # 备份原配置
    if [[ -f /etc/samba/smb.conf ]]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%Y%m%d%H%M%S)
    fi
    
    # 检查是否已配置
    if grep -q "\[WebUnzipper\]" /etc/samba/smb.conf 2>/dev/null; then
        log_info "Samba 共享已配置，跳过"
    else
        # 追加共享配置
        cat >> /etc/samba/smb.conf << EOF

# ========== 极客私有云解压引擎共享 ==========
[WebUnzipper]
    path = ${DATA_DIR}
    available = yes
    valid users = ${REAL_USER}
    read only = no
    browsable = yes
    public = no
    writable = yes
    create mask = 0644
    directory mask = 0755
    force create mode = 0644
    force directory mode = 0755
EOF
        log_success "Samba 共享配置已添加"
    fi
    
    # 设置目录权限
    chown -R ${REAL_USER}:${REAL_USER} "${DATA_DIR}"
    
    # 重启 Samba 服务
    systemctl restart smbd nmbd 2>/dev/null || true
    systemctl enable smbd nmbd 2>/dev/null || true
    
    log_success "Samba 服务已重启"
}

#===============================================================================
# 第八步：启动所有服务
#===============================================================================
start_services() {
    log_step "启动所有服务"
    
    # 启动 auto-extractor
    systemctl restart ${EXTRACTOR_SERVICE}
    sleep 2
    
    if systemctl is-active --quiet ${EXTRACTOR_SERVICE}; then
        log_success "auto-extractor 服务已启动"
    else
        log_error "auto-extractor 服务启动失败"
        journalctl -u ${EXTRACTOR_SERVICE} --no-pager -n 20
    fi
    
    # 启动 filebrowser
    systemctl restart ${FILEBROWSER_SERVICE}
    sleep 2
    
    if systemctl is-active --quiet ${FILEBROWSER_SERVICE}; then
        log_success "filebrowser 服务已启动"
    else
        log_error "filebrowser 服务启动失败"
        journalctl -u ${FILEBROWSER_SERVICE} --no-pager -n 20
    fi
}

#===============================================================================
# 第九步：显示安装结果
#===============================================================================
show_summary() {
    # 获取服务器 IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    
    echo -e ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}"
    echo -e "  ╔═══════════════════════════════════════════════════════════════╗"
    echo -e "  ║     🚀 极客私有云：全自动解压与沉浸式阅读引擎                  ║"
    echo -e "  ║              安装完成！Installation Complete!                  ║"
    echo -e "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e ""
    echo -e "${CYAN}📁 目录结构：${NC}"
    echo -e "   数据目录:    ${DATA_DIR}"
    echo -e "   缓冲目录:    ${BUFFER_DIR}"
    echo -e "   密码字典:    ${PWD_FILE}"
    echo -e "   运行日志:    ${LOG_FILE}"
    echo -e ""
    echo -e "${CYAN}🌐 Web 访问 (FileBrowser)：${NC}"
    echo -e "   地址:        ${GREEN}http://${SERVER_IP}:${FB_PORT}${NC}"
    echo -e "   管理员:      ${FB_ADMIN_USER} / ${FB_ADMIN_PASS}"
    echo -e "   阅读账户:    ${FB_READER_USER} / ${FB_READER_PASS} ${YELLOW}(只读，适合 PWA)${NC}"
    echo -e ""
    echo -e "${CYAN}🔗 局域网共享 (Samba)：${NC}"
    echo -e "   路径:        ${GREEN}\\\\${SERVER_IP}\\WebUnzipper${NC}"
    echo -e "   用户:        ${REAL_USER}"
    echo -e "   ${YELLOW}⚠️  首次使用请运行: sudo smbpasswd -a ${REAL_USER}${NC}"
    echo -e ""
    echo -e "${CYAN}⚙️  服务管理命令：${NC}"
    echo -e "   查看状态:    systemctl status ${EXTRACTOR_SERVICE}"
    echo -e "   查看日志:    tail -f ${LOG_FILE}"
    echo -e "   重启服务:    systemctl restart ${EXTRACTOR_SERVICE}"
    echo -e "   停止服务:    systemctl stop ${EXTRACTOR_SERVICE}"
    echo -e ""
    echo -e "${CYAN}📝 使用说明：${NC}"
    echo -e "   1. 将压缩包放入 ${DATA_DIR} 目录"
    echo -e "   2. 系统自动检测并解压（支持分卷、密码提取）"
    echo -e "   3. 解压成功后原压缩包自动删除（阅后即焚）"
    echo -e "   4. TXT 文件自动转换为 UTF-8 编码的 Markdown"
    echo -e "   5. 文件保留 ${MAX_RETENTION_DAYS} 天后自动清理"
    echo -e ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${CHECK} 安装完成！享受你的极客私有云吧！${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

#===============================================================================
# 主程序入口
#===============================================================================
main() {
    echo -e ""
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}"
    echo -e "  ╔═══════════════════════════════════════════════════════════════╗"
    echo -e "  ║     🚀 极客私有云：全自动解压与沉浸式阅读引擎                  ║"
    echo -e "  ║                    一键安装脚本 v1.0                           ║"
    echo -e "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${PURPLE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e ""
    
    # 执行安装步骤
    preflight_check
    install_dependencies
    create_directories
    write_python_script
    create_password_file
    setup_filebrowser
    setup_systemd_services
    setup_samba
    start_services
    show_summary
}

# 执行主程序
main "$@"
