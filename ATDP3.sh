#!/bin/bash

# =========================================================
# AutoDeploy Ultimate
# Installation automatique universelle depuis une archive source
#
# Fonctionnalités :
# - Téléchargement automatique
# - Détection archive
# - Extraction automatique
# - Détection du vrai dossier extrait
# - Support :
#     autotools
#     cmake
#     meson
#     cargo
#     makefile
# - Installation automatique des dépendances
# - Gestion des erreurs
# - Logs complets
# - Continue même en cas d’erreur
#
# Usage :
# ./AutoDeploy.sh <URL>
#
# =========================================================

LOG_FILE="$(pwd)/install_errors.log"

# =========================================================
# Vérification argument
# =========================================================

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <URL_archive>"
    exit 1
fi

URL="$1"

# Nettoyage paramètres URL
CLEAN_URL="${URL%%\?*}"

ARCHIVE=$(basename "$CLEAN_URL")

# =========================================================
# Fonction log
# =========================================================

log_error() {
    echo "[ERROR] $1" | tee -a "$LOG_FILE"
}

log_info() {
    echo "[INFO] $1"
}

# =========================================================
# Vérification connexion
# =========================================================

log_info "Vérification connexion réseau..."

if ! ping -c 1 google.com &>/dev/null; then
    log_error "Pas de connexion internet."
    exit 1
fi

# =========================================================
# Installation outils essentiels
# =========================================================

log_info "Installation des outils essentiels..."

sudo apt-get update -qq

sudo apt-get install -y \
    build-essential \
    wget \
    curl \
    tar \
    gzip \
    bzip2 \
    xz-utils \
    unzip \
    git \
    pkg-config \
    autoconf \
    automake \
    libtool \
    cmake \
    meson \
    ninja-build \
    cargo \
    rustc \
    golang \
    python3 \
    python3-pip \
    nodejs \
    npm \
    checkinstall \
    gettext \
    flex \
    bison \
    texinfo \
    2>>"$LOG_FILE"

# =========================================================
# Téléchargement
# =========================================================

log_info "Téléchargement : $ARCHIVE"

wget --content-disposition -O "$ARCHIVE" "$URL" \
    2>>"$LOG_FILE"

if [ ! -f "$ARCHIVE" ]; then
    log_error "Téléchargement échoué."
    exit 1
fi

# =========================================================
# Détection type archive
# =========================================================

log_info "Détection archive..."

case "$ARCHIVE" in

    *.tar.gz|*.tgz)
        tar -xzf "$ARCHIVE" 2>>"$LOG_FILE"
        ;;

    *.tar.xz)
        tar -xJf "$ARCHIVE" 2>>"$LOG_FILE"
        ;;

    *.tar.bz2)
        tar -xjf "$ARCHIVE" 2>>"$LOG_FILE"
        ;;

    *.zip)
        unzip "$ARCHIVE" >>"$LOG_FILE" 2>&1
        ;;

    *)
        log_error "Format archive non supporté."
        exit 1
        ;;

esac

# =========================================================
# Détection dossier extrait
# =========================================================

log_info "Détection dossier extrait..."

DIRNAME=$(find . -maxdepth 1 -type d ! -name "." | sort | tail -n 1)

if [ -z "$DIRNAME" ]; then
    log_error "Impossible de détecter le dossier extrait."
    exit 1
fi

cd "$DIRNAME" || exit 1

log_info "Dossier détecté : $(pwd)"

# =========================================================
# Installation dépendances configure
# =========================================================

install_missing_dependencies() {

    if [ -f config.log ]; then

        MISSING_HEADERS=$(grep -i "No such file or directory" config.log \
            | grep "\.h" \
            | awk '{print $NF}' \
            | tr -d '<>:"' \
            | sort -u)

        for header in $MISSING_HEADERS; do

            PKG=$(apt-file search "$header" 2>/dev/null \
                | head -n 1 \
                | cut -d: -f1)

            if [ -n "$PKG" ]; then

                log_info "Installation dépendance : $PKG"

                sudo apt-get install -y "$PKG" \
                    2>>"$LOG_FILE"

            fi

        done

    fi
}

# =========================================================
# AUTOTOOLS
# =========================================================

build_autotools() {

    log_info "Système détecté : AUTOTOOLS"

    chmod +x configure 2>/dev/null

    while true; do

        if ./configure >>"$LOG_FILE" 2>&1; then
            break
        fi

        install_missing_dependencies

        log_info "Nouvelle tentative configure..."

    done

    make -j"$(nproc)" \
        2>&1 | tee -a "$LOG_FILE"

    sudo make install \
        2>&1 | tee -a "$LOG_FILE"
}

# =========================================================
# CMAKE
# =========================================================

build_cmake() {

    log_info "Système détecté : CMAKE"

    mkdir -p build
    cd build || exit 1

    cmake .. \
        2>&1 | tee -a "$LOG_FILE"

    make -j"$(nproc)" \
        2>&1 | tee -a "$LOG_FILE"

    sudo make install \
        2>&1 | tee -a "$LOG_FILE"
}

# =========================================================
# MESON
# =========================================================

build_meson() {

    log_info "Système détecté : MESON"

    meson setup build \
        2>&1 | tee -a "$LOG_FILE"

    ninja -C build \
        2>&1 | tee -a "$LOG_FILE"

    sudo ninja -C build install \
        2>&1 | tee -a "$LOG_FILE"
}

# =========================================================
# CARGO
# =========================================================

build_cargo() {

    log_info "Système détecté : CARGO / RUST"

    cargo build --release \
        2>&1 | tee -a "$LOG_FILE"

    sudo cargo install --path . \
        2>&1 | tee -a "$LOG_FILE"
}

# =========================================================
# GO
# =========================================================

build_go() {

    log_info "Système détecté : GO"

    go build \
        2>&1 | tee -a "$LOG_FILE"
}

# =========================================================
# NODEJS
# =========================================================

build_node() {

    log_info "Système détecté : NODEJS"

    npm install \
        2>&1 | tee -a "$LOG_FILE"

    npm run build \
        2>&1 | tee -a "$LOG_FILE"
}

# =========================================================
# MAKEFILE SIMPLE
# =========================================================

build_makefile() {

    log_info "Système détecté : MAKEFILE"

    make -j"$(nproc)" \
        2>&1 | tee -a "$LOG_FILE"

    sudo make install \
        2>&1 | tee -a "$LOG_FILE"
}

# =========================================================
# Détection système build
# =========================================================

log_info "Détection système de build..."

if [ -f configure ]; then

    build_autotools

elif [ -f CMakeLists.txt ]; then

    build_cmake

elif [ -f meson.build ]; then

    build_meson

elif [ -f Cargo.toml ]; then

    build_cargo

elif [ -f go.mod ]; then

    build_go

elif [ -f package.json ]; then

    build_node

elif [ -f Makefile ] || [ -f makefile ]; then

    build_makefile

else

    log_error "Aucun système de build supporté détecté."

    exit 1

fi

# =========================================================
# Fin
# =========================================================

log_info "========================================="
log_info "Installation terminée."
log_info "Logs disponibles : $LOG_FILE"
log_info "========================================="
