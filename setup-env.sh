#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  setup-env.sh  —  Entorno gráfico completo + acelerado por GPU para Colab
#  Detecta Ubuntu, valida compatibilidad, configura Xorg con NVIDIA (no Xvfb),
#  instala XFCE4 con tema/compositor/fuentes, Chrome, Brave, herramientas.
#  Uso:  chmod +x setup-env.sh && ./setup-env.sh
# ============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✔]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✘]${NC} $*"; exit 1; }
step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }

RESOLUTION="${RESOLUTION:-1920x1080}"
DPI="${DPI:-96}"
DISPLAY_NUM=":0"

# ── Root + Linux ────────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Linux" ]] || fail "Solo funciona en Linux."
[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (en Colab ya eres root)."

# ── Detectar distro ─────────────────────────────────────────────────────────
step "Detectando sistema operativo"

if command -v lsb_release &>/dev/null; then
    DISTRO_ID=$(lsb_release -si)
    DISTRO_CODENAME=$(lsb_release -sc)
    DISTRO_RELEASE=$(lsb_release -sr)
elif [[ -f /etc/os-release ]]; then
    source /etc/os-release
    DISTRO_ID="${ID^}"
    DISTRO_CODENAME="${VERSION_CODENAME:-unknown}"
    DISTRO_RELEASE="${VERSION_ID:-0}"
else
    fail "No se pudo detectar la distribución."
fi

log "Distro: ${DISTRO_ID} ${DISTRO_RELEASE} (${DISTRO_CODENAME})"

declare -A SUPPORTED_VERSIONS=(
    ["focal"]="20.04"
    ["jammy"]="22.04"
    ["noble"]="24.04"
)

if [[ -z "${SUPPORTED_VERSIONS[$DISTRO_CODENAME]+_}" ]]; then
    warn "Codename '${DISTRO_CODENAME}' no probado. Soportados: ${!SUPPORTED_VERSIONS[*]}"
    warn "Continuando bajo tu responsabilidad..."
else
    log "Versión ${DISTRO_RELEASE} (${DISTRO_CODENAME}) validada."
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
[[ "$ARCH" == "amd64" ]] || fail "Arquitectura ${ARCH} no soportada."

# ── Repositorios ────────────────────────────────────────────────────────────
step "Actualizando repositorios"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# ── GPU: detectar NVIDIA y preparar Xorg ────────────────────────────────────
step "Detectando GPU y configurando servidor gráfico"

HAS_NVIDIA=false
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
    HAS_NVIDIA=true
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
    GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    GPU_VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
    log "GPU detectada: ${GPU_NAME} (driver ${GPU_DRIVER}, VRAM ${GPU_VRAM})"
else
    warn "No se detectó GPU NVIDIA. Se usará Xvfb (software, menor calidad)."
fi

# Paquetes X11 base necesarios para ambos modos
apt-get install -y -qq \
    xserver-xorg-core \
    x11-xserver-utils \
    x11-utils \
    xinit \
    dbus-x11 \
    xdg-utils \
    xdg-user-dirs \
    xterm 2>/dev/null || true

if $HAS_NVIDIA; then
    # Xorg con driver NVIDIA real: renderizado por GPU, no software
    apt-get install -y -qq xserver-xorg-video-dummy 2>/dev/null || true

    BUS_ID=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null | head -1 | sed 's/00000000://' | sed 's/\./:/')

    mkdir -p /etc/X11
    cat > /etc/X11/xorg.conf << XORGEOF
Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0"
EndSection

Section "Device"
    Identifier     "Device0"
    Driver         "nvidia"
    BusID          "${BUS_ID}"
    Option         "AllowEmptyInitialConfiguration" "True"
    Option         "ConnectedMonitor" "DFP-0"
    Option         "CustomEDID" "DFP-0:/etc/X11/edid.bin"
EndSection

Section "Monitor"
    Identifier     "Monitor0"
    HorizSync       1.0 - 500.0
    VertRefresh     1.0 - 240.0
    Option         "DPMS" "False"
    Modeline "1920x1080_60" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
    Modeline "2560x1440_60" 241.50 2560 2608 2640 2720 1440 1443 1448 1481 +hsync +vsync
EndSection

Section "Screen"
    Identifier     "Screen0"
    Device         "Device0"
    Monitor        "Monitor0"
    DefaultDepth    24
    Option         "MetaModes" "${RESOLUTION} +0+0"
    SubSection     "Display"
        Depth       24
        Modes       "${RESOLUTION}"
    EndSubSection
EndSection

Section "Extensions"
    Option         "Composite" "Enable"
EndSection
XORGEOF

    # Generar EDID falso para que NVIDIA crea que hay un monitor conectado
    apt-get install -y -qq edid-decode 2>/dev/null || true
    if command -v nvidia-xconfig &>/dev/null; then
        nvidia-xconfig --allow-empty-initial-configuration \
            --enable-all-gpus \
            --connected-monitor=DFP-0 \
            --custom-edid=DFP-0:/etc/X11/edid.bin 2>/dev/null || true
    fi

    # Crear EDID binario mínimo para 1920x1080
    py_edid='
import struct, sys
edid = bytearray(128)
edid[0:8] = b"\x00\xff\xff\xff\xff\xff\xff\x00"
edid[8:10] = struct.pack(">H", 0x1234)
edid[10:12] = struct.pack("<H", 0x5678)
edid[12:16] = struct.pack("<I", 1)
edid[16] = 1; edid[17] = 21
edid[18] = 1; edid[19] = 4
edid[20] = 0xA5
edid[21] = 52; edid[22] = 30
edid[23] = 78
edid[24:34] = b"\x26\x0C\x50\xA0\x54\x00\x08\x00\x81\x80"
edid[35] = 0; edid[36] = 0; edid[37] = 0
edid[38:54] = b"\xFC\x00Virtual Screen\x0A"
edid[54:126] = bytes(72)
s = (256 - (sum(edid[:127]) % 256)) % 256
edid[127] = s
sys.stdout.buffer.write(bytes(edid))
'
    python3 -c "$py_edid" > /etc/X11/edid.bin 2>/dev/null || true

    # Matar X existente y arrancar Xorg con NVIDIA
    pkill -9 Xorg 2>/dev/null || true
    pkill -9 Xvfb 2>/dev/null || true
    sleep 1

    Xorg ${DISPLAY_NUM} -config /etc/X11/xorg.conf &
    sleep 3

    if pgrep -f "Xorg ${DISPLAY_NUM}" &>/dev/null; then
        log "Xorg arrancado en ${DISPLAY_NUM} con GPU NVIDIA (${RESOLUTION})."
    else
        warn "Xorg con NVIDIA falló. Intentando fallback con Xvfb..."
        HAS_NVIDIA=false
    fi
fi

# Fallback: Xvfb si no hay NVIDIA o falló Xorg
if ! $HAS_NVIDIA; then
    apt-get install -y -qq xvfb 2>/dev/null || true
    pkill -9 Xvfb 2>/dev/null || true
    sleep 1
    Xvfb ${DISPLAY_NUM} -screen 0 ${RESOLUTION}x24 -dpi ${DPI} +extension GLX +render &
    sleep 2
    if pgrep -f "Xvfb ${DISPLAY_NUM}" &>/dev/null; then
        log "Xvfb iniciado en ${DISPLAY_NUM} (${RESOLUTION}x24, ${DPI} DPI) — software rendering."
    else
        fail "No se pudo iniciar ningún servidor gráfico."
    fi
fi

export DISPLAY=${DISPLAY_NUM}

# ── Escritorio XFCE4 ───────────────────────────────────────────────────────
step "Instalando escritorio XFCE4"
apt-get install -y -qq \
    xfce4 \
    xfce4-terminal \
    xfce4-whiskermenu-plugin \
    xfce4-taskmanager \
    xfce4-screenshooter \
    xfce4-power-manager \
    xfce4-settings \
    xfce4-notifyd \
    thunar \
    thunar-archive-plugin \
    mousepad \
    ristretto \
    fonts-noto-color-emoji \
    fonts-liberation \
    fonts-dejavu-core \
    fonts-freefont-ttf \
    fonts-ubuntu \
    adwaita-icon-theme \
    papirus-icon-theme \
    gtk2-engines-murrine \
    arc-theme \
    mesa-utils \
    libgl1-mesa-dri \
    libglu1-mesa 2>/dev/null || true
log "XFCE4 + temas + fuentes instalados."

# ── Tema y apariencia de XFCE4 ─────────────────────────────────────────────
step "Configurando tema, fuentes y compositor"

XFCE_CONF_DIR="/root/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "${XFCE_CONF_DIR}"

# Tema GTK + iconos + fuentes + DPI
cat > "${XFCE_CONF_DIR}/xsettings.xml" << 'SETTINGSEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Arc-Dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="CursorSize" type="int" value="24"/>
    <property name="EnableEventSounds" type="bool" value="false"/>
    <property name="EnableInputFeedbackSounds" type="bool" value="false"/>
  </property>
  <property name="Xft" type="empty">
    <property name="DPI" type="int" value="96"/>
    <property name="Antialias" type="int" value="1"/>
    <property name="Hinting" type="int" value="1"/>
    <property name="HintStyle" type="string" value="hintslight"/>
    <property name="RGBA" type="string" value="rgb"/>
    <property name="Lcdfilter" type="string" value="lcddefault"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Ubuntu 11"/>
    <property name="MonospaceFontName" type="string" value="DejaVu Sans Mono 10"/>
    <property name="CursorThemeName" type="string" value="Adwaita"/>
    <property name="CursorThemeSize" type="int" value="24"/>
    <property name="CanChangeAccels" type="bool" value="false"/>
    <property name="MenuImages" type="bool" value="true"/>
    <property name="ButtonImages" type="bool" value="true"/>
  </property>
</channel>
SETTINGSEOF

# Window manager: tema + títulos
cat > "${XFCE_CONF_DIR}/xfwm4.xml" << 'XFWM4EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Arc-Dark"/>
    <property name="title_font" type="string" value="Ubuntu Bold 10"/>
    <property name="use_compositing" type="bool" value="true"/>
    <property name="unredirect_overlays" type="bool" value="true"/>
    <property name="cycle_draw_frame" type="bool" value="true"/>
    <property name="cycle_raise" type="bool" value="true"/>
    <property name="cycle_hidden" type="bool" value="true"/>
    <property name="cycle_minimum" type="bool" value="true"/>
    <property name="cycle_preview" type="bool" value="true"/>
    <property name="placement_ratio" type="int" value="20"/>
    <property name="shadow_opacity" type="int" value="50"/>
    <property name="frame_opacity" type="int" value="100"/>
    <property name="inactive_opacity" type="int" value="100"/>
    <property name="move_opacity" type="int" value="100"/>
    <property name="resize_opacity" type="int" value="100"/>
    <property name="popup_opacity" type="int" value="100"/>
    <property name="snap_to_border" type="bool" value="true"/>
    <property name="snap_to_windows" type="bool" value="true"/>
    <property name="snap_width" type="int" value="10"/>
    <property name="box_move" type="bool" value="false"/>
    <property name="box_resize" type="bool" value="false"/>
  </property>
</channel>
XFWM4EOF

# Panel: posición abajo, tamaño decente, transparencia
cat > "${XFCE_CONF_DIR}/xfce4-panel.xml" << 'PANELEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=960;y=1054"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="36"/>
      <property name="background-style" type="uint" value="0"/>
      <property name="enter-opacity" type="uint" value="100"/>
      <property name="leave-opacity" type="uint" value="85"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist"/>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="pulseaudio"/>
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-format" type="string" value="%H:%M"/>
    </property>
  </property>
</channel>
PANELEOF

# Desktop: fondo sólido oscuro, sin iconos de basura
cat > "${XFCE_CONF_DIR}/xfce4-desktop.xml" << 'DESKEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="2"/>
    <property name="file-icons" type="empty">
      <property name="show-trash" type="bool" value="false"/>
      <property name="show-filesystem" type="bool" value="false"/>
      <property name="show-home" type="bool" value="true"/>
      <property name="show-removable" type="bool" value="false"/>
    </property>
    <property name="icon-size" type="uint" value="48"/>
  </property>
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorscreen" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="rgba1" type="array">
            <value type="double" value="0.1569"/>
            <value type="double" value="0.1647"/>
            <value type="double" value="0.2118"/>
            <value type="double" value="1.0"/>
          </property>
          <property name="image-style" type="int" value="0"/>
        </property>
      </property>
    </property>
  </property>
</channel>
DESKEOF

# Terminal: tema oscuro, fuente mono decente
TERM_CONF_DIR="/root/.config/xfce4/terminal"
mkdir -p "${TERM_CONF_DIR}"
cat > "${TERM_CONF_DIR}/terminalrc" << 'TERMEOF'
[Configuration]
FontName=DejaVu Sans Mono 11
MiscAlwaysShowTabs=FALSE
MiscBordersDefault=TRUE
MiscCursorBlinks=TRUE
MiscCursorShape=TERMINAL_CURSOR_SHAPE_BLOCK
MiscDefaultGeometry=120x35
MiscMenubarDefault=TRUE
MiscMouseAutohide=FALSE
MiscToolbarDefault=FALSE
MiscConfirmClose=TRUE
MiscCycleTabs=TRUE
MiscTabCloseButtons=TRUE
MiscTabCloseMiddleClick=TRUE
MiscTabPosition=GTK_POS_TOP
ScrollingBar=TERMINAL_SCROLLBAR_NONE
ColorForeground=#d3d3d7d7cfcf
ColorBackground=#2e2e34344040
ColorPalette=#070736364141;#dcdc32322f2f;#858599990000;#b5b589890000;#26268b8bd2d2;#d3d336368282;#2a2aa1a19898;#eeeee8e8d5d5;#000028283636;#cbcb4b4b1616;#58586e6e7575;#65657b7b8383;#838394949696;#6c6c7171c4c4;#9393a1a1a1a1;#fdfdf6f6e3e3
TabActivityColor=#dc322f
TERMEOF

# Fontconfig: renderizado de fuentes de alta calidad
mkdir -p /etc/fonts/conf.d /root/.config/fontconfig
cat > /root/.config/fontconfig/fonts.conf << 'FONTEOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter" mode="assign"><const>lcddefault</const></edit>
    <edit name="autohint" mode="assign"><bool>false</bool></edit>
  </match>
</fontconfig>
FONTEOF
fc-cache -f 2>/dev/null || true

log "Tema Arc-Dark, iconos Papirus, fuentes Ubuntu/DejaVu, compositor ON."

# ── Iniciar XFCE ───────────────────────────────────────────────────────────
step "Iniciando sesión XFCE4"
pkill -9 xfce4-session 2>/dev/null || true
sleep 1

export XDG_SESSION_TYPE=x11
export XDG_CURRENT_DESKTOP=XFCE
export XDG_CONFIG_HOME=/root/.config

dbus-launch --exit-with-session startxfce4 &>/dev/null &
sleep 4

if pgrep -f "xfce4-session" &>/dev/null; then
    log "Sesión XFCE4 corriendo con compositor habilitado."
else
    warn "XFCE4 no arrancó (puede iniciar al conectar Sunshine/VNC)."
fi

# ── Google Chrome ───────────────────────────────────────────────────────────
step "Instalando Google Chrome"
if ! command -v google-chrome &>/dev/null; then
    CHROME_DEB="/tmp/google-chrome-stable.deb"
    wget -q -O "${CHROME_DEB}" \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    apt-get install -y -qq "${CHROME_DEB}" 2>/dev/null || apt-get install -f -y -qq
    rm -f "${CHROME_DEB}"
    log "Chrome $(google-chrome --version 2>/dev/null | head -1) instalado."
else
    log "Chrome ya presente: $(google-chrome --version 2>/dev/null | head -1)"
fi

# ── Brave Browser ───────────────────────────────────────────────────────────
step "Instalando Brave Browser"
if ! command -v brave-browser &>/dev/null; then
    apt-get install -y -qq curl gnupg 2>/dev/null || true
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg"
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg arch=${ARCH}] \
https://brave-browser-apt-release.s3.brave.com/ stable main" \
        > /etc/apt/sources.list.d/brave-browser-release.list
    apt-get update -qq
    apt-get install -y -qq brave-browser 2>/dev/null || warn "Brave no se pudo instalar (no crítico)."
    if command -v brave-browser &>/dev/null; then
        log "Brave $(brave-browser --version 2>/dev/null | head -1) instalado."
    fi
else
    log "Brave ya presente."
fi

# ── Herramientas útiles ─────────────────────────────────────────────────────
step "Instalando herramientas adicionales"
TOOLS=(htop neofetch nano vim curl wget unzip p7zip-full net-tools iputils-ping file)
apt-get install -y -qq "${TOOLS[@]}" 2>/dev/null || true
log "Herramientas: ${TOOLS[*]}"

# ── PulseAudio ──────────────────────────────────────────────────────────────
step "Configurando audio (PulseAudio)"
apt-get install -y -qq pulseaudio pulseaudio-utils 2>/dev/null || true
if ! pgrep -f pulseaudio &>/dev/null; then
    pulseaudio --start --exit-idle-time=-1 2>/dev/null || true
    log "PulseAudio iniciado."
else
    log "PulseAudio ya corriendo."
fi

# ── Directorios estándar ────────────────────────────────────────────────────
xdg-user-dirs-update 2>/dev/null || true

# ── Accesos directos en el escritorio ───────────────────────────────────────
step "Creando accesos directos en el escritorio"
DESKTOP_DIR="/root/Desktop"
mkdir -p "${DESKTOP_DIR}"

cat > "${DESKTOP_DIR}/chrome.desktop" << 'CHREOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Exec=google-chrome --no-sandbox --disable-gpu-sandbox
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
CHREOF
chmod +x "${DESKTOP_DIR}/chrome.desktop"

if command -v brave-browser &>/dev/null; then
    cat > "${DESKTOP_DIR}/brave.desktop" << 'BRVEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Brave Browser
Exec=brave-browser --no-sandbox --disable-gpu-sandbox
Icon=brave-browser
Terminal=false
Categories=Network;WebBrowser;
BRVEOF
    chmod +x "${DESKTOP_DIR}/brave.desktop"
fi

cat > "${DESKTOP_DIR}/terminal.desktop" << 'TRMEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
TRMEOF
chmod +x "${DESKTOP_DIR}/terminal.desktop"

cat > "${DESKTOP_DIR}/files.desktop" << 'FILEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Archivos
Exec=thunar
Icon=system-file-manager
Terminal=false
Categories=System;FileManager;
FILEOF
chmod +x "${DESKTOP_DIR}/files.desktop"

log "Accesos: Chrome, Brave, Terminal, Archivos en el escritorio."

# ── Resumen ─────────────────────────────────────────────────────────────────
step "Resumen de instalación"
echo ""
log "Sistema:      ${DISTRO_ID} ${DISTRO_RELEASE} (${DISTRO_CODENAME}) — ${ARCH}"
if $HAS_NVIDIA; then
    log "GPU:          ${GPU_NAME} (driver ${GPU_DRIVER}, ${GPU_VRAM})"
    log "Display:      Xorg + NVIDIA en ${DISPLAY_NUM} (${RESOLUTION})"
else
    log "Display:      Xvfb en ${DISPLAY_NUM} (${RESOLUTION}, software)"
fi
log "Escritorio:   XFCE4 — Arc-Dark + Papirus-Dark + compositor ON"
log "Fuentes:      Ubuntu 11 / DejaVu Sans Mono 10 — antialiasing + hinting"
log "DPI:          ${DPI}"
command -v google-chrome &>/dev/null && log "Chrome:       $(google-chrome --version 2>/dev/null | head -1)"
command -v brave-browser &>/dev/null && log "Brave:        $(brave-browser --version 2>/dev/null | head -1)"
log "Audio:        PulseAudio"
log "Herramientas: ${TOOLS[*]}"
echo ""
log "Entorno listo. Ejecuta ./ColabSteam para Sunshine + Steam + Tailscale."
echo ""
