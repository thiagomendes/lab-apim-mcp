#!/bin/bash
# Script para configurar as settings do Azure Function App
# Uso: ./configure-function.sh

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Configurando Azure Function App ===${NC}\n"

# Verifica se as variáveis necessárias estão definidas
MISSING_VARS=()

[ -z "$FUNC" ] && MISSING_VARS+=("FUNC")
[ -z "$GRP" ] && MISSING_VARS+=("GRP")
[ -z "$AZURE_TENANT_ID" ] && MISSING_VARS+=("AZURE_TENANT_ID")
[ -z "$BACKEND_APP_ID" ] && MISSING_VARS+=("BACKEND_APP_ID")
[ -z "$BACKEND_SECRET" ] && MISSING_VARS+=("BACKEND_SECRET")

if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    echo -e "${RED}✗ Erro: As seguintes variáveis não estão definidas:${NC}"
    for var in "${MISSING_VARS[@]}"; do
        echo -e "  - $var"
    done
    echo -e "\n${YELLOW}Execute primeiro:${NC}"
    echo -e "  ${GREEN}source env-setup.sh${NC}"
    echo -e "\n${YELLOW}E se necessário, configure o BACKEND_SECRET:${NC}"
    echo -e "  ${GREEN}export BACKEND_SECRET=\$(az ad app credential reset --id \$BACKEND_APP_ID --display-name \"OBOSecret\" --query password -o tsv)${NC}"
    exit 1
fi

# Mostra as configurações que serão aplicadas
echo -e "${YELLOW}Function App:${NC} $FUNC"
echo -e "${YELLOW}Resource Group:${NC} $GRP"
echo -e "${YELLOW}Settings a serem configuradas:${NC}"
echo -e "  - AZURE_TENANT_ID = $AZURE_TENANT_ID"
echo -e "  - BACKEND_CLIENT_ID = $BACKEND_APP_ID"
echo -e "  - BACKEND_CLIENT_SECRET = ${BACKEND_SECRET:0:4}***"

echo -e "\n${YELLOW}Aplicando configurações...${NC}"

# Executa o comando
az functionapp config appsettings set \
  --name "$FUNC" \
  --resource-group "$GRP" \
  --settings \
    AZURE_TENANT_ID="$AZURE_TENANT_ID" \
    BACKEND_CLIENT_ID="$BACKEND_APP_ID" \
    BACKEND_CLIENT_SECRET="$BACKEND_SECRET" \
  --output table

if [ $? -eq 0 ]; then
    echo -e "\n${GREEN}✓ Configurações aplicadas com sucesso!${NC}"
else
    echo -e "\n${RED}✗ Erro ao aplicar configurações.${NC}"
    exit 1
fi
