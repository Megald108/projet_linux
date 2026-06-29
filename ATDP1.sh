#!/bin/bash

# Script FINAL ULTIME : Installation automatique depuis archive .tar.gz
# Usage : ./install_from_source.sh <URL_de_l'archive>
# L'utilisateur n'a besoin que du lien. Tout le reste est automatisé.

LOG_FILE="../install_errors.log"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <URL_de_l'archive>"
    exit 1
fi

URL=$1
ARCHIVE=$(basename "$URL")
DIRNAME=${ARCHIVE%.tar.gz}

# Vérification et installation de build-essential (compilateur)
echo "Vérification des outils de compilation essentiels..."
sudo apt-get update -qq
sudo apt-get install -y build-essential wget tar

# Téléchargement
echo "Téléchargement de $ARCHIVE..."
wget -q --show-progress "$URL"
if [ ! -f "$ARCHIVE" ]; then
    echo "Erreur: téléchargement échoué."
    exit 1
fi

# Décompression
echo "Décompression de $ARCHIVE..."
tar -xzf "$ARCHIVE"
if [ ! -d "$DIRNAME" ]; then
    echo "Erreur: répertoire décompressé $DIRNAME introuvable."
    exit 1
fi
cd "$DIRNAME"

# Fonction configure avec installation automatique des dépendances
run_configure_auto() {
    while true; do
        if ./configure; then
            echo "./configure réussi !"
            break
        else
            echo "Erreur détectée dans ./configure, recherche automatique des dépendances..."
            if [ ! -f config.log ]; then
                echo "config.log introuvable, impossible de détecter les dépendances."
                break
            fi
            MISSING=$(grep -i "error:.*No such file or directory" config.log | awk '{print $4}' | sed 's/<//;s/>//;s/"//g' | grep "\.h" | sort -u)
            if [ -z "$MISSING" ]; then
                echo "Aucune dépendance détectable automatiquement."
                break
            fi
            for header in $MISSING; do
                PKG=$(apt-cache search "$header" | awk '{print $1}' | head -n1)
                if [ -n "$PKG" ]; then
                    echo "Installation automatique du paquet $PKG correspondant à $header..."
                    sudo apt-get install -y "$PKG"
                else
                    echo "Impossible de trouver le paquet correspondant à $header."
                fi
            done
            echo "Re-lancement de ./configure..."
        fi
    done
}

run_configure_auto

# Compilation avec log et continuation en cas d'erreurs
echo "Compilation du programme..."
make 2>&1 | tee -a "$LOG_FILE" || echo "Des erreurs sont survenues lors de la compilation. Vérifiez $LOG_FILE"

# Installation avec log et continuation
echo "Installation du programme (sudo requis)..."
sudo make install 2>&1 | tee -a "$LOG_FILE" || echo "Des erreurs sont survenues lors de l'installation. Vérifiez $LOG_FILE"

echo "Installation terminée. Toutes les erreurs sont loguées dans $LOG_FILE."

