#!/bin/bash
# Script de configuração de ambiente para o lab MCP OBO
# Uso: source env-setup.sh [RANDOM_SUFFIX]

# Cores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== MCP OBO Lab - Configuração de Ambiente ===${NC}\n"

# Se um sufixo for passado como argumento, use-o. Caso contrário, tente detectar.
if [ -n "$1" ]; then
    export RND="$1"
    echo -e "${YELLOW}Usando sufixo fornecido:${NC} $RND"
else
    echo -e "${YELLOW}Nenhum sufixo fornecido. Tentando detectar recursos existentes...${NC}"

    # Tenta detectar o resource group
    DETECTED_RG=$(az group list --query "[?contains(name, 'rg-mcp-obo-lab')].name" -o tsv | head -n 1)

    if [ -n "$DETECTED_RG" ]; then
        export RND=$(echo $DETECTED_RG | sed 's/rg-mcp-obo-lab-//')
        echo -e "${GREEN}✓ Resource group detectado:${NC} $DETECTED_RG"
        echo -e "${GREEN}✓ Sufixo extraído:${NC} $RND"
    else
        # Gera um novo sufixo aleatório
        export RND=$(openssl rand -hex 3)
        echo -e "${YELLOW}! Nenhum resource group encontrado. Gerando novo sufixo:${NC} $RND"
    fi
fi

# Define todas as variáveis de ambiente
export LOC="eastus"
export EMAIL="admin@example.com"
export GRP="rg-mcp-obo-lab-$RND"
export STG="stmcpapi${RND}"
export FUNC="func-mcp-api-$RND"
export APIM="apim-mcp-obo-$RND"

echo -e "\n${GREEN}Variáveis de ambiente configuradas:${NC}"
echo "  RND  = $RND"
echo "  LOC  = $LOC"
echo "  GRP  = $GRP"
echo "  STG  = $STG"
echo "  FUNC = $FUNC"
echo "  APIM = $APIM"

# Tenta buscar informações do Backend App se existir
echo -e "\n${YELLOW}Buscando informações do Backend App...${NC}"
export BACKEND_APP_ID=$(az ad app list --display-name "mcp-lab-backend-$RND" --query [0].appId -o tsv 2>/dev/null)

if [ -n "$BACKEND_APP_ID" ] && [ "$BACKEND_APP_ID" != "null" ]; then
    echo -e "${GREEN}✓ Backend App encontrado:${NC} $BACKEND_APP_ID"
    echo -e "${RED}⚠ BACKEND_SECRET não pode ser recuperado automaticamente.${NC}"
    echo -e "${YELLOW}  Se você precisa do secret, defina manualmente:${NC}"
    echo -e "  export BACKEND_SECRET=\"your-secret-here\""
    echo -e "  ${YELLOW}ou regenere com:${NC}"
    echo -e "  export BACKEND_SECRET=\$(az ad app credential reset --id $BACKEND_APP_ID --display-name \"OBOSecret\" --query password -o tsv)"
else
    echo -e "${YELLOW}! Backend App não encontrado. Será necessário criar.${NC}"
fi

# Pega o Tenant ID
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
echo -e "\n${GREEN}✓ Azure Tenant ID:${NC} $AZURE_TENANT_ID"

echo -e "\n${GREEN}=== Configuração concluída! ===${NC}"
echo -e "${YELLOW}Para usar estas variáveis, execute:${NC}"
echo -e "  ${GREEN}source env-setup.sh${NC} [sufixo-opcional]"
echo -e "\n${YELLOW}Scripts disponíveis:${NC}"
echo -e "  ${GREEN}./configure-function.sh${NC} - Configura settings do Function App"
