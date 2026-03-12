#!/bin/bash

#######################################################################
# 极客私有云：全自动解压与沉浸式阅读引擎 - 一键安装脚本
# 版本: 1.0.0
# 适用系统: Ubuntu 18.04 及以上版本
# 作者: CodeArts Agent
#######################################################################

set -e  # 遇到错误立即退出

# ==================== 全局变量定义 ====================
WORK_DIR="/opt/web-unzipper"
DATA_DIR="${WORK_DIR}/data"
BUFFER_DIR="${WORK_DIR}/buffer"
PYTHON_SCRIPT="${WORK_DIR}/auto_extractor.py"
PWD_FILE="${DATA_DIR}/passwords.txt"
PWD_BACKUP="${WORK_DIR}/passwords_backup.txt"
FB_DB="${WORK_DIR}/filebrowser.db"
LOG_FILE="${WORK_DIR}/extractor.log"
FB_PORT=8080
FB_BIN="/usr/local/bin/filebrowser"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ==================== 工具函数 ====================

# 打印信息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 打印分隔线
print_separator() {
    echo "================================================================"
}

# 检查命令是否存在
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ==================== 阶段 1: 环境检查 ====================

check_os() {
    print_separator
    print_info "阶段 1/8: 环境检查"
    print_separator

    print_info "检查操作系统版本..."

    if [ ! -f /etc/os-release ]; then
        print_error "无法检测操作系统版本"
        exit 1
    fi

    source /etc/os-release

    if [ "$ID" != "ubuntu" ]; then
        print_error "此脚本仅支持 Ubuntu 系统，当前系统: $ID"
        exit 1
    fi

    # 检查版本号
    MAJOR_VERSION=$(echo "$VERSION_ID" | cut -d. -f1)
    if [ "$MAJOR_VERSION" -lt 18 ]; then
        print_error "需要 Ubuntu 18.04 或更高版本，当前版本: $VERSION_ID"
        exit 1
    fi

    print_success "操作系统检查通过: Ubuntu $VERSION_ID"
}

check_root() {
    print_info "检查 root 权限..."

    if [ "$EUID" -ne 0 ]; then
        print_error "此脚本需要 root 权限，请使用 sudo 执行"
        exit 1
    fi

    print_success "Root 权限检查通过"
}

check_network() {
    print_info "检查网络连接..."

    # 尝试 ping Google DNS
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        print_success "网络连接正常"
        return 0
    fi

    # 尝试 ping 国内 DNS
    if ping -c 1 -W 3 114.114.114.114 >/dev/null 2>&1; then
        print_success "网络连接正常"
        return 0
    fi

    # 尝试访问 Ubuntu 软件源
    if curl -s --connect-timeout 5 http://archive.ubuntu.com/ubuntu/ >/dev/null 2>&1; then
        print_success "网络连接正常"
        return 0
    fi

    print_warning "网络连接检测失败，但将继续尝试安装"
}

# ==================== 阶段 2: 依赖安装 ====================

install_dependencies() {
    print_separator
    print_info "阶段 2/8: 依赖安装"
    print_separator

    print_info "更新 apt 缓存..."
    if ! apt update -qq; then
        print_error "apt 缓存更新失败，请检查网络连接或软件源配置"
        exit 1
    fi
    print_success "apt 缓存更新成功"

    print_info "安装系统依赖包..."

    DEPS="p7zip-full lsof samba curl wget"

    for dep in $DEPS; do
        if dpkg -l | grep -q "^ii  $dep"; then
            print_info "$dep 已安装，跳过"
        else
            print_info "正在安装 $dep..."
            if apt install -y -qq "$dep"; then
                print_success "$dep 安装成功"
            else
                print_error "$dep 安装失败"
                exit 1
            fi
        fi
    done

    print_success "所有依赖包安装完成"
}

# ==================== 阶段 3: 目录创建 ====================

create_directories() {
    print_separator
    print_info "阶段 3/8: 目录创建"
    print_separator

    print_info "创建工作目录结构..."

    # 创建根目录
    if [ ! -d "$WORK_DIR" ]; then
        mkdir -p "$WORK_DIR"
        print_success "创建目录: $WORK_DIR"
    else
        print_info "目录已存在: $WORK_DIR"
    fi

    # 创建数据目录
    if [ ! -d "$DATA_DIR" ]; then
        mkdir -p "$DATA_DIR"
        print_success "创建目录: $DATA_DIR"
    else
        print_info "目录已存在: $DATA_DIR"
    fi

    # 创建缓冲目录
    if [ ! -d "$BUFFER_DIR" ]; then
        mkdir -p "$BUFFER_DIR"
        print_success "创建目录: $BUFFER_DIR"
    else
        print_info "目录已存在: $BUFFER_DIR"
    fi

    # 设置权限
    chmod 755 "$WORK_DIR"
    chmod 755 "$DATA_DIR"
    chmod 755 "$BUFFER_DIR"

    print_success "目录结构创建完成"
}

# ==================== 阶段 4: Python 守护进程部署 ====================

deploy_python_daemon() {
    print_separator
    print_info "阶段 4/8: Python 守护进程部署"
    print_separator

    print_info "写入 auto_extractor.py 文件..."

    cat > "$PYTHON_SCRIPT" << 'PYTHON_EOF'
import os, time, subprocess, re, shutil, logging
from logging.handlers import RotatingFileHandler
from concurrent.futures import ProcessPoolExecutor

DATA_DIR = "/opt/web-unzipper/data"
BUFFER_DIR = "/opt/web-unzipper/buffer"
PWD_FILE = os.path.join(DATA_DIR, "passwords.txt")
BACKUP_FILE = "/opt/web-unzipper/passwords_backup.txt"
LOG_FILE = "/opt/web-unzipper/extractor.log"

MAX_WORKERS = 4
MAX_RETENTION_DAYS = 7
MAX_DISK_USAGE_PERCENT = 85
TARGET_DISK_USAGE_PERCENT = 75

logger = logging.getLogger("Extractor")
logger.setLevel(logging.INFO)
handler = RotatingFileHandler(LOG_FILE, maxBytes=10*1024*1024, backupCount=1, encoding='utf-8')
formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
handler.setFormatter(formatter)
logger.addHandler(handler)

def get_passwords():
    if not os.path.exists(PWD_FILE): return [""]
    with open(PWD_FILE, 'r', encoding='utf-8') as f: pwds = f.read().splitlines()
    return [""] + list(dict.fromkeys([p for p in pwds if p.strip()]))

def auto_learn_password(new_pwd):
    if not new_pwd: return
    try:
        with open(PWD_FILE, 'r', encoding='utf-8') as f:
            content = f.read()
            existing = content.splitlines()
        if new_pwd not in existing:
            with open(PWD_FILE, 'a', encoding='utf-8') as f:
                if content and not content.endswith('\n'): f.write('\n')
                f.write(f"{new_pwd}\n")
            logger.info(f"🔑 学习并保存新密码: {new_pwd}")
    except: pass

def is_file_stable(filepath):
    if not os.path.exists(filepath): return False
    try:
        if subprocess.run(['lsof', filepath], stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode == 0: return False
    except: pass
    try:
        s1 = os.path.getsize(filepath)
        time.sleep(2)
        if s1 == os.path.getsize(filepath) and s1 > 0 and (time.time() - os.path.getmtime(filepath)) > 2.0: return True
    except: pass
    return False

def is_main_archive(filename):
    lower_f = filename.lower()
    if lower_f.endswith('.extracted'): return False
    if re.search(r'\.(zip|7z|rar|tar)\.001$', lower_f): return True
    if re.search(r'\.(zip|7z|rar|tar)\.\d+$', lower_f): return False
    if re.search(r'\.part0*1\.rar$', lower_f): return True
    if re.search(r'\.part\d+\.rar$', lower_f): return False
    if lower_f.endswith(('.zip', '.rar', '.7z', '.tar', '.gz')): return True
    return False

def get_archive_parts(filepath):
    dir_name = os.path.dirname(filepath)
    filename = os.path.basename(filepath)
    parts = [filepath]
    if re.search(r'\.\d{3}$', filename):
        base = filename[:-4]
        for f in os.listdir(dir_name):
            if f != filename and f.startswith(base + '.') and f[len(base)+1:].isdigit():
                parts.append(os.path.join(dir_name, f))
    elif re.search(r'\.part0*1\.rar$', filename, re.IGNORECASE):
        base = re.sub(r'\.part0*1\.rar$', '', filename, flags=re.IGNORECASE)
        for f in os.listdir(dir_name):
            if f != filename and re.search(rf'^{re.escape(base)}\.part\d+\.rar$', f, re.IGNORECASE):
                parts.append(os.path.join(dir_name, f))
    elif filename.lower().endswith('.rar'):
        base = filename[:-4]
        for f in os.listdir(dir_name):
            if f != filename and re.search(rf'^{re.escape(base)}\.r\d+$', f, re.IGNORECASE):
                parts.append(os.path.join(dir_name, f))
    return parts

def get_stable_archives():
    stable_files = []
    for root, dirs, files in os.walk(DATA_DIR):
        for f in files:
            if is_main_archive(f):
                filepath = os.path.join(root, f)
                parts = get_archive_parts(filepath)
                if all(is_file_stable(p) for p in parts): stable_files.append(filepath)
    return stable_files

def extract_potential_pwds_from_filename(filename):
    pwds = set()
    pwds.update(re.findall(r'(?:密码|解压码|提取码)\s*[:：\s]*([a-zA-Z0-9_@#!\*\-\.]+)', filename))
    for b in re.findall(r'[\(（\[【\{](.*?)[\)）\]】\}]', filename):
        clean_b = re.sub(r'^(?:密码|解压码|提取码)\s*[:：\s]*', '', b).strip()
        if clean_b and len(clean_b) < 50: pwds.add(clean_b)
    at_match = re.search(r'@([^@\.]+)(?=\.[a-zA-Z0-9]+$)', filename)
    if at_match: pwds.add(at_match.group(1))
    return list(pwds)

def convert_txt_to_md(directory):
    protected_files = {'passwords.txt', 'passwords_backup.txt'}
    for root, dirs, files in os.walk(directory):
        for file in files:
            if file.lower().endswith('.txt') and file not in protected_files:
                old_path = os.path.join(root, file)
                new_file = os.path.splitext(file)[0] + '.md'
                new_path = os.path.join(root, new_file)
                content = None
                for enc in ['utf-8', 'gb18030', 'big5']:
                    try:
                        with open(old_path, 'r', encoding=enc) as f:
                            content = f.read()
                        break
                    except UnicodeDecodeError:
                        continue
                if content is not None:
                    try:
                        with open(new_path, 'w', encoding='utf-8') as f:
                            f.write(content)
                        os.remove(old_path)
                        logger.info(f"📄 编码清洗: {file} -> {new_file}")
                    except: pass

def try_extract(filepath):
    passwords = get_passwords()
    filename = os.path.basename(filepath)
    for sp in extract_potential_pwds_from_filename(filename):
        if sp not in passwords: passwords.insert(0, sp)

    base_name = filename
    if re.search(r'\.\d{3}$', base_name): base_name = base_name[:-4]
    if re.search(r'\.part\d+\.rar$', base_name, re.I): base_name = re.sub(r'\.part\d+\.rar$', '', base_name, flags=re.I)
    else: base_name = os.path.splitext(base_name)[0]

    clean_name = re.sub(r'@[^@]+$', '', base_name)
    clean_name = re.sub(r'[\(（\[【\{].*?(密码|解压码).*?[\)）\]】\}]', '', clean_name).strip()

    base_dir = os.path.dirname(filepath)
    final_out_dir = os.path.join(base_dir, clean_name)
    buffer_out_dir = os.path.join(BUFFER_DIR, clean_name)

    if os.path.exists(final_out_dir): return False, filepath
    os.makedirs(buffer_out_dir, exist_ok=True)

    success, successful_pwd = False, ""
    for pwd in passwords:
        if subprocess.run(['7z', 'x', filepath, f'-p{pwd}', f'-o{buffer_out_dir}', '-y', '-mmt=on'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            success, successful_pwd = True, pwd
            break

    if success:
        parts = get_archive_parts(filepath)
        for part in parts:
            try: os.remove(part) # 阅后即焚
            except: pass
        auto_learn_password(successful_pwd)
        convert_txt_to_md(buffer_out_dir)
        shutil.move(buffer_out_dir, final_out_dir)
        return True, filepath
    else:
        try: shutil.rmtree(buffer_out_dir)
        except: pass
        return False, filepath

def run_lifecycle_management():
    now = time.time()
    for f in os.listdir(DATA_DIR):
        if f in ['passwords.txt', 'passwords_backup.txt']: continue
        full_path = os.path.join(DATA_DIR, f)
        try:
            if (now - os.path.getmtime(full_path)) > (MAX_RETENTION_DAYS * 86400):
                os.remove(full_path) if os.path.isfile(full_path) else shutil.rmtree(full_path)
        except: pass

    try:
        t, u, f = shutil.disk_usage(DATA_DIR)
        current_percent = (u / t) * 100
        if current_percent > MAX_DISK_USAGE_PERCENT:
            items = []
            for item in os.listdir(DATA_DIR):
                if item in ['passwords.txt', 'passwords_backup.txt']: continue
                p = os.path.join(DATA_DIR, item)
                try: items.append((p, os.path.getmtime(p)))
                except: pass
            items.sort(key=lambda x: x[1])
            for item_path, _ in items:
                try: os.remove(item_path) if os.path.isfile(item_path) else shutil.rmtree(item_path)
                except: pass
                if (shutil.disk_usage(DATA_DIR).used / t) * 100 <= TARGET_DISK_USAGE_PERCENT: break
    except: pass

def main():
    last_pwd_mtime, last_cleanup_time = 0, 0
    failed_files = set()
    if not os.path.exists(PWD_FILE) and not os.path.exists(BACKUP_FILE): open(PWD_FILE, 'w').close()
    convert_txt_to_md(DATA_DIR) # 开机自检转码

    with ProcessPoolExecutor(max_workers=MAX_WORKERS) as executor:
        while True:
            try:
                if time.time() - last_cleanup_time > 300:
                    run_lifecycle_management()
                    last_cleanup_time = time.time()
                if not os.path.exists(PWD_FILE) and os.path.exists(BACKUP_FILE): shutil.copy2(BACKUP_FILE, PWD_FILE)
                cur_mtime = os.path.getmtime(PWD_FILE) if os.path.exists(PWD_FILE) else 0
                if cur_mtime > last_pwd_mtime:
                    if os.path.exists(PWD_FILE): shutil.copy2(PWD_FILE, BACKUP_FILE)
                    failed_files.clear()
                    last_pwd_mtime = cur_mtime
                pending_tasks = [f for f in get_stable_archives() if f not in failed_files]
                if pending_tasks:
                    results = list(executor.map(try_extract, pending_tasks))
                    for success, path in results:
                        if not success: failed_files.add(path)
                failed_files.intersection_update(set(get_stable_archives()))
            except: pass
            time.sleep(3)

if __name__ == "__main__":
    main()
PYTHON_EOF

    print_success "Python 守护进程文件写入成功"

    # 验证 Python 语法
    print_info "验证 Python 语法..."
    if python3 -m py_compile "$PYTHON_SCRIPT" 2>/dev/null; then
        print_success "Python 语法验证通过"
    else
        print_error "Python 语法验证失败"
        exit 1
    fi

    # 创建密码文件（如不存在）
    print_info "创建密码文件..."
    if [ ! -f "$PWD_FILE" ]; then
        touch "$PWD_FILE"
        print_success "创建密码文件: $PWD_FILE"
    else
        print_warning "密码文件已存在，保留原文件: $PWD_FILE"
    fi

    # 设置文件权限
    chmod 644 "$PYTHON_SCRIPT"
    chmod 644 "$PWD_FILE"

    print_success "Python 守护进程部署完成"
}

# ==================== 阶段 5: FileBrowser 部署 ====================

deploy_filebrowser() {
    print_separator
    print_info "阶段 5/8: FileBrowser 部署"
    print_separator

    # 下载 FileBrowser
    print_info "下载 FileBrowser 二进制文件..."

    FB_URL="https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz"
    FB_TEMP="/tmp/filebrowser.tar.gz"

    # 尝试下载
    if command_exists curl; then
        if curl -L -o "$FB_TEMP" "$FB_URL" 2>/dev/null; then
            print_success "FileBrowser 下载成功"
        else
            print_error "FileBrowser 下载失败，请检查网络连接"
            exit 1
        fi
    elif command_exists wget; then
        if wget -O "$FB_TEMP" "$FB_URL" 2>/dev/null; then
            print_success "FileBrowser 下载成功"
        else
            print_error "FileBrowser 下载失败，请检查网络连接"
            exit 1
        fi
    else
        print_error "需要 curl 或 wget 来下载文件"
        exit 1
    fi

    # 解压并安装
    print_info "安装 FileBrowser..."
    tar -xzf "$FB_TEMP" -C /tmp/
    mv /tmp/filebrowser "$FB_BIN"
    chmod +x "$FB_BIN"
    rm -f "$FB_TEMP"

    print_success "FileBrowser 安装成功: $FB_BIN"

    # 初始化配置
    print_info "初始化 FileBrowser 配置..."

    # 初始化数据库
    "$FB_BIN" config init \
        -d "$FB_DB" \
        -a "0.0.0.0" \
        -p "$FB_PORT" \
        -r "$DATA_DIR" \
        >/dev/null 2>&1

    print_success "FileBrowser 配置初始化成功"

    # 创建 admin 用户
    print_info "创建 admin 用户..."

    # 生成随机密码
    ADMIN_PASS=$(openssl rand -base64 12)
    READER_PASS=$(openssl rand -base64 12)

    "$FB_BIN" users add admin "$ADMIN_PASS" \
        -d "$FB_DB" \
        --perm.admin \
        >/dev/null 2>&1

    print_success "admin 用户创建成功"

    # 创建 reader 用户
    print_info "创建 reader 用户..."

    "$FB_BIN" users add reader "$READER_PASS" \
        -d "$FB_DB" \
        --perm.download \
        >/dev/null 2>&1

    print_success "reader 用户创建成功"

    # 保存密码到文件
    cat > "${WORK_DIR}/credentials.txt" << EOF
FileBrowser 登录凭据
====================

管理员账户 (admin):
  用户名: admin
  密码: $ADMIN_PASS
  权限: 所有权限

只读账户 (reader):
  用户名: reader
  密码: $READER_PASS
  权限: 仅查看和下载

⚠️  请妥善保管此文件，建议登录后修改密码
EOF

    chmod 600 "${WORK_DIR}/credentials.txt"

    print_success "用户凭据已保存到: ${WORK_DIR}/credentials.txt"
    print_success "FileBrowser 部署完成"
}

# ==================== 阶段 6: Systemd 服务注册 ====================

register_systemd_services() {
    print_separator
    print_info "阶段 6/8: Systemd 服务注册"
    print_separator

    # 创建 auto-extractor.service
    print_info "创建 auto-extractor.service..."

    cat > /etc/systemd/system/auto-extractor.service << 'EOF'
[Unit]
Description=Auto Extractor Daemon
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/web-unzipper
ExecStart=/usr/bin/python3 /opt/web-unzipper/auto_extractor.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    print_success "auto-extractor.service 创建成功"

    # 创建 filebrowser.service
    print_info "创建 filebrowser.service..."

    cat > /etc/systemd/system/filebrowser.service << EOF
[Unit]
Description=File Browser Web Interface
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORK_DIR
ExecStart=$FB_BIN -d $FB_DB
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    print_success "filebrowser.service 创建成功"

    # 重载 systemd
    print_info "重载 systemd 配置..."
    systemctl daemon-reload
    print_success "systemd 配置重载成功"

    # 启用并启动服务
    print_info "启动 auto-extractor 服务..."
    systemctl enable auto-extractor >/dev/null 2>&1
    systemctl start auto-extractor

    if systemctl is-active --quiet auto-extractor; then
        print_success "auto-extractor 服务启动成功"
    else
        print_error "auto-extractor 服务启动失败"
        systemctl status auto-extractor --no-pager
        exit 1
    fi

    print_info "启动 filebrowser 服务..."
    systemctl enable filebrowser >/dev/null 2>&1
    systemctl start filebrowser

    if systemctl is-active --quiet filebrowser; then
        print_success "filebrowser 服务启动成功"
    else
        print_error "filebrowser 服务启动失败"
        systemctl status filebrowser --no-pager
        exit 1
    fi

    print_success "Systemd 服务注册完成"
}

# ==================== 阶段 7: Samba 配置 ====================

configure_samba() {
    print_separator
    print_info "阶段 7/8: Samba 配置"
    print_separator

    # 检查 Samba 是否安装
    if ! command_exists smbd; then
        print_warning "Samba 未安装，跳过共享配置"
        return 0
    fi

    # 设置目录所有权
    print_info "设置目录所有权..."

    # 获取实际用户（非 root）
    if [ -n "$SUDO_USER" ]; then
        ACTUAL_USER="$SUDO_USER"
    else
        ACTUAL_USER="root"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DATA_DIR"
    print_success "目录所有权设置为: $ACTUAL_USER:$ACTUAL_USER"

    # 备份原配置文件
    if [ -f /etc/samba/smb.conf ]; then
        print_info "备份 Samba 配置文件..."
        cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.$(date +%Y%m%d%H%M%S)
        print_success "配置文件已备份"
    fi

    # 追加共享配置
    print_info "配置 Samba 共享..."

    # 检查是否已存在配置
    if grep -q "\[WebUnzipper\]" /etc/samba/smb.conf 2>/dev/null; then
        print_warning "Samba 共享配置已存在，跳过"
    else
        cat >> /etc/samba/smb.conf << EOF

[WebUnzipper]
path = $DATA_DIR
available = yes
valid users = @$ACTUAL_USER
read only = no
browsable = yes
public = no
writable = yes
create mask = 0644
directory mask = 0755
force create mode = 0644
force directory mode = 0755
EOF

        print_success "Samba 共享配置已添加"
    fi

    # 重启 Samba 服务
    print_info "重启 Samba 服务..."
    systemctl restart smbd nmbd

    if systemctl is-active --quiet smbd; then
        print_success "Samba 服务重启成功"
    else
        print_warning "Samba 服务重启失败，请手动检查"
    fi

    print_success "Samba 配置完成"
}

# ==================== 阶段 8: 安装完成提示 ====================

show_completion_message() {
    print_separator
    print_info "阶段 8/8: 安装完成"
    print_separator

    # 获取 IP 地址
    LOCAL_IP=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          🎉 极客私有云安装完成！                          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}📁 目录结构:${NC}"
    echo "   工作目录: $WORK_DIR"
    echo "   数据目录: $DATA_DIR"
    echo "   缓冲目录: $BUFFER_DIR"
    echo ""
    echo -e "${BLUE}🌐 FileBrowser 访问:${NC}"
    echo "   本地访问: http://localhost:$FB_PORT"
    echo "   局域网访问: http://$LOCAL_IP:$FB_PORT"
    echo ""
    echo -e "${BLUE}👤 用户账户:${NC}"
    echo "   管理员: admin (所有权限)"
    echo "   只读用户: reader (仅查看和下载)"
    echo "   ⚠️  密码已保存到: ${WORK_DIR}/credentials.txt"
    echo ""
    echo -e "${BLUE}💾 Samba 共享:${NC}"
    echo "   Windows: \\\\$LOCAL_IP\\WebUnzipper"
    echo "   macOS/Linux: smb://$LOCAL_IP/WebUnzipper"
    echo "   ⚠️  需要运行以下命令设置 Samba 密码:"
    echo "   sudo smbpasswd -a $ACTUAL_USER"
    echo ""
    echo -e "${BLUE}🔧 服务管理:${NC}"
    echo "   查看状态: systemctl status auto-extractor"
    echo "   查看状态: systemctl status filebrowser"
    echo "   重启服务: systemctl restart auto-extractor"
    echo "   重启服务: systemctl restart filebrowser"
    echo "   查看日志: tail -f $LOG_FILE"
    echo ""
    echo -e "${BLUE}📝 后续操作:${NC}"
    echo "   1. 登录 FileBrowser 并修改默认密码"
    echo "   2. 设置 Samba 访问密码: sudo smbpasswd -a $ACTUAL_USER"
    echo "   3. 将压缩包上传到 $DATA_DIR 目录"
    echo "   4. 系统将自动解压并转换编码"
    echo ""
    echo -e "${GREEN}✨ 安装完成！享受您的私有云阅读体验！${NC}"
    echo ""
}

# ==================== 主函数 ====================

main() {
    clear
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     极客私有云：全自动解压与沉浸式阅读引擎                ║${NC}"
    echo -e "${GREEN}║              一键安装脚本 v1.0.0                           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # 执行各阶段
    check_os
    check_root
    check_network

    install_dependencies
    create_directories
    deploy_python_daemon
    deploy_filebrowser
    register_systemd_services
    configure_samba
    show_completion_message
}

# 执行主函数
main "$@"
