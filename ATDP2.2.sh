#!/bin/bash
#
# install_from_source.sh — Installation automatique d'un projet GNU Make
#                           à partir d'une archive .tar.gz / .tar.bz2 / .tar.xz / .zip
#
# Usage :
#   ./install_from_source.sh <URL_de_l'archive>     (mode direct, comme avant)
#   ./install_from_source.sh                        (mode interactif)
#
# En mode interactif, le script demande à l'utilisateur de choisir entre :
#   1) Télécharger l'archive depuis un lien (URL)
#   2) Utiliser une archive déjà présente sur le disque (chemin absolu)
#
# Architecture :
#   main()
#    ├── prompt_user_choice()       (mode interactif uniquement)
#    ├── check_dependencies()
#    ├── download_archive()         (option "lien")
#    ├── use_local_archive()        (option "chemin absolu")
#    ├── verify_archive()
#    ├── extract_archive()
#    ├── locate_source_directory()
#    ├── detect_build_system()
#    ├── configure_project()
#    ├── compile_project()
#    ├── install_project()
#    └── cleanup()
#
set -u  # variable non définie = erreur (on garde le contrôle manuel des codes de retour)

# ----------------------------------------------------------------------------
# Configuration globale
# ----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/install_errors.log"
WORK_DIR=""        # créé dans main(), nettoyé par cleanup()
ARCHIVE_PATH=""
SRC_DIR=""

# Dictionnaire en-tête -> paquet Debian/Ubuntu (plus fiable que apt-cache search)
declare -A HEADER_TO_PKG=(
    ["openssl/ssl.h"]="libssl-dev"
    ["openssl/evp.h"]="libssl-dev"
    ["zlib.h"]="zlib1g-dev"
    ["curl/curl.h"]="libcurl4-openssl-dev"
    ["libxml2/libxml/parser.h"]="libxml2-dev"
    ["png.h"]="libpng-dev"
    ["jpeglib.h"]="libjpeg-dev"
    ["ncurses.h"]="libncurses-dev"
    ["readline/readline.h"]="libreadline-dev"
    ["gtk/gtk.h"]="libgtk-3-dev"
    ["glib.h"]="libglib2.0-dev"
    ["pcre.h"]="libpcre3-dev"
    ["sqlite3.h"]="libsqlite3-dev"
    ["ffi.h"]="libffi-dev"
    ["bz2lib.h"]="libbz2-dev"
    ["lzma.h"]="liblzma-dev"
)

# Mots-clés signalant une dépendance manquante dans config.log / un log de build
MISSING_DEP_PATTERNS=(
    "No such file or directory"
    "not found"
    "required"
    "missing"
    "fatal error"
    "cannot find"
    "No package"
)

# ----------------------------------------------------------------------------
# Utilitaires de log
# ----------------------------------------------------------------------------

log() {
    # log <niveau> <message>
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] [$level] $msg" | tee -a "$LOG_FILE" >&2
}

log_info()  { log "INFO"  "$*"; }
log_warn()  { log "WARN"  "$*"; }
log_error() { log "ERROR" "$*"; }

die() {
    log_error "$*"
    log_error "Arrêt du script. Consultez $LOG_FILE pour le détail."
    cleanup
    exit 1
}

# ----------------------------------------------------------------------------
# 0. Dépendances système de base
# ----------------------------------------------------------------------------

check_dependencies() {
    log_info "Vérification des outils de base (build-essential, wget, tar, unzip)..."

    if ! sudo apt-get update -qq; then
        die "Impossible de mettre à jour la liste des paquets (apt-get update)."
    fi

    if ! sudo apt-get install -y build-essential wget tar unzip autoconf automake libtool pkg-config; then
        die "Impossible d'installer les outils de compilation de base."
    fi
}

# ----------------------------------------------------------------------------
# 1. Téléchargement (corrige le bug d'ordre wget / tar -tf)
# ----------------------------------------------------------------------------

download_archive() {
    local url="$1"
    local filename

    filename="$(basename "${url%%\?*}")"
    if [ -z "$filename" ]; then
        die "Impossible de déduire un nom de fichier depuis l'URL : $url"
    fi

    ARCHIVE_PATH="$WORK_DIR/$filename"

    log_info "Téléchargement de $url ..."
    if ! wget -q --show-progress -O "$ARCHIVE_PATH" "$url"; then
        die "Le téléchargement a échoué (wget a retourné une erreur)."
    fi

    if [ ! -s "$ARCHIVE_PATH" ]; then
        die "Le fichier téléchargé est vide ou introuvable : $ARCHIVE_PATH"
    fi

    log_info "Téléchargement terminé : $ARCHIVE_PATH"
}

# ----------------------------------------------------------------------------
# 1bis. Utilisation d'une archive déjà présente sur le disque (chemin absolu)
# ----------------------------------------------------------------------------

use_local_archive() {
    local path="$1"

    if [[ "$path" != /* ]]; then
        die "Le chemin fourni n'est pas un chemin absolu : $path"
    fi

    if [ ! -f "$path" ]; then
        die "Aucun fichier trouvé à ce chemin : $path"
    fi

    if [ ! -s "$path" ]; then
        die "Le fichier est vide : $path"
    fi

    log_info "Utilisation de l'archive locale : $path"

    # On copie l'archive dans WORK_DIR pour rester cohérent avec le reste du script
    # (extraction, nettoyage, etc. se font tous dans WORK_DIR)
    local filename
    filename="$(basename "$path")"
    ARCHIVE_PATH="$WORK_DIR/$filename"

    if ! cp -- "$path" "$ARCHIVE_PATH"; then
        die "Impossible de copier l'archive locale vers le répertoire de travail."
    fi

    log_info "Archive locale prête : $ARCHIVE_PATH"
}

# ----------------------------------------------------------------------------
# 2. Vérification de l'archive (intégrité + type)
# ----------------------------------------------------------------------------

# Renseigne ARCHIVE_KIND: tar | zip
ARCHIVE_KIND=""

verify_archive() {
    log_info "Vérification de l'intégrité de l'archive..."

    case "$ARCHIVE_PATH" in
        *.zip)
            ARCHIVE_KIND="zip"
            if ! unzip -tq "$ARCHIVE_PATH" >/dev/null 2>>"$LOG_FILE"; then
                die "Archive ZIP corrompue ou invalide : $ARCHIVE_PATH"
            fi
            ;;
        *.tar.gz|*.tgz|*.tar.bz2|*.tbz2|*.tar.xz|*.txz|*.tar)
            ARCHIVE_KIND="tar"
            if ! tar -tf "$ARCHIVE_PATH" >/dev/null 2>>"$LOG_FILE"; then
                die "Archive tar corrompue, invalide, ou le téléchargement n'est pas une archive valide : $ARCHIVE_PATH"
            fi
            ;;
        *)
            die "Extension d'archive non reconnue : $ARCHIVE_PATH (attendu .tar.gz, .tar.bz2, .tar.xz ou .zip)"
            ;;
    esac

    log_info "Archive valide (type: $ARCHIVE_KIND)."
}

# ----------------------------------------------------------------------------
# 3. Extraction
# ----------------------------------------------------------------------------

extract_archive() {
    log_info "Décompression de $ARCHIVE_PATH ..."

    local extract_dir="$WORK_DIR/extracted"
    mkdir -p "$extract_dir"

    if [ "$ARCHIVE_KIND" = "zip" ]; then
        if ! unzip -q "$ARCHIVE_PATH" -d "$extract_dir" 2>>"$LOG_FILE"; then
            die "Échec de l'extraction de l'archive ZIP."
        fi
    else
        if ! tar -xf "$ARCHIVE_PATH" -C "$extract_dir" 2>>"$LOG_FILE"; then
            die "Échec de l'extraction de l'archive tar."
        fi
    fi

    log_info "Extraction terminée dans $extract_dir"
    echo "$extract_dir"
}

# ----------------------------------------------------------------------------
# 4. Localisation robuste du répertoire source extrait
# ----------------------------------------------------------------------------

locate_source_directory() {
    local extract_dir="$1"
    local -a top_entries=()

    while IFS= read -r -d '' entry; do
        top_entries+=("$entry")
    done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -print0)

    local -a top_dirs=()
    for entry in "${top_entries[@]}"; do
        [ -d "$entry" ] && top_dirs+=("$entry")
    done

    if [ "${#top_entries[@]}" -eq 1 ] && [ -d "${top_entries[0]}" ]; then
        # Cas classique : un seul dossier racine dans l'archive
        echo "${top_entries[0]}"
        return 0
    fi

    if [ "${#top_dirs[@]}" -ge 1 ]; then
        # Plusieurs entrées : on cherche celle qui ressemble à un projet source
        local d
        for d in "${top_dirs[@]}"; do
            if [ -f "$d/configure" ] || [ -f "$d/configure.ac" ] || \
               [ -f "$d/configure.in" ] || [ -f "$d/Makefile" ] || \
               [ -f "$d/Makefile.am" ] || [ -f "$d/autogen.sh" ]; then
                echo "$d"
                return 0
            fi
        done
        # Aucun indicateur trouvé : on prend le premier dossier par défaut
        echo "${top_dirs[0]}"
        return 0
    fi

    # L'archive a extrait directement des fichiers à plat (pas de sous-dossier)
    if [ "${#top_entries[@]}" -gt 0 ]; then
        echo "$extract_dir"
        return 0
    fi

    die "Aucun répertoire ou fichier source trouvé après extraction."
}

# ----------------------------------------------------------------------------
# 5. Détection du système de build et génération de ./configure si besoin
# ----------------------------------------------------------------------------

detect_build_system() {
    cd "$SRC_DIR" || die "Impossible d'entrer dans $SRC_DIR"

    if [ -f "./configure" ]; then
        log_info "configure trouvé."
        BUILD_MODE="configure"
        return 0
    fi

    if [ -f "./autogen.sh" ]; then
        log_info "configure absent, autogen.sh trouvé. Exécution de autogen.sh..."
        chmod +x ./autogen.sh
        if ./autogen.sh 2>&1 | tee -a "$LOG_FILE"; then
            if [ -f "./configure" ]; then
                log_info "configure généré avec succès par autogen.sh."
                BUILD_MODE="configure"
                return 0
            fi
        fi
        log_warn "autogen.sh n'a pas produit de script configure exploitable."
    fi

    if [ -f "./configure.ac" ] || [ -f "./configure.in" ]; then
        log_info "configure absent, configure.ac/.in trouvé. Exécution de autoreconf -i..."
        if autoreconf -i 2>&1 | tee -a "$LOG_FILE" && [ -f "./configure" ]; then
            log_info "configure généré avec succès par autoreconf."
            BUILD_MODE="configure"
            return 0
        fi
        log_warn "autoreconf n'a pas réussi à générer configure."
    fi

    if [ -f "./Makefile" ] || [ -f "./makefile" ]; then
        log_info "Pas de configure nécessaire, Makefile déjà présent."
        BUILD_MODE="make_only"
        return 0
    fi

    if [ -f "./Makefile.am" ]; then
        log_warn "Makefile.am présent sans configure.ac : tentative d'automake seul."
        if automake --add-missing 2>&1 | tee -a "$LOG_FILE" && [ -f "./Makefile" ]; then
            BUILD_MODE="make_only"
            return 0
        fi
    fi

    die "Système de build non reconnu dans $SRC_DIR (ni configure, ni autogen.sh, ni configure.ac, ni Makefile)."
}

# ----------------------------------------------------------------------------
# 6. Détection et installation automatique des dépendances manquantes
# ----------------------------------------------------------------------------

extract_missing_headers() {
    # Lit un fichier de log et extrait les noms d'en-têtes .h potentiellement manquants
    local logfile="$1"
    [ -f "$logfile" ] || return 0

    grep -iE "$(IFS='|'; echo "${MISSING_DEP_PATTERNS[*]}")" "$logfile" \
        | grep -oE "[A-Za-z0-9_./-]+\.h" \
        | sort -u
}

install_missing_dependencies() {
    local logfile="$1"
    local missing
    missing="$(extract_missing_headers "$logfile")"

    if [ -z "$missing" ]; then
        return 1   # rien trouvé
    fi

    local header pkg installed_any=1
    while IFS= read -r header; do
        [ -z "$header" ] && continue

        pkg="${HEADER_TO_PKG[$header]:-}"

        if [ -z "$pkg" ]; then
            # essai avec juste le nom de base (ex: ssl.h plutôt que openssl/ssl.h)
            local base="${header##*/}"
            for key in "${!HEADER_TO_PKG[@]}"; do
                if [ "${key##*/}" = "$base" ]; then
                    pkg="${HEADER_TO_PKG[$key]}"
                    break
                fi
            done
        fi

        if [ -z "$pkg" ]; then
            # dernier recours : apt-cache search, en gardant un résultat plausible
            pkg="$(apt-cache search "$base" 2>/dev/null | awk '{print $1}' | grep -E '\-dev$' | head -n1)"
        fi

        if [ -n "$pkg" ]; then
            log_info "Dépendance manquante '$header' -> installation de '$pkg'..."
            if sudo apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
                installed_any=0
            fi
        else
            log_warn "Impossible de déterminer le paquet correspondant à '$header'."
        fi
    done <<< "$missing"

    return $installed_any
}

# ----------------------------------------------------------------------------
# 7. ./configure avec boucle de résolution automatique des dépendances
# ----------------------------------------------------------------------------

configure_project() {
    if [ "$BUILD_MODE" = "make_only" ]; then
        log_info "Aucune étape configure nécessaire."
        return 0
    fi

    chmod +x ./configure

    local max_attempts=8
    local attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        log_info "Exécution de ./configure (tentative $attempt/$max_attempts)..."

        if ./configure 2>&1 | tee -a "$LOG_FILE"; then
            log_info "./configure a réussi."
            return 0
        fi

        log_warn "./configure a échoué, recherche de dépendances manquantes..."

        if [ ! -f config.log ]; then
            die "configure a échoué et aucun config.log n'est disponible pour diagnostiquer."
        fi

        if ! install_missing_dependencies "config.log"; then
            die "configure continue d'échouer et aucune dépendance supplémentaire n'a pu être identifiée. Consultez config.log."
        fi

        attempt=$((attempt + 1))
    done

    die "./configure échoue toujours après $max_attempts tentatives de résolution de dépendances."
}

# ----------------------------------------------------------------------------
# 8. Compilation
# ----------------------------------------------------------------------------

compile_project() {
    log_info "Compilation du projet (make)..."

    local build_log="$WORK_DIR/build.log"

    if make 2>&1 | tee -a "$LOG_FILE" | tee "$build_log" >/dev/null; then
        log_info "Compilation réussie."
        return 0
    fi

    log_warn "make a échoué, tentative de résolution de dépendances depuis le log de build..."
    if install_missing_dependencies "$build_log"; then
        log_info "Nouvelle tentative de compilation après installation de dépendances..."
        if make 2>&1 | tee -a "$LOG_FILE"; then
            log_info "Compilation réussie après installation de dépendances supplémentaires."
            return 0
        fi
    fi

    die "La compilation a échoué. Consultez $LOG_FILE pour le détail."
}

# ----------------------------------------------------------------------------
# 9. Installation
# ----------------------------------------------------------------------------

install_project() {
    log_info "Installation du projet (sudo make install)..."

    if sudo make install 2>&1 | tee -a "$LOG_FILE"; then
        log_info "Installation réussie."
        return 0
    fi

    die "L'installation (make install) a échoué. Consultez $LOG_FILE pour le détail."
}

# ----------------------------------------------------------------------------
# 10. Nettoyage
# ----------------------------------------------------------------------------

cleanup() {
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        log_info "Nettoyage du répertoire temporaire $WORK_DIR..."
        rm -rf "$WORK_DIR"
    fi
}

# ----------------------------------------------------------------------------
# 0bis. Mode interactif : demande à l'utilisateur lien OU chemin absolu
# ----------------------------------------------------------------------------

# Renseigne en sortie deux variables globales :
#   SOURCE_MODE = "url" | "local"
#   SOURCE_VALUE = l'URL saisie OU le chemin absolu saisi
SOURCE_MODE=""
SOURCE_VALUE=""

prompt_user_choice() {
    echo ""
    echo "=== Installation automatique depuis une archive source ==="
    echo ""
    echo "Comment souhaitez-vous fournir l'archive du programme à installer ?"
    echo "  1) J'ai un lien (URL) à télécharger"
    echo "  2) J'ai déjà l'archive compressée sur mon disque (chemin absolu)"
    echo ""

    local choice
    while true; do
        read -r -p "Votre choix [1/2] : " choice
        case "$choice" in
            1)
                SOURCE_MODE="url"
                break
                ;;
            2)
                SOURCE_MODE="local"
                break
                ;;
            *)
                echo "Choix invalide. Merci de saisir 1 ou 2."
                ;;
        esac
    done

    if [ "$SOURCE_MODE" = "url" ]; then
        while true; do
            read -r -p "Entrez l'URL de l'archive : " SOURCE_VALUE
            if [ -n "$SOURCE_VALUE" ]; then
                break
            fi
            echo "L'URL ne peut pas être vide."
        done
    else
        while true; do
            read -r -p "Entrez le chemin absolu de l'archive (ex: /home/user/projet.tar.gz) : " SOURCE_VALUE
            if [[ "$SOURCE_VALUE" == /* ]] && [ -f "$SOURCE_VALUE" ]; then
                break
            elif [[ "$SOURCE_VALUE" != /* ]]; then
                echo "Merci de fournir un chemin absolu (commençant par /)."
            else
                echo "Fichier introuvable : $SOURCE_VALUE"
            fi
        done
    fi
}

# ----------------------------------------------------------------------------
# main
# ----------------------------------------------------------------------------

main() {
    if [ "$#" -gt 1 ]; then
        echo "Usage: $0 [URL_de_l'archive]" >&2
        echo "       $0                      (mode interactif)" >&2
        exit 1
    fi

    : > "$LOG_FILE"   # repart d'un log propre à chaque exécution

    if [ "$#" -eq 1 ]; then
        # Mode direct (compatibilité avec l'usage existant) : un seul argument = URL
        SOURCE_MODE="url"
        SOURCE_VALUE="$1"
    else
        # Mode interactif : aucun argument fourni
        prompt_user_choice
    fi

    log_info "=== Démarrage de l'installation (mode: $SOURCE_MODE) : $SOURCE_VALUE ==="

    WORK_DIR="$(mktemp -d)" || die "Impossible de créer un répertoire temporaire."
    trap cleanup EXIT INT TERM

    check_dependencies

    if [ "$SOURCE_MODE" = "url" ]; then
        download_archive "$SOURCE_VALUE"
    else
        use_local_archive "$SOURCE_VALUE"
    fi

    verify_archive

    local extract_dir
    extract_dir="$(extract_archive)"

    SRC_DIR="$(locate_source_directory "$extract_dir")"
    log_info "Répertoire source détecté : $SRC_DIR"

    detect_build_system
    configure_project
    compile_project
    install_project

    log_info "=== Installation terminée avec succès. Log complet : $LOG_FILE ==="
}

main "$@"
