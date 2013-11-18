#!/bin/sh

BUNDLE_FILE="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
PLUGIN_FILE="`basename ${BUNDLE_FILE} .bundle`.plugin"
rm -rf "${HOME}/Library/Application Support/GTWSPARQLEngine/PlugIns/${PLUGIN_FILE}"
cp -R $BUNDLE_FILE "${HOME}/Library/Application Support/GTWSPARQLEngine/PlugIns/${PLUGIN_FILE}"
