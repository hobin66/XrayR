#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat"; then
    release="centos"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(arch)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

os_version=""

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release -y
        yum install wget curl unzip tar crontabs socat -y
    else
        apt update -y
        apt install wget curl unzip tar cron socat -y
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /etc/systemd/system/nodectl.service ]]; then
        return 2
    fi
    temp=$(systemctl status nodectl | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
    if [[ x"${temp}" == x"running" ]]; then
        return 0
    else
        return 1
    fi
}

install_acme() {
    curl https://get.acme.sh | sh
}

install_nodectl() {
    # 【关键修改】在一切开始之前，强制停止所有相关服务
    # 这能释放内存，防止解压时内存溢出导致 SSH 断开
    # 同时防止文件被占用
    echo -e "${green}正在停止旧服务以确保安装顺利...${plain}"
    systemctl stop nodectl >/dev/null 2>&1
    systemctl disable nodectl >/dev/null 2>&1
    # 顺便把 XrayR 也停了，防止冲突
    systemctl stop XrayR >/dev/null 2>&1
    systemctl disable XrayR >/dev/null 2>&1

    if [[ -e /usr/local/nodectl/ ]]; then
        rm /usr/local/nodectl/ -rf
    fi

    mkdir /usr/local/nodectl/ -p
	cd /usr/local/nodectl/

    if  [ $# == 0 ] ;then
        last_version=$(curl -Ls "https://api.github.com/repos/hobin66/XrayR/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 nodectl 版本失败，可能是超出 Github API 限制，请稍后再试，或手动指定 nodectl 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 nodectl 最新版本：${last_version}，开始安装"
        wget -q -N --no-check-certificate -O /usr/local/nodectl/nodectl-linux.zip https://github.com/hobin66/XrayR/releases/download/${last_version}/nodectl-linux-${arch}.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 nodectl 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        if [[ $1 == v* ]]; then
            last_version=$1
	else
	    last_version="v"$1
	fi
        url="https://github.com/hobin66/XrayR/releases/download/${last_version}/nodectl-linux-${arch}.zip"
        echo -e "开始安装 nodectl ${last_version}"
        wget -q -N --no-check-certificate -O /usr/local/nodectl/nodectl-linux.zip ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 nodectl ${last_version} 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi

    # 此时服务已停止，解压操作不再容易触发 OOM
    unzip nodectl-linux.zip
    rm nodectl-linux.zip -f
    chmod +x nodectl
    mkdir /etc/nodectl/ -p
    rm /etc/systemd/system/nodectl.service -f

    cat > /etc/systemd/system/nodectl.service <<EOF
[Unit]
Description=Nodectl Service
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/nodectl/nodectl -c /etc/nodectl/config.yml
Restart=on-failure
RestartPreventExitStatus=23

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    # 这里再次停止确保状态一致
    systemctl stop nodectl
    systemctl enable nodectl
    echo -e "${green}nodectl ${last_version}${plain} 安装完成，已设置开机自启"

    cp geoip.dat /etc/nodectl/
    cp geosite.dat /etc/nodectl/

    if [[ ! -f /etc/nodectl/config.yml ]]; then
        cp config.yml /etc/nodectl/
        echo -e ""
        echo -e "全新安装，请先配置 /etc/nodectl/config.yml"
    else
        systemctl start nodectl
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}nodectl 重启成功${plain}"
        else
            echo -e "${red}nodectl 可能启动失败，请稍后使用 nodectl log 查看日志信息${plain}"
        fi
    fi

    if [[ ! -f /etc/nodectl/dns.json ]]; then
        cp dns.json /etc/nodectl/
    fi
    if [[ ! -f /etc/nodectl/route.json ]]; then
        cp route.json /etc/nodectl/
    fi
    if [[ ! -f /etc/nodectl/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/nodectl/
    fi
    if [[ ! -f /etc/nodectl/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/nodectl/
    fi
    if [[ ! -f /etc/nodectl/rulelist ]]; then
        cp rulelist /etc/nodectl/
    fi

    curl -o /usr/bin/nodectl -Ls https://raw.githubusercontent.com/hobin66/XrayR/master/nodectl.sh
    chmod +x /usr/bin/nodectl

    rm -f /usr/bin/xrayr

    cd $cur_dir
    rm -f install.sh
    echo -e ""
    echo "nodectl 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "nodectl                    - 显示管理菜单 (功能更多)"
    echo "nodectl start              - 启动 nodectl"
    echo "nodectl stop               - 停止 nodectl"
    echo "nodectl restart            - 重启 nodectl"
    echo "nodectl status             - 查看 nodectl 状态"
    echo "nodectl enable             - 设置 nodectl 开机自启"
    echo "nodectl disable            - 取消 nodectl 开机自启"
    echo "nodectl log                - 查看 nodectl 日志"
    echo "nodectl update             - 更新 nodectl"
    echo "nodectl update x.x.x       - 更新 nodectl 指定版本"
    echo "nodectl config             - 显示配置文件内容"
    echo "nodectl install            - 安装 nodectl"
    echo "nodectl uninstall          - 卸载 nodectl"
    echo "nodectl version            - 查看 nodectl 版本"
    echo "------------------------------------------"
}

echo -e "${green}开始安装${plain}"
install_base
# install_acme
install_nodectl $1
