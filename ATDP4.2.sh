#!/bin/bash
# =========================================================
# AutoDeploy Ultimate v4 (ATDP4)
# Installation automatique universelle depuis une archive source
#
# version interractif et amelioree de ATDP3 :
#   - détection fiable du dossier extrait (snapshot avant/après)
#   - boucle "configure" bornée (plus d'infini)
#   - vérification réelle du fichier téléchargé (type MIME / intégrité archive)
#   - make install seulement si make a réussi
#   - vérification systématique des codes de retour ($?)
#   - support configure.ac / configure.in / autogen.sh (autoreconf)
#   - nettoyage (trap EXIT, option --clean, prompt final)
#   - gestion propre de CTRL+C (trap SIGINT/SIGTERM)
#   - apt-file installé + "apt-file update" avant utilisation
#   - test de connexion sans dépendre d'ICMP (wget --spider)
#   - sortie en couleurs, étapes numérotées [n/N], résumé final
#   - factorisation (compile()/do_install() au lieu de code dupliqué)
#   - installation des toolchains à la demande seulement (pas tout, d'office)
#   - mode --verbose / --quiet
#   - détection dépendances via pkg-config en plus de config.log
#   - option --checkinstall pour générer un .deb désinstallable proprement
#   - mode interactif : choix entre URL à télécharger OU archive déjà présente
#     localement (chemin absolu), pour éviter de télécharger inutilement
#
# Usage :
#   Mode direct (comme avant) :
#     ./ATDP4.sh <URL_archive> [options]
#
#   Mode interactif (nouveau) : lancer sans argument source, le script
#   demande alors de choisir entre une URL à télécharger ou le chemin
#   absolu d'une archive déjà téléchargée sur le disque :
#     ./ATDP4.sh [options]
#
# Options :
#   --verbose        Affiche toutes les commandes exécutées (set -x partiel)
#   --quiet          N'affiche que les erreurs et le résumé final
#   --clean          Supprime systématiquement archive + dossier extrait à la fin
#   --no-clean       Ne supprime jamais (par défaut : demande à l'utilisateur)
#   --checkinstall    Utilise checkinstall au lieu de "make install" (paquet .deb)
#   --max-retries=N  Nombre maximal de tentatives "configure" (défaut : 5)
#   --sha256=HASH    Vérifie le SHA256 de l'archive (téléchargée ou locale)
#
# =========================================================

set -uo pipefail

# =========================================================
# Configuration générale
# =========================================================

WORKDIR="$(pwd)"
LOG_FILE="$WORKDIR/install_errors.log"
START_TIME=$(date +%s)

VERBOSE=0
QUIET=0
CLEAN_MODE=""        # "" = demander ; "yes" = --clean ; "no" = --no-clean
USE_CHECKINSTALL=0
MAX_RETRIES=5
EXPECTED_SHA256=""

# SOURCE_MODE : "url" (téléchargement) ou "local" (archive déjà sur disque).
# Déterminé soit directement par l'argument positionnel (mode direct,
# rétrocompatible avec l'ancienne version), soit via le menu interactif
# si aucun argument source n'est fourni.
SOURCE_MODE=""
LOCAL_ARCHIVE_PATH=""

TOTAL_STEPS=6
CURRENT_STEP=0

# Variables d'état utilisées pour le résumé final
DETECTED_BUILD_SYSTEM="inconnu"
INSTALLED_DEPS=()
PROJECT_DIRNAME=""
BUILD_STATUS="non lancé"
CLEANUP_DONE="non"
NEEDS_PATH_NOTICE=0

# Initialisées tôt pour éviter toute erreur "unbound variable" (set -u) si le
# script s'arrête (erreur d'argument, etc.) avant d'avoir téléchargé quoi que ce soit.
ARCHIVE=""
URL=""

# Passe à "oui" uniquement une fois l'archive réellement téléchargée et vérifiée :
# sert à savoir si un nettoyage / résumé a un sens, ou si on doit sortir en silence.
WORK_STARTED="non"

# =========================================================
# Couleurs
# =========================================================

if [ -t 1 ]; then
    C_RESET="\033[0m"
    C_INFO="\033[1;34m"   # bleu
    C_OK="\033[1;32m"     # vert
    C_WARN="\033[1;33m"   # jaune
    C_ERR="\033[1;31m"    # rouge
    C_STEP="\033[1;36m"   # cyan
else
    C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""; C_STEP=""
fi

# =========================================================
# Fonctions de log
# =========================================================

log_info() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${C_INFO}[INFO]${C_RESET} $1"
}

log_ok() {
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${C_OK}[OK]${C_RESET} $1"
}

log_warn() {
    echo -e "${C_WARN}[WARN]${C_RESET} $1" | tee -a "$LOG_FILE" >/dev/null
    [ "$QUIET" -eq 1 ] || echo -e "${C_WARN}[WARN]${C_RESET} $1"
}

log_error() {
    echo -e "${C_ERR}[ERROR]${C_RESET} $1"
    echo "[ERROR] $1" >> "$LOG_FILE"
}

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    [ "$QUIET" -eq 1 ] && return 0
    echo -e "${C_STEP}[${CURRENT_STEP}/${TOTAL_STEPS}]${C_RESET} $1"
}

# Exécute une commande, log tout, renvoie le vrai code de retour.
# Usage : run_step "description" commande arg1 arg2 ...
run_step() {
    local description="$1"
    shift

    log_info "$description"

    if [ "$VERBOSE" -eq 1 ]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        local status=${PIPESTATUS[0]}
    else
        "$@" >>"$LOG_FILE" 2>&1
        local status=$?
    fi

    if [ "$status" -ne 0 ]; then
        log_error "Échec : $description (code $status). Voir $LOG_FILE"
    else
        log_ok "$description"
    fi

    return "$status"
}

# =========================================================
# Nettoyage / interruption (CTRL+C, EXIT)
# =========================================================

cleanup() {
    local exit_code=$?

    if [ "$CLEANUP_DONE" = "oui" ]; then
        exit "$exit_code"
    fi

    # Si on n'a encore rien téléchargé ni extrait (ex : erreur d'arguments, ou
    # réseau indisponible avant le téléchargement), il n'y a rien à nettoyer
    # ni à résumer : on sort sans bruit.
    if [ "$WORK_STARTED" != "oui" ]; then
        CLEANUP_DONE="oui"
        exit "$exit_code"
    fi

    echo
    log_info "Nettoyage en cours..."

    cd "$WORKDIR" 2>/dev/null || true

    do_cleanup_prompt

    print_summary

    exit "$exit_code"
}

on_interrupt() {
    echo
    log_warn "Interruption demandée (CTRL+C). Arrêt propre en cours..."
    exit 130
}

trap cleanup EXIT
trap on_interrupt SIGINT SIGTERM

do_cleanup_prompt() {
    local archive_path="${ARCHIVE:-}"
    local project_dir="${PROJECT_DIRNAME:-}"

    if [ -z "$project_dir" ] && [ -z "$archive_path" ]; then
        CLEANUP_DONE="oui"
        return
    fi

    local answer="$CLEAN_MODE"

    if [ -z "$answer" ]; then
        if [ -t 0 ] && [ "$QUIET" -eq 0 ]; then
            read -r -p "Supprimer les fichiers temporaires (archive + dossier extrait) ? [o/N] " reply
            case "$reply" in
                [oOyY]*) answer="yes" ;;
                *) answer="no" ;;
            esac
        else
            answer="no"
        fi
    fi

    if [ "$answer" = "yes" ]; then
        [ -n "$archive_path" ] && [ -f "$WORKDIR/$archive_path" ] && rm -f "$WORKDIR/$archive_path"
        [ -n "$project_dir" ] && [ -d "$WORKDIR/$project_dir" ] && rm -rf "$WORKDIR/$project_dir"
        log_info "Fichiers temporaires supprimés."
    else
        log_info "Fichiers temporaires conservés."
    fi

    CLEANUP_DONE="oui"
}

print_summary() {
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))

    [ "$QUIET" -eq 1 ] && [ "$BUILD_STATUS" = "succès" ] && return 0

    echo
    echo -e "${C_STEP}=========================================${C_RESET}"
    echo -e "${C_STEP} Résumé de l'installation${C_RESET}"
    echo -e "${C_STEP}=========================================${C_RESET}"
    echo "Projet (dossier)     : ${PROJECT_DIRNAME:-inconnu}"
    echo "Système de build     : $DETECTED_BUILD_SYSTEM"
    echo "Statut final         : $BUILD_STATUS"
    echo "Temps écoulé         : ${elapsed}s"
    if [ "${#INSTALLED_DEPS[@]}" -gt 0 ]; then
        echo "Dépendances installées :"
        printf '   - %s\n' "${INSTALLED_DEPS[@]}"
    else
        echo "Dépendances installées : aucune"
    fi
    echo "Fichier de log       : $LOG_FILE"
    if [ "$NEEDS_PATH_NOTICE" -eq 1 ] && [ "$BUILD_STATUS" = "succès" ]; then
        echo
        echo "Rappel : de nombreux projets autotools/cmake/meson s'installent par"
        echo "défaut sous /usr/local (ex : ncurses sans --prefix). Le cache des"
        echo "bibliothèques a été rafraîchi (ldconfig), mais si une commande"
        echo "reste introuvable, vérifiez que /usr/local/bin est dans votre PATH :"
        echo "  echo \$PATH"
        echo "Si besoin, ouvrez un nouveau terminal ou faites : hash -r"
    fi
    echo -e "${C_STEP}=========================================${C_RESET}"
}

# =========================================================
# Lecture des arguments
# =========================================================
#
# Le premier argument positionnel (s'il existe et ne commence pas par "--")
# est la SOURCE : soit une URL (http/https/ftp), soit un chemin absolu vers
# une archive déjà présente sur le disque. S'il est absent, le script bascule
# en mode interactif et demande à l'utilisateur de choisir.

SOURCE_ARG=""

if [ "$#" -ge 1 ] && [[ "$1" != --* ]]; then
    SOURCE_ARG="$1"
    shift
fi

for arg in "$@"; do
    case "$arg" in
        --verbose) VERBOSE=1 ;;
        --quiet) QUIET=1 ;;
        --clean) CLEAN_MODE="yes" ;;
        --no-clean) CLEAN_MODE="no" ;;
        --checkinstall) USE_CHECKINSTALL=1 ;;
        --max-retries=*) MAX_RETRIES="${arg#*=}" ;;
        --sha256=*) EXPECTED_SHA256="${arg#*=}" ;;
        *)
            log_warn "Option inconnue ignorée : $arg"
            ;;
    esac
done

if [ "$VERBOSE" -eq 1 ] && [ "$QUIET" -eq 1 ]; then
    echo "Erreur : --verbose et --quiet sont incompatibles."
    exit 1
fi

# Réinitialise le log à chaque exécution
: > "$LOG_FILE"

# =========================================================
# Détermination de la source : URL / archive locale / interactif
# =========================================================

is_url() {
    case "$1" in
        http://*|https://*|ftp://*) return 0 ;;
        *) return 1 ;;
    esac
}

ask_source_interactively() {
    echo
    echo -e "${C_STEP}=========================================${C_RESET}"
    echo " AutoDeploy Ultimate - Sélection de la source"
    echo -e "${C_STEP}=========================================${C_RESET}"
    echo "Comment voulez-vous fournir le programme à installer ?"
    echo
    echo "  1) Télécharger depuis un lien (URL)"
    echo "  2) Utiliser une archive déjà présente sur le disque (chemin absolu)"
    echo

    local choice=""
    while true; do
        read -r -p "Votre choix [1/2] : " choice
        case "$choice" in
            1) SOURCE_MODE="url"; break ;;
            2) SOURCE_MODE="local"; break ;;
            *) echo "Choix invalide, entrez 1 ou 2." ;;
        esac
    done

    if [ "$SOURCE_MODE" = "url" ]; then
        while true; do
            read -r -p "Entrez l'URL de l'archive à télécharger : " URL
            if [ -z "$URL" ]; then
                echo "URL vide, réessayez."
                continue
            fi
            if ! is_url "$URL"; then
                echo "Cela ne ressemble pas à une URL valide (http://, https:// ou ftp://). Réessayez."
                continue
            fi
            break
        done
    else
        while true; do
            read -r -p "Entrez le chemin absolu de l'archive (.tar.gz, .tgz, .tar.bz2, .tar.xz, .zip) : " LOCAL_ARCHIVE_PATH
            if [ -z "$LOCAL_ARCHIVE_PATH" ]; then
                echo "Chemin vide, réessayez."
                continue
            fi
            case "$LOCAL_ARCHIVE_PATH" in
                /*) : ;;
                *)
                    echo "Le chemin doit être absolu (commencer par /). Réessayez."
                    continue
                    ;;
            esac
            if [ ! -f "$LOCAL_ARCHIVE_PATH" ]; then
                echo "Fichier introuvable : $LOCAL_ARCHIVE_PATH. Réessayez."
                continue
            fi
            break
        done
    fi
}

if [ -n "$SOURCE_ARG" ]; then
    # Mode direct (rétrocompatible) : on détermine le type de source à partir
    # de l'unique argument positionnel.
    if is_url "$SOURCE_ARG"; then
        SOURCE_MODE="url"
        URL="$SOURCE_ARG"
    elif [ -f "$SOURCE_ARG" ]; then
        SOURCE_MODE="local"
        LOCAL_ARCHIVE_PATH="$SOURCE_ARG"
    else
        log_error "Argument source non reconnu : '$SOURCE_ARG' n'est ni une URL (http/https/ftp) ni un fichier existant."
        exit 1
    fi
else
    # Aucun argument source : mode interactif.
    if [ ! -t 0 ]; then
        echo "Usage: $0 <URL_ou_chemin_absolu_archive> [--verbose|--quiet] [--clean|--no-clean]"
        echo "             [--checkinstall] [--max-retries=N] [--sha256=HASH]"
        echo "Erreur : aucune source fournie et entrée non interactive (pas de terminal)."
        exit 1
    fi
    ask_source_interactively
fi

if [ "$SOURCE_MODE" = "local" ]; then
    LOCAL_ARCHIVE_PATH=$(readlink -f -- "$LOCAL_ARCHIVE_PATH" 2>/dev/null || echo "$LOCAL_ARCHIVE_PATH")
    case "$LOCAL_ARCHIVE_PATH" in
        *.tar.gz|*.tgz|*.tar.bz2|*.tar.xz|*.zip) : ;;
        *)
            log_error "Extension d'archive non reconnue pour : $LOCAL_ARCHIVE_PATH (attendu .tar.gz, .tgz, .tar.bz2, .tar.xz ou .zip)"
            exit 1
            ;;
    esac
    ARCHIVE=$(basename "$LOCAL_ARCHIVE_PATH")
else
    CLEAN_URL="${URL%%\?*}"
    ARCHIVE=$(basename "$CLEAN_URL")
fi

# =========================================================
# Étape 1 : Vérification connexion (sans dépendre d'ICMP)
# (uniquement nécessaire en mode "url" ; sautée en mode "local")
# =========================================================

if [ "$SOURCE_MODE" = "url" ]; then
    log_step "Vérification de la connexion réseau"

    if ! wget --spider --timeout=10 -q "https://www.google.com" \
        && ! wget --spider --timeout=10 -q "$URL"; then
        log_error "Pas de connexion Internet (ou hôte inaccessible). ICMP n'est pas utilisé : certains réseaux d'entreprise le bloquent sans bloquer le HTTP."
        exit 1
    fi

    log_ok "Connexion réseau disponible."
else
    log_step "Mode archive locale : vérification réseau ignorée"
    log_info "Archive locale fournie : $LOCAL_ARCHIVE_PATH"
fi

# =========================================================
# Étape 2 : Installation des outils essentiels minimaux
# (Les toolchains spécifiques (rust, go, node...) sont installés
#  plus tard, uniquement si le projet en a réellement besoin.)
# =========================================================

log_step "Installation des outils essentiels (base uniquement)"

BASE_PACKAGES=(
    build-essential
    wget
    curl
    tar
    gzip
    bzip2
    xz-utils
    unzip
    git
    pkg-config
    autoconf
    automake
    libtool
    apt-file
    coreutils
)

run_step "apt-get update" sudo apt-get update -qq

for pkg in "${BASE_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" > /dev/null 2>&1; then
        if run_step "Installation de $pkg" sudo apt-get install -y "$pkg"; then
            INSTALLED_DEPS+=("$pkg")
        fi
    fi
done

# apt-file ne sert à rien sans une base à jour : on la met à jour une fois.
run_step "Mise à jour de la base apt-file" sudo apt-file update

# =========================================================
# Fonction de vérification d'intégrité d'archive
# =========================================================

verify_checksum() {
    [ -z "$EXPECTED_SHA256" ] && return 0

    log_info "Vérification du SHA256 de l'archive..."
    local actual
    actual=$(sha256sum "$ARCHIVE" | awk '{print $1}')

    if [ "$actual" != "$EXPECTED_SHA256" ]; then
        log_error "SHA256 invalide. Attendu=$EXPECTED_SHA256 Obtenu=$actual"
        return 1
    fi

    log_ok "SHA256 vérifié."
    return 0
}

# Vérifie que le fichier téléchargé est bien une archive, et pas une page
# d'erreur HTML (cas d'un lien mort renvoyant un 404 avec contenu HTML).
verify_downloaded_file() {
    if [ ! -s "$ARCHIVE" ]; then
        log_error "Fichier téléchargé vide ou absent."
        return 1
    fi

    local mime
    mime=$(file --brief --mime-type "$ARCHIVE")

    case "$mime" in
        text/html|text/xml|text/plain)
            log_error "Le fichier téléchargé semble être une page texte/HTML (mime=$mime), pas une archive. URL probablement invalide (404 ?)."
            return 1
            ;;
    esac

    case "$ARCHIVE" in
        *.tar.gz|*.tgz|*.tar.bz2|*.tar.xz)
            if ! tar -tf "$ARCHIVE" > /dev/null 2>&1; then
                log_error "L'archive tar semble corrompue ou illisible (mime=$mime)."
                return 1
            fi
            ;;
        *.zip)
            if ! unzip -tqq "$ARCHIVE" > /dev/null 2>&1; then
                log_error "L'archive zip semble corrompue ou illisible (mime=$mime)."
                return 1
            fi
            ;;
    esac

    return 0
}

# =========================================================
# Étape 3 : Récupération de l'archive (téléchargement OU copie locale)
# =========================================================

if [ "$SOURCE_MODE" = "url" ]; then
    log_step "Téléchargement de l'archive : $ARCHIVE"

    if ! run_step "Téléchargement" wget --content-disposition -O "$ARCHIVE" "$URL"; then
        exit 1
    fi

    # wget --content-disposition peut renommer le fichier : on récupère le nom réel
    if [ ! -f "$ARCHIVE" ]; then
        REAL_NAME=$(find . -maxdepth 1 -type f -newer "$LOG_FILE" -printf '%f\n' 2>/dev/null | head -n1)
        [ -n "$REAL_NAME" ] && ARCHIVE="$REAL_NAME"
    fi
else
    log_step "Préparation de l'archive locale : $ARCHIVE"

    if [ "$(readlink -f -- "$LOCAL_ARCHIVE_PATH" 2>/dev/null)" != "$(readlink -f -- "$WORKDIR/$ARCHIVE" 2>/dev/null)" ]; then
        if ! run_step "Copie de l'archive locale vers $WORKDIR" cp -- "$LOCAL_ARCHIVE_PATH" "$WORKDIR/$ARCHIVE"; then
            exit 1
        fi
    else
        log_info "L'archive est déjà dans le répertoire de travail, pas de copie nécessaire."
    fi
fi

if ! verify_downloaded_file; then
    exit 1
fi

if ! verify_checksum; then
    exit 1
fi

if [ "$SOURCE_MODE" = "url" ]; then
    log_ok "Archive téléchargée et vérifiée : $ARCHIVE"
else
    log_ok "Archive locale vérifiée : $ARCHIVE"
fi
WORK_STARTED="oui"

# =========================================================
# Étape 4 : Extraction + détection fiable du dossier
# =========================================================

log_step "Extraction de l'archive"

# Snapshot AVANT extraction : seul moyen fiable de savoir ce qui a été créé,
# plutôt que de deviner via "le dossier le plus récent" (faux si l'utilisateur
# a d'autres dossiers récents dans le même répertoire de travail).
BEFORE_LIST=$(find . -maxdepth 1 -type d ! -name "." | sort)

case "$ARCHIVE" in
    *.tar.gz|*.tgz)
        run_step "Extraction tar.gz" tar -xzf "$ARCHIVE"
        ;;
    *.tar.xz)
        run_step "Extraction tar.xz" tar -xJf "$ARCHIVE"
        ;;
    *.tar.bz2)
        run_step "Extraction tar.bz2" tar -xjf "$ARCHIVE"
        ;;
    *.zip)
        run_step "Extraction zip" unzip -o "$ARCHIVE"
        ;;
    *)
        log_error "Format d'archive non supporté : $ARCHIVE"
        exit 1
        ;;
esac

if [ "$?" -ne 0 ]; then
    log_error "Extraction échouée."
    exit 1
fi

AFTER_LIST=$(find . -maxdepth 1 -type d ! -name "." | sort)

# Le dossier extrait = la différence entre AVANT et APRÈS extraction.
NEW_DIRS=$(comm -13 <(echo "$BEFORE_LIST") <(echo "$AFTER_LIST"))
NEW_DIR_COUNT=$(echo "$NEW_DIRS" | grep -c . || true)

if [ "$NEW_DIR_COUNT" -eq 1 ]; then
    DIRNAME=$(echo "$NEW_DIRS" | head -n1)
elif [ "$NEW_DIR_COUNT" -gt 1 ]; then
    # Plusieurs dossiers nouveaux : on prend celui qui contient un fichier
    # de build reconnu, plutôt qu'un choix arbitraire.
    DIRNAME=""
    while IFS= read -r d; do
        for marker in configure configure.ac configure.in autogen.sh \
                       CMakeLists.txt meson.build Cargo.toml go.mod \
                       package.json Makefile makefile; do
            if [ -f "$d/$marker" ]; then
                DIRNAME="$d"
                break 2
            fi
        done
    done <<< "$NEW_DIRS"
    [ -z "$DIRNAME" ] && DIRNAME=$(echo "$NEW_DIRS" | head -n1)
    log_warn "Plusieurs dossiers créés par l'extraction ; sélection : $DIRNAME"
else
    # Archive "à plat" (pas de sous-dossier) : on travaille dans le répertoire courant.
    log_warn "Aucun nouveau dossier détecté (archive probablement extraite à plat ici)."
    DIRNAME="."
fi

cd "$DIRNAME" || { log_error "Impossible d'entrer dans $DIRNAME"; exit 1; }

PROJECT_DIRNAME="$DIRNAME"
log_ok "Dossier de projet détecté : $(pwd)"

# =========================================================
# Détection / installation de dépendances manquantes (configure)
# =========================================================

install_missing_dependencies() {
    local found_any=0

    if [ -f config.log ]; then
        local missing_headers
        missing_headers=$(grep -i "No such file or directory" config.log \
            | grep "\.h" \
            | awk '{print $NF}' \
            | tr -d '<>:"' \
            | sort -u)

        for header in $missing_headers; do
            local pkg
            pkg=$(apt-file search "$header" 2>/dev/null | head -n1 | cut -d: -f1)

            if [ -n "$pkg" ] && ! dpkg -s "$pkg" > /dev/null 2>&1; then
                log_info "Dépendance détectée via config.log : $pkg (pour $header)"
                if run_step "Installation de $pkg" sudo apt-get install -y "$pkg"; then
                    INSTALLED_DEPS+=("$pkg")
                    found_any=1
                fi
            fi
        done
    fi

    # Complément : certains projets exposent leurs dépendances via pkg-config
    # (fichiers .pc requis) plutôt que via des erreurs de header dans config.log.
    local missing_pc
    missing_pc=$(grep -iE "Package .* was not found|Requested .* not found" config.log 2>/dev/null \
        | grep -oE "[A-Za-z0-9_.-]+\.pc|[A-Za-z0-9_-]+>= [0-9.]+" \
        | sed 's/>=.*//' | tr -d ' ' | sort -u)

    for pc in $missing_pc; do
        local pkgname="${pc%.pc}"
        local pkg
        pkg=$(apt-file search "${pkgname}.pc" 2>/dev/null | head -n1 | cut -d: -f1)
        if [ -n "$pkg" ] && ! dpkg -s "$pkg" > /dev/null 2>&1; then
            log_info "Dépendance pkg-config détectée : $pkg"
            if run_step "Installation de $pkg" sudo apt-get install -y "$pkg"; then
                INSTALLED_DEPS+=("$pkg")
                found_any=1
            fi
        fi
    done

    return $((1 - found_any))
}

# =========================================================
# Fonctions génériques (factorisation make / make install / checkinstall)
# =========================================================

compile() {
    # compile <description>
    run_step "$1 (make -j$(nproc))" make -j"$(nproc)"
}

do_install() {
    # do_install <description du contexte>
    local install_status

    if [ "$USE_CHECKINSTALL" -eq 1 ]; then
        if ! command -v checkinstall > /dev/null 2>&1; then
            run_step "Installation de checkinstall" sudo apt-get install -y checkinstall
            INSTALLED_DEPS+=("checkinstall")
        fi
        run_step "$1 (checkinstall)" sudo checkinstall -y
        install_status=$?
    else
        run_step "$1 (make install)" sudo make install
        install_status=$?
    fi

    if [ "$install_status" -eq 0 ]; then
        # make install ne met pas à jour le cache des bibliothèques partagées.
        # Sans ce rafraîchissement, un programme installé sous /usr/local/lib
        # (préfixe par défaut de nombreux projets autotools, dont ncurses)
        # reste invisible pour le système même si l'installation a réussi.
        run_step "Mise à jour du cache des bibliothèques (ldconfig)" sudo ldconfig
        NEEDS_PATH_NOTICE=1
    fi

    return "$install_status"
}

# =========================================================
# AUTOTOOLS (configure / configure.ac / configure.in / autogen.sh)
# =========================================================

build_autotools() {
    DETECTED_BUILD_SYSTEM="autotools"
    log_info "Système détecté : AUTOTOOLS"

    if [ ! -f configure ]; then
        if [ -f autogen.sh ]; then
            log_info "configure absent : exécution de autogen.sh"
            chmod +x autogen.sh
            run_step "autogen.sh" ./autogen.sh
        elif [ -f configure.ac ] || [ -f configure.in ]; then
            log_info "configure absent : exécution de autoreconf -fi"
            if ! command -v autoreconf > /dev/null 2>&1; then
                run_step "Installation autoconf/automake/libtool" sudo apt-get install -y autoconf automake libtool
            fi
            run_step "autoreconf -fi" autoreconf -fi
        fi
    fi

    if [ ! -f configure ]; then
        log_error "Aucun script configure n'a pu être généré."
        BUILD_STATUS="échec"
        return 1
    fi

    chmod +x configure

    local attempt=1
    local configure_ok=0

    while [ "$attempt" -le "$MAX_RETRIES" ]; do
        log_info "Tentative configure $attempt/$MAX_RETRIES"

        if run_step "./configure" ./configure; then
            configure_ok=1
            break
        fi

        install_missing_dependencies
        local install_status=$?

        if [ "$install_status" -ne 0 ]; then
            log_warn "Aucune nouvelle dépendance trouvée à installer automatiquement."
        fi

        attempt=$((attempt + 1))
    done

    if [ "$configure_ok" -ne 1 ]; then
        log_error "configure a échoué après $MAX_RETRIES tentatives. Abandon (plus de boucle infinie)."
        BUILD_STATUS="échec"
        return 1
    fi

    if ! compile "Compilation autotools"; then
        BUILD_STATUS="échec (make)"
        return 1
    fi

    if ! do_install "Installation autotools"; then
        BUILD_STATUS="échec (make install)"
        return 1
    fi

    BUILD_STATUS="succès"
    return 0
}

# =========================================================
# CMAKE
# =========================================================

build_cmake() {
    DETECTED_BUILD_SYSTEM="cmake"
    log_info "Système détecté : CMAKE"

    mkdir -p build
    cd build || { log_error "Impossible de créer/entrer dans build/"; BUILD_STATUS="échec"; return 1; }

    if ! run_step "cmake .." cmake ..; then
        BUILD_STATUS="échec (cmake)"
        return 1
    fi

    if ! compile "Compilation cmake"; then
        BUILD_STATUS="échec (make)"
        return 1
    fi

    if ! do_install "Installation cmake"; then
        BUILD_STATUS="échec (make install)"
        return 1
    fi

    BUILD_STATUS="succès"
    return 0
}

# =========================================================
# MESON
# =========================================================

build_meson() {
    DETECTED_BUILD_SYSTEM="meson"
    log_info "Système détecté : MESON"

    if ! command -v meson > /dev/null 2>&1 || ! command -v ninja > /dev/null 2>&1; then
        run_step "Installation de meson/ninja-build" sudo apt-get install -y meson ninja-build
        INSTALLED_DEPS+=("meson" "ninja-build")
    fi

    if ! run_step "meson setup build" meson setup build; then
        BUILD_STATUS="échec (meson setup)"
        return 1
    fi

    if ! run_step "ninja -C build" ninja -C build; then
        BUILD_STATUS="échec (ninja)"
        return 1
    fi

    if [ "$USE_CHECKINSTALL" -eq 1 ]; then
        log_warn "checkinstall n'est pas compatible avec ninja install ; utilisation de 'sudo ninja install'."
    fi

    if ! run_step "ninja -C build install" sudo ninja -C build install; then
        BUILD_STATUS="échec (ninja install)"
        return 1
    fi

    BUILD_STATUS="succès"
    return 0
}

# =========================================================
# CARGO / RUST
# =========================================================

build_cargo() {
    DETECTED_BUILD_SYSTEM="cargo/rust"
    log_info "Système détecté : CARGO / RUST"

    if ! command -v cargo > /dev/null 2>&1; then
        log_info "Rust/Cargo requis par ce projet : installation à la demande."
        run_step "Installation cargo/rustc" sudo apt-get install -y cargo rustc
        INSTALLED_DEPS+=("cargo" "rustc")
    fi

    if ! run_step "cargo build --release" cargo build --release; then
        BUILD_STATUS="échec (cargo build)"
        return 1
    fi

    if ! run_step "cargo install --path ." sudo cargo install --path .; then
        BUILD_STATUS="échec (cargo install)"
        return 1
    fi

    BUILD_STATUS="succès"
    return 0
}

# =========================================================
# GO
# =========================================================

build_go() {
    DETECTED_BUILD_SYSTEM="go"
    log_info "Système détecté : GO"

    if ! command -v go > /dev/null 2>&1; then
        log_info "Go requis par ce projet : installation à la demande."
        run_step "Installation golang" sudo apt-get install -y golang
        INSTALLED_DEPS+=("golang")
    fi

    if ! run_step "go build" go build; then
        BUILD_STATUS="échec (go build)"
        return 1
    fi

    BUILD_STATUS="succès"
    return 0
}

# =========================================================
# NODEJS
# =========================================================

build_node() {
    DETECTED_BUILD_SYSTEM="nodejs"
    log_info "Système détecté : NODEJS"

    if ! command -v npm > /dev/null 2>&1; then
        log_info "Node.js/npm requis par ce projet : installation à la demande."
        run_step "Installation nodejs/npm" sudo apt-get install -y nodejs npm
        INSTALLED_DEPS+=("nodejs" "npm")
    fi

    if ! run_step "npm install" npm install; then
        BUILD_STATUS="échec (npm install)"
        return 1
    fi

    if ! run_step "npm run build" npm run build; then
        log_warn "npm run build a échoué (script 'build' peut-être absent : non bloquant)."
    fi

    BUILD_STATUS="succès"
    return 0
}

# =========================================================
# MAKEFILE SIMPLE
# =========================================================

build_makefile() {
    DETECTED_BUILD_SYSTEM="makefile"
    log_info "Système détecté : MAKEFILE"

    if ! compile "Compilation makefile"; then
        BUILD_STATUS="échec (make)"
        return 1
    fi

    if ! do_install "Installation makefile"; then
        BUILD_STATUS="échec (make install)"
        return 1
    fi

    BUILD_STATUS="succès"
    return 0
}

# =========================================================
# Étape 5 : Détection du système de build et compilation
# =========================================================

log_step "Détection du système de build et compilation"

BUILD_RESULT=1

if [ -f configure ] || [ -f configure.ac ] || [ -f configure.in ] || [ -f autogen.sh ]; then
    build_autotools
    BUILD_RESULT=$?
elif [ -f CMakeLists.txt ]; then
    build_cmake
    BUILD_RESULT=$?
elif [ -f meson.build ]; then
    build_meson
    BUILD_RESULT=$?
elif [ -f Cargo.toml ]; then
    build_cargo
    BUILD_RESULT=$?
elif [ -f go.mod ]; then
    build_go
    BUILD_RESULT=$?
elif [ -f package.json ]; then
    build_node
    BUILD_RESULT=$?
elif [ -f Makefile ] || [ -f makefile ]; then
    build_makefile
    BUILD_RESULT=$?
else
    log_error "Aucun système de build supporté détecté dans $(pwd)."
    BUILD_STATUS="échec (système de build inconnu)"
    BUILD_RESULT=1
fi

# =========================================================
# Étape 6 : Fin
# =========================================================

log_step "Finalisation"

if [ "$BUILD_RESULT" -eq 0 ]; then
    log_ok "Installation terminée avec succès."
else
    log_error "Installation terminée avec des erreurs. Consultez $LOG_FILE."
fi

cd "$WORKDIR" || true

exit "$BUILD_RESULT"
