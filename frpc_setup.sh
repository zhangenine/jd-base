#!/bin/bash

# frpc自动部署和启动脚本
# 功能：
# 1. 检测系统类型和架构
# 2. 下载对应的frp包并解压获取frpc
# 3. 从/root/目录读取frpc*.ini配置文件
# 4. 为每个配置文件创建服务并设置开机启动
# 5. 循环检测/root/目录下的frpc*.ini文件变化
# 6. 检测进程重复运行，确保一个ini对应一个进程

# 设置颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "请使用root用户运行此脚本"
        exit 1
    fi
}

# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    else
        OS="unknown"
    fi
    
    log_info "检测到系统类型: $OS $VERSION"
    
    # 检查包管理器
    if [ -x "$(command -v apt-get)" ]; then
        PKG_MANAGER="apt-get"
    elif [ -x "$(command -v yum)" ]; then
        PKG_MANAGER="yum"
    elif [ -x "$(command -v dnf)" ]; then
        PKG_MANAGER="dnf"
    else
        log_error "未找到支持的包管理器"
        exit 1
    fi
    
    log_info "使用包管理器: $PKG_MANAGER"
}

# 检测系统架构
detect_arch() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="arm"
            ;;
        *)
            log_error "不支持的系统架构: $ARCH"
            exit 1
            ;;
    esac
    
    log_info "检测到系统架构: $ARCH"
}

# 安装必要的依赖
install_dependencies() {
    log_info "安装必要的依赖..."
    
    case $PKG_MANAGER in
        apt-get)
            apt-get update -y
            apt-get install -y curl wget tar unzip
            ;;
        yum|dnf)
            $PKG_MANAGER install -y curl wget tar unzip
            ;;
    esac
    
    if [ $? -ne 0 ]; then
        log_error "安装依赖失败"
        exit 1
    fi
    
    log_info "依赖安装完成"
}

# 获取最新的frp版本
get_latest_version() {
    log_info "获取frp最新版本..."
    
    # 使用GitHub API获取最新版本
    LATEST_VERSION=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep -Po '"tag_name": "\K.*?(?=")')
    
    if [ -z "$LATEST_VERSION" ]; then
        log_error "获取最新版本失败，使用默认版本v0.51.3"
        LATEST_VERSION="v0.51.3"
    fi
    
    log_info "最新版本: $LATEST_VERSION"
    return 0
}

# 下载并解压frp
download_frp() {
    log_info "下载frp $LATEST_VERSION..."
    
    # 创建临时目录
    TEMP_DIR="/tmp/frp_install"
    mkdir -p $TEMP_DIR
    cd $TEMP_DIR
    
    # 构建下载URL
    DOWNLOAD_URL="https://github.com/fatedier/frp/releases/download/$LATEST_VERSION/frp_${LATEST_VERSION#v}_linux_$ARCH.tar.gz"
    log_info "下载地址: $DOWNLOAD_URL"
    
    # 下载文件
    wget -q $DOWNLOAD_URL -O frp.tar.gz
    
    if [ $? -ne 0 ]; then
        log_error "下载frp失败"
        exit 1
    fi
    
    # 解压文件
    log_info "解压frp..."
    tar -xzf frp.tar.gz
    
    if [ $? -ne 0 ]; then
        log_error "解压frp失败"
        exit 1
    fi
    
    # 找到解压后的目录
    FRP_DIR=$(find . -maxdepth 1 -type d -name "frp_*" | head -n 1)
    
    if [ -z "$FRP_DIR" ]; then
        log_error "找不到frp目录"
        exit 1
    fi
    
    # 创建安装目录
    INSTALL_DIR="/usr/local/frp"
    mkdir -p $INSTALL_DIR
    
    # 复制frpc到安装目录
    cp $FRP_DIR/frpc $INSTALL_DIR/
    chmod +x $INSTALL_DIR/frpc
    
    log_info "frpc已安装到 $INSTALL_DIR/frpc"
    
    # 清理临时文件
    cd - > /dev/null
    rm -rf $TEMP_DIR
}

# 查找frpc配置文件
find_configs() {
    log_info "查找frpc配置文件..."
    
    # 查找/root/目录下所有frpc*.ini文件
    CONFIG_FILES=$(find /root/ -maxdepth 1 -name "frpc*.ini")
    
    if [ -z "$CONFIG_FILES" ]; then
        log_warn "在/root/目录下未找到frpc*.ini配置文件"
        return 1
    fi
    
    log_info "找到以下配置文件:"
    echo "$CONFIG_FILES" | while read -r file; do
        echo "  - $file"
    done
    
    return 0
}

# 检查进程是否已运行
check_process_running() {
    local config_file=$1
    local service_name=$(basename "$config_file" .ini)
    
    # 检查是否有使用此配置文件的frpc进程正在运行
    if pgrep -f "frpc -c $config_file" > /dev/null; then
        log_info "frpc进程已经在运行 (配置文件: $config_file)"
        return 0
    else
        log_info "frpc进程未运行 (配置文件: $config_file)"
        return 1
    fi
}

# 停止已运行的进程
stop_process() {
    local config_file=$1
    local service_name=$(basename "$config_file" .ini)
    
    log_info "停止frpc进程 (配置文件: $config_file)..."
    
    # 查找并终止使用此配置文件的frpc进程
    pkill -f "frpc -c $config_file"
    
    # 等待进程终止
    for i in {1..5}; do
        if ! pgrep -f "frpc -c $config_file" > /dev/null; then
            log_info "frpc进程已停止"
            return 0
        fi
        sleep 1
    done
    
    # 如果进程仍在运行，强制终止
    if pgrep -f "frpc -c $config_file" > /dev/null; then
        log_warn "frpc进程未能正常停止，强制终止..."
        pkill -9 -f "frpc -c $config_file"
    fi
    
    return 0
}

# 为systemd创建服务
create_systemd_service() {
    local config_file=$1
    local service_name=$(basename "$config_file" .ini)
    
    log_info "为 $config_file 创建systemd服务..."
    
    # 检查进程是否已运行，如果是则停止
    if check_process_running "$config_file"; then
        log_warn "发现 $service_name 进程已在运行，先停止它..."
        stop_process "$config_file"
    fi
    
    # 创建启动前检查脚本
    mkdir -p /usr/local/frp/scripts
    cat > /usr/local/frp/scripts/${service_name}_starter.sh << EOF
#!/bin/bash

# 检查是否有相同配置的进程在运行
if pgrep -f "frpc -c $config_file" > /dev/null; then
    echo "frpc进程已经在运行，跳过启动"
    exit 0
fi

# 检查配置文件是否存在
if [ ! -f "$config_file" ]; then
    echo "配置文件 $config_file 不存在，退出"
    exit 1
fi

# 启动frpc
exec /usr/local/frp/frpc -c $config_file
EOF
    
    chmod +x /usr/local/frp/scripts/${service_name}_starter.sh
    
    cat > /etc/systemd/system/${service_name}.service << EOF
[Unit]
Description=frpc service for $service_name
After=network.target

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=/usr/local/frp/scripts/${service_name}_starter.sh

[Install]
WantedBy=multi-user.target
EOF
    
    # 重新加载systemd
    systemctl daemon-reload
    
    # 启用并启动服务
    systemctl enable ${service_name}.service
    systemctl start ${service_name}.service
    
    if [ $? -ne 0 ]; then
        log_error "启动 ${service_name} 服务失败"
        return 1
    fi
    
    log_info "${service_name} 服务已创建并启动"
    return 0
}

# 为SysVinit创建服务
create_sysvinit_service() {
    local config_file=$1
    local service_name=$(basename "$config_file" .ini)
    
    log_info "为 $config_file 创建SysVinit服务..."
    
    # 检查进程是否已运行，如果是则停止
    if check_process_running "$config_file"; then
        log_warn "发现 $service_name 进程已在运行，先停止它..."
        stop_process "$config_file"
    fi
    
    # 创建启动前检查脚本
    mkdir -p /usr/local/frp/scripts
    cat > /usr/local/frp/scripts/${service_name}_starter.sh << EOF
#!/bin/bash

# 检查是否有相同配置的进程在运行
if pgrep -f "frpc -c $config_file" > /dev/null; then
    echo "frpc进程已经在运行，跳过启动"
    exit 0
fi

# 检查配置文件是否存在
if [ ! -f "$config_file" ]; then
    echo "配置文件 $config_file 不存在，退出"
    exit 1
fi

# 启动frpc
exec /usr/local/frp/frpc -c $config_file
EOF
    
    chmod +x /usr/local/frp/scripts/${service_name}_starter.sh
    
    cat > /etc/init.d/${service_name} << EOF
#!/bin/bash
### BEGIN INIT INFO
# Provides:          ${service_name}
# Required-Start:    \$network \$remote_fs \$syslog
# Required-Stop:     \$network \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: frpc service for ${service_name}
### END INIT INFO

STARTER="/usr/local/frp/scripts/${service_name}_starter.sh"
NAME="${service_name}"
PID_FILE="/var/run/\${NAME}.pid"

case "\$1" in
    start)
        echo "Starting \${NAME}..."
        # 检查进程是否已运行
        if pgrep -f "frpc -c $config_file" > /dev/null; then
            echo "\${NAME} 已经在运行"
            exit 0
        fi
        # 检查配置文件是否存在
        if [ ! -f "$config_file" ]; then
            echo "配置文件 $config_file 不存在，退出"
            exit 1
        fi
        start-stop-daemon --start --background --make-pidfile --pidfile \${PID_FILE} --exec \${STARTER}
        ;;
    stop)
        echo "Stopping \${NAME}..."
        start-stop-daemon --stop --pidfile \${PID_FILE}
        rm -f \${PID_FILE}
        # 确保所有相关进程都已停止
        if pgrep -f "frpc -c $config_file" > /dev/null; then
            pkill -f "frpc -c $config_file"
        fi
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    status)
        if [ -f \${PID_FILE} ]; then
            PID=\$(cat \${PID_FILE})
            if ps -p \${PID} > /dev/null; then
                echo "\${NAME} is running (PID: \${PID})"
                exit 0
            else
                # 检查是否有相同配置的进程在运行
                if pgrep -f "frpc -c $config_file" > /dev/null; then
                    echo "\${NAME} is running (PID file is stale)"
                    exit 0
                else
                    echo "\${NAME} is not running (stale PID file)"
                    exit 1
                fi
            fi
        else
            # 检查是否有相同配置的进程在运行
            if pgrep -f "frpc -c $config_file" > /dev/null; then
                echo "\${NAME} is running (no PID file)"
                exit 0
            else
                echo "\${NAME} is not running"
                exit 3
            fi
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOF
    
    # 设置执行权限
    chmod +x /etc/init.d/${service_name}
    
    # 添加到启动项
    if [ -x "$(command -v update-rc.d)" ]; then
        update-rc.d ${service_name} defaults
    elif [ -x "$(command -v chkconfig)" ]; then
        chkconfig --add ${service_name}
        chkconfig ${service_name} on
    else
        log_error "无法添加服务到启动项"
        return 1
    fi
    
    # 启动服务
    /etc/init.d/${service_name} start
    
    if [ $? -ne 0 ]; then
        log_error "启动 ${service_name} 服务失败"
        return 1
    fi
    
    log_info "${service_name} 服务已创建并启动"
    return 0
}

# 设置服务
setup_services() {
    log_info "设置frpc服务..."
    
    # 检查init系统类型
    if [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif [ -f /etc/init.d/cron ] || [ -f /etc/init.d/crond ]; then
        INIT_SYSTEM="sysvinit"
    else
        log_error "不支持的init系统"
        exit 1
    fi
    
    log_info "检测到init系统: $INIT_SYSTEM"
    
    # 为每个配置文件创建服务
    echo "$CONFIG_FILES" | while read -r config_file; do
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            create_systemd_service "$config_file"
        else
            create_sysvinit_service "$config_file"
        fi
    done
}

# 检查服务状态
check_services() {
    log_info "检查服务状态..."
    
    echo "$CONFIG_FILES" | while read -r config_file; do
        local service_name=$(basename "$config_file" .ini)
        
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl status ${service_name}.service
        else
            /etc/init.d/${service_name} status
        fi
    done
}

# 创建监控脚本
create_monitor_script() {
    log_info "创建frpc配置文件监控脚本..."
    
    cat > /usr/local/frp/scripts/frpc_monitor.sh << 'EOF'
#!/bin/bash

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" | tee -a /var/log/frpc_monitor.log
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a /var/log/frpc_monitor.log
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a /var/log/frpc_monitor.log
}

# 检查进程是否运行
check_process() {
    local config_file=$1
    if pgrep -f "frpc -c $config_file" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# 启动frpc进程
start_frpc() {
    local config_file=$1
    local service_name=$(basename "$config_file" .ini)
    
    # 检查服务是否存在
    if [ -f /etc/systemd/system/${service_name}.service ]; then
        log_info "使用systemd启动 $service_name"
        systemctl start ${service_name}.service
    elif [ -f /etc/init.d/${service_name} ]; then
        log_info "使用SysVinit启动 $service_name"
        /etc/init.d/${service_name} start
    else
        log_info "服务不存在，直接启动frpc进程"
        nohup /usr/local/frp/frpc -c "$config_file" > /var/log/frpc_${service_name}.log 2>&1 &
    fi
}

# 停止frpc进程
stop_frpc() {
    local config_file=$1
    local service_name=$(basename "$config_file" .ini)
    
    # 检查服务是否存在
    if [ -f /etc/systemd/system/${service_name}.service ]; then
        log_info "使用systemd停止 $service_name"
        systemctl stop ${service_name}.service
    elif [ -f /etc/init.d/${service_name} ]; then
        log_info "使用SysVinit停止 $service_name"
        /etc/init.d/${service_name} stop
    else
        log_info "服务不存在，直接终止frpc进程"
        pkill -f "frpc -c $config_file"
    fi
}

# 主循环
while true; do
    log_info "检查 /root/ 目录下的frpc*.ini文件..."
    
    # 获取当前所有配置文件
    current_configs=$(find /root/ -maxdepth 1 -name "frpc*.ini")
    
    # 检查每个配置文件
    for config_file in $current_configs; do
        service_name=$(basename "$config_file" .ini)
        
        # 检查配置文件是否有更新（使用修改时间）
        if [ -f "/tmp/frpc_${service_name}_mtime" ]; then
            old_mtime=$(cat "/tmp/frpc_${service_name}_mtime")
            new_mtime=$(stat -c %Y "$config_file")
            
            if [ "$old_mtime" != "$new_mtime" ]; then
                log_info "配置文件 $config_file 已更新，重启服务..."
                stop_frpc "$config_file"
                sleep 2
                start_frpc "$config_file"
                echo "$new_mtime" > "/tmp/frpc_${service_name}_mtime"
            fi
        else
            # 首次检测，记录修改时间
            stat -c %Y "$config_file" > "/tmp/frpc_${service_name}_mtime"
        fi
        
        # 检查进程是否在运行
        if ! check_process "$config_file"; then
            log_warn "frpc进程 ($service_name) 未运行，启动它..."
            start_frpc "$config_file"
        fi
    done
    
    # 检查是否有进程需要停止（配置文件已删除）
    running_processes=$(pgrep -fa "frpc -c /root/frpc.*\.ini" | grep -o "/root/frpc.*\.ini")
    for process_config in $running_processes; do
        if [ ! -f "$process_config" ]; then
            log_warn "配置文件 $process_config 已删除，停止对应进程..."
            stop_frpc "$process_config"
        fi
    done
    
    # 等待一段时间再次检查
    sleep 60
done
EOF
    
    chmod +x /usr/local/frp/scripts/frpc_monitor.sh
    
    # 创建systemd服务来运行监控脚本
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > /etc/systemd/system/frpc-monitor.service << EOF
[Unit]
Description=frpc configuration monitor
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/frp/scripts/frpc_monitor.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        
        systemctl daemon-reload
        systemctl enable frpc-monitor.service
        systemctl start frpc-monitor.service
        
        log_info "frpc监控服务已创建并启动 (systemd)"
    else
        # 创建SysVinit服务
        cat > /etc/init.d/frpc-monitor << EOF
#!/bin/bash
### BEGIN INIT INFO
# Provides:          frpc-monitor
# Required-Start:    \$network \$remote_fs \$syslog
# Required-Stop:     \$network \$remote_fs \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: frpc configuration monitor
### END INIT INFO

NAME="frpc-monitor"
DAEMON="/usr/local/frp/scripts/frpc_monitor.sh"
PID_FILE="/var/run/\${NAME}.pid"

case "\$1" in
    start)
        echo "Starting \${NAME}..."
        start-stop-daemon --start --background --make-pidfile --pidfile \${PID_FILE} --exec \${DAEMON}
        ;;
    stop)
        echo "Stopping \${NAME}..."
        start-stop-daemon --stop --pidfile \${PID_FILE}
        rm -f \${PID_FILE}
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    status)
        if [ -f \${PID_FILE} ]; then
            PID=\$(cat \${PID_FILE})
            if ps -p \${PID} > /dev/null; then
                echo "\${NAME} is running (PID: \${PID})"
                exit 0
            else
                echo "\${NAME} is not running (stale PID file)"
                exit 1
            fi
        else
            echo "\${NAME} is not running"
            exit 3
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOF
        
        chmod +x /etc/init.d/frpc-monitor
        
        # 添加到启动项
        if [ -x "$(command -v update-rc.d)" ]; then
            update-rc.d frpc-monitor defaults
        elif [ -x "$(command -v chkconfig)" ]; then
            chkconfig --add frpc-monitor
            chkconfig frpc-monitor on
        fi
        
        # 启动服务
        /etc/init.d/frpc-monitor start
        
        log_info "frpc监控服务已创建并启动 (SysVinit)"
    fi
}

# 直接启动所有frpc配置
start_all_frpc() {
    log_info "启动所有frpc配置..."
    
    # 查找/root/目录下所有frpc*.ini文件
    local configs=$(find /root/ -maxdepth 1 -name "frpc*.ini")
    
    if [ -z "$configs" ]; then
        log_warn "在/root/目录下未找到frpc*.ini配置文件"
        return 1
    fi
    
    # 为每个配置文件启动一个frpc进程
    echo "$configs" | while read -r config_file; do
        local service_name=$(basename "$config_file" .ini)
        
        # 检查进程是否已运行
        if check_process_running "$config_file"; then
            log_info "frpc进程已经在运行 (配置文件: $config_file)"
        else
            log_info "启动frpc (配置文件: $config_file)..."
            nohup /usr/local/frp/frpc -c "$config_file" > /var/log/frpc_${service_name}.log 2>&1 &
            
            if [ $? -eq 0 ]; then
                log_info "frpc已在后台启动，PID: $!"
            else
                log_error "启动frpc失败 (配置文件: $config_file)"
            fi
        fi
    done
    
    return 0
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [选项] [配置文件]"
    echo ""
    echo "选项:"
    echo "  -h, --help             显示此帮助信息"
    echo "  -i, --install          安装frpc并设置服务"
    echo "  -f, --foreground FILE  在前台运行frpc，使用指定配置文件"
    echo "  -b, --background FILE  在后台运行frpc，使用指定配置文件"
    echo "  --start-all           启动所有配置文件"
    echo ""
    echo "示例:"
    echo "  $0                     安装frpc并自动启动所有配置"
    echo "  $0 -f /root/frpc.ini   在前台运行frpc，使用指定配置文件"
    echo "  $0 --start-all         启动所有配置文件"
}

# 执行安装
do_install() {
    log_info "开始安装frpc..."
    
    # 检查root权限
    check_root
    
    # 检测系统类型和架构
    detect_os
    detect_arch
    
    # 安装依赖
    install_dependencies
    
    # 获取最新版本并下载
    get_latest_version
    download_frp
    
    # 查找配置文件
    find_configs
    
    if [ $? -ne 0 ]; then
        log_warn "未找到配置文件，请手动创建frpc配置文件后重新运行此脚本"
        return 1
    fi
    
    # 设置服务
    setup_services
    
    # 创建监控脚本
    create_monitor_script
    
    # 检查服务状态
    check_services
    
    log_info "frpc安装和配置完成！"
    log_info "已启动监控服务，将自动检测/root/目录下frpc*.ini文件的变化"
    log_info "监控日志保存在 /var/log/frpc_monitor.log"
    
    return 0
}

# 前台运行frpc
run_foreground() {
    local config_file=$1
    
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        exit 1
    fi
    
    log_info "在前台运行frpc，使用配置文件: $config_file"
    /usr/local/frp/frpc -c "$config_file"
}

# 后台运行frpc
run_background() {
    local config_file=$1
    local service_name=$(basename "$config_file" .ini)
    
    if [ ! -f "$config_file" ]; then
        log_error "配置文件不存在: $config_file"
        exit 1
    fi
    
    log_info "在后台运行frpc，使用配置文件: $config_file"
    nohup /usr/local/frp/frpc -c "$config_file" > /var/log/frpc_${service_name}.log 2>&1 &
    
    if [ $? -eq 0 ]; then
        log_info "frpc已在后台启动，PID: $!"
    else
        log_error "启动frpc失败"
        exit 1
    fi
}

# 主函数
main() {
    # 解析命令行参数
    if [ $# -eq 0 ]; then
        # 无参数，执行默认安装并自动启动所有配置
        do_install
        
        # 安装完成后，自动启动监控服务和所有frpc配置
        log_info "安装完成，自动启动所有frpc配置..."
        
        # 确保监控服务已启动
        if [ "$INIT_SYSTEM" = "systemd" ]; then
            systemctl status frpc-monitor.service > /dev/null 2>&1 || systemctl start frpc-monitor.service
            
            # 验证监控服务是否成功启动
            if systemctl is-active --quiet frpc-monitor.service; then
                log_success "frpc监控服务已成功启动并在后台运行"
            else
                log_error "frpc监控服务启动失败，请检查日志"
            fi
        else
            service frpc-monitor status > /dev/null 2>&1 || service frpc-monitor start
            
            # 验证监控服务是否成功启动
            if service frpc-monitor status > /dev/null 2>&1; then
                log_success "frpc监控服务已成功启动并在后台运行"
            else
                log_error "frpc监控服务启动失败，请检查日志"
            fi
        fi
        
        # 直接启动所有配置
        start_all_frpc
        
        # 显示成功信息并自动退出
        log_success "所有配置已在后台启动，监控服务正在运行"
        log_info "您可以关闭终端，frpc服务和监控将继续在后台运行"
    else
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            -f|--foreground)
                if [ -z "$2" ]; then
                    log_error "前台运行需要指定配置文件"
                    show_help
                    exit 1
                fi
                run_foreground "$2"
                ;;
            -b|--background)
                if [ -z "$2" ]; then
                    log_error "后台运行需要指定配置文件"
                    show_help
                    exit 1
                fi
                run_background "$2"
                ;;
            -i|--install)
                do_install
                ;;
            --start-all)
                # 启动所有配置
                start_all_frpc
                ;;
            *)
                if [ -f "$1" ]; then
                    # 如果参数是文件，默认前台运行
                    run_foreground "$1"
                else
                    log_error "未知选项或文件不存在: $1"
                    show_help
                    exit 1
                fi
                ;;
        esac
    fi
}

# 执行主函数
main