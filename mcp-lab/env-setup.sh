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
        echo -e "${GREEN}[OK] Resource group detectado:${NC} $DETECTED_RG"
        echo -e "${GREEN}[OK] Sufixo extraído:${NC} $RND"
    else
        # Gera um novo sufixo aleatório
        export RND=$(openssl rand -hex 3)
        echo -e "${YELLOW}[WARN] Nenhum resource group encontrado. Gerando novo sufixo:${NC} $RND"
    fi
fi

# Define todas as variáveis de ambiente
export LOC="eastus2"
export EMAIL="admin@yourdomain.com"
export GRP="rg-mcp-obo-lab-$RND"
export STG="stmcplab$RND"
export FUNC="func-mcp-api-$RND"
export APIM="apim-mcp-gw-$RND"

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
    echo -e "${GREEN}[OK] Backend App encontrado:${NC} $BACKEND_APP_ID"
    echo -e "${RED}[WARN] BACKEND_SECRET não pode ser recuperado automaticamente.${NC}"
    echo -e "${YELLOW}  Se você precisa do secret, defina manualmente:${NC}"
    echo -e "  export BACKEND_SECRET=\"your-secret-here\""
    echo -e "  ${YELLOW}ou regenere com:${NC}"
    echo -e "  export BACKEND_SECRET=\$(az ad app credential reset --id $BACKEND_APP_ID --display-name \"OBOSecret\" --query password -o tsv)"
else
    echo -e "${YELLOW}[WARN] Backend App não encontrado. Será necessário criar.${NC}"
fi

# Pega o Tenant ID
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)
echo -e "\n${GREEN}[OK] Azure Tenant ID:${NC} $AZURE_TENANT_ID"

# Busca o App ID do Azure CLI (aplicativo de primeira parte da Microsoft)
echo -e "\n${YELLOW}Buscando App ID do 'Microsoft Azure CLI'...${NC}"
export AZURE_CLI_APP_ID=$(az ad sp show --id 04b07795-8ddb-461a-bbee-02f9e1bf7b46 --query appId -o tsv 2>/dev/null)
if [ -n "$AZURE_CLI_APP_ID" ] && [ "$AZURE_CLI_APP_ID" != "null" ]; then
    echo -e "${GREEN}[OK] Azure CLI App ID detectado:${NC} $AZURE_CLI_APP_ID"
else
    echo -e "${RED}[WARN] Não foi possível detectar o App ID do Azure CLI. Usando valor padrão.${NC}"
    export AZURE_CLI_APP_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"
fi

echo -e "\n${GREEN}=== Configuração concluída! ===${NC}"
echo -e "${YELLOW}Para usar estas variáveis, execute:${NC}"
echo -e "  ${GREEN}source env-setup.sh${NC} [sufixo-opcional]"
echo -e "\n${YELLOW}Scripts disponíveis:${NC}"
echo -e "  ${GREEN}./configure-function.sh${NC} - Configura settings do Function App"

